import Foundation
import SwiftData

/// Fetches and saves album artwork from an MPD source on demand — the first time an album is
/// actually shown in the UI, rather than during the library sync (see MPDLibrarySyncService).
///
/// Requests are funnelled through a single serialized worker sharing one connection. Fetching
/// per-view instead (a connection per visible row, all at once) buries a modest MPD host: every
/// row that scrolls past opens its own socket, and each cover is transferred in `binary_limit`
/// sized chunks — hundreds of round trips for a multi-MB image. That starves the separate
/// playback-control connection, which shows up as play/pause/skip lagging badly while browsing.
@MainActor
final class MPDArtworkFetcher {
    static let shared = MPDArtworkFetcher()

    /// How many of an album's tracks to probe before concluding it has no artwork. Embedded
    /// picture coverage varies track to track, but each extra candidate costs round trips.
    private let maxCandidateSongs = 3
    /// Upper bound on queued requests, so scrolling a long list doesn't commit the server to
    /// hundreds of downloads. The oldest are dropped first — they've scrolled furthest away.
    private let maxPendingRequests = 64

    private let makeClient: () -> MPDClientProtocol
    private var pendingIDs: [PersistentIdentifier] = []
    private var pendingSet: Set<PersistentIdentifier> = []
    /// Albums the server had no artwork for. Without this, every scroll past such an album
    /// re-runs a full readpicture/albumart probe across several tracks, for nothing.
    private var knownMissingArtwork: Set<PersistentIdentifier> = []
    private var isDraining = false
    private var client: MPDClientProtocol?
    private var clientEndpoint: String?
    private var activeScope: UUID?

    init(makeClient: @escaping () -> MPDClientProtocol = { MPDClient() }) {
        self.makeClient = makeClient
    }

    /// - Parameter scope: the screen this request came from. When it differs from the last
    ///   requesting screen, everything still queued belongs to a screen the user has navigated
    ///   away from, so it's dropped in favour of what's on screen now. Persistent chrome passes
    ///   nil so it never cancels a browsing screen's queue.
    func fetchIfNeeded(album: Album, modelContext: ModelContext, scope: UUID? = nil) {
        if let scope, scope != activeScope {
            activeScope = scope
            cancelPendingRequests()
        }

        guard album.artwork == nil else { return }
        guard let source = album.source, source.kind == .network, !source.host.isEmpty else { return }

        let albumID = album.persistentModelID
        guard !knownMissingArtwork.contains(albumID) else { return }

        if !pendingSet.contains(albumID) {
            pendingSet.insert(albumID)
            pendingIDs.append(albumID)
            if pendingIDs.count > maxPendingRequests {
                let dropped = pendingIDs.removeFirst()
                pendingSet.remove(dropped)
            }
        }

        // Kicked even when this album was already queued: the drain stops when the host can't be
        // reached, and if an already-pending request returned early here there would be nothing
        // left to restart it — the queue would sit full and idle for the rest of the session.
        drainIfNeeded(modelContext: modelContext)
    }

    /// How long to wait before trying an unreachable host again, multiplied by the attempt
    /// number, and how many times to bother.
    private static let unreachableBackoff: TimeInterval = 2
    private static let maxUnreachableRetries = 4

    // No pacing between covers. Gaps were added when a poll-failure-and-stutter looked like this
    // queue swamping a modest host, but the cause turned out to be the network — so they were
    // slowing covers down for nothing. Requests are already serialized over one connection,
    // which is the limit that matters.

    /// Drops everything still queued. A fetch already in progress is allowed to finish rather
    /// than being torn down mid-transfer — aborting would mean dropping the connection and
    /// reconnecting, and with one request in flight at a time it completes promptly anyway.
    func cancelPendingRequests() {
        pendingIDs.removeAll()
        pendingSet.removeAll()
    }

    // MARK: - Serialized draining

    private func drainIfNeeded(modelContext: ModelContext) {
        guard !isDraining else { return }
        isDraining = true

        Task { [weak self] in
            guard let self else { return }

            // Looped around the teardown, not just the queue.
            //
            // Closing the socket is an await, and `isDraining` stayed true across it — so a
            // request arriving in that window was queued, saw a drain already running and so
            // didn't start one, and was then abandoned when this task ended. Its artwork never
            // appeared until some unrelated request happened to restart the drain, which for the
            // last row scrolled into view meant never. Re-checking after the socket closes picks
            // up anything that landed meanwhile.
            var unreachableAttempts = 0
            while true {
                var hostUnreachable = false
                while let albumID = self.takeNextRequest() {
                    let reachable = await self.fetchArtwork(forAlbumID: albumID, modelContext: modelContext)
                    guard reachable else {
                        // The host isn't answering. Put this one back and stop, rather than
                        // attempting a fresh connection for every album still queued — the next
                        // request (a scroll, or revisiting the screen) starts the drain again.
                        self.requeue(albumID)
                        hostUnreachable = true
                        break
                    }
                }

                // Nothing left to fetch — let the socket go rather than holding it open idle.
                await self.releaseClient()

                if self.pendingIDs.isEmpty {
                    self.isDraining = false
                    return
                }

                // An unreachable host is waited out rather than given up on.
                //
                // Stopping dead left the queue full and idle until some UI request happened to
                // restart it — and a user who is listening rather than scrolling makes none, so
                // covers stopped when the server got busy and never came back. Retrying at once
                // would spin on a server that isn't there, so each attempt waits longer than the
                // last, and after a few it does stop: by then the host is genuinely gone, and a
                // later scroll will start a fresh drain.
                if hostUnreachable {
                    unreachableAttempts += 1
                    guard unreachableAttempts <= Self.maxUnreachableRetries else {
                        self.isDraining = false
                        return
                    }
                    let backoff = Self.unreachableBackoff * Double(unreachableAttempts)
                    print("MPDArtworkFetcher: host unreachable — retrying in \(backoff)s")
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                } else {
                    unreachableAttempts = 0
                }
            }
        }
    }

    /// Newest request first: those are the rows actually on screen right now, whereas the
    /// front of the queue is whatever the user has already scrolled past.
    private func takeNextRequest() -> PersistentIdentifier? {
        guard let albumID = pendingIDs.popLast() else { return nil }
        pendingSet.remove(albumID)
        return albumID
    }

    /// Puts a request back at the head of the queue so it is taken first next time.
    private func requeue(_ albumID: PersistentIdentifier) {
        guard !pendingSet.contains(albumID) else { return }
        pendingSet.insert(albumID)
        pendingIDs.append(albumID)
    }

    /// - Returns: false only when the server couldn't be reached, meaning the caller should stop
    ///   draining. A missing cover, or an album that no longer needs one, returns true.
    @discardableResult
    private func fetchArtwork(forAlbumID albumID: PersistentIdentifier, modelContext: ModelContext) async -> Bool {
        var albumDescriptor = FetchDescriptor<Album>(predicate: #Predicate<Album> { $0.persistentModelID == albumID })
        albumDescriptor.fetchLimit = 1
        guard let album = try? modelContext.fetch(albumDescriptor).first, album.artwork == nil else { return true }
        guard let source = album.source, source.kind == .network, !source.host.isEmpty else { return true }

        // Queried directly rather than via `album.songs`: that relationship array can be
        // faulted in (and cached) on this instance before all of its songs exist, since the
        // sync pipeline saves in batches and inserts albums before songs.
        var songDescriptor = FetchDescriptor<Song>(
            predicate: #Predicate<Song> { $0.album?.persistentModelID == albumID },
            sortBy: [SortDescriptor(\.track)]
        )
        songDescriptor.fetchLimit = maxCandidateSongs
        let candidates = (try? modelContext.fetch(songDescriptor)) ?? []
        guard !candidates.isEmpty else { return true }

        guard let client = await connectedClient(host: source.host, port: source.port) else {
            await releaseClient()
            return false
        }

        for song in candidates {
            guard let raw = await client.fetchAlbumArt(forFile: song.relativePath) else { continue }
            guard let processed = await ArtworkProcessor.processInBackground(raw) else { continue }
            album.apply(processed)
            do {
                try modelContext.save()
            } catch {
                // Not recorded as missing. The server plainly has a cover — it was just
                // downloaded — so blaming the album for a failed save meant never asking again
                // for something that would probably save perfectly well next time.
                print("MPDArtworkFetcher: couldn't save artwork for '\(album.name)' — \(error)")
            }
            return true
        }

        knownMissingArtwork.insert(albumID)
        print("MPDArtworkFetcher: no artwork on the server for '\(album.name)' — won't retry this session")
        return true
    }

    // MARK: - Shared connection

    private func connectedClient(host: String, port: Int) async -> MPDClientProtocol? {
        let endpoint = "\(host):\(port)"
        if let client, clientEndpoint == endpoint {
            return client
        }
        await releaseClient()

        let newClient = makeClient()
        do {
            try await newClient.connect(host: host, port: UInt16(clamping: max(0, port)))
            client = newClient
            clientEndpoint = endpoint
            return newClient
        } catch {
            print("MPDArtworkFetcher: couldn't connect to \(endpoint) — \(error)")
            return nil
        }
    }

    private func releaseClient() async {
        if let client {
            await client.disconnect()
        }
        client = nil
        clientEndpoint = nil
    }
}
