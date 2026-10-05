import Foundation
import SwiftData

/// Downloads album covers published over HTTP (Spotify's, currently) the first time an album is
/// actually shown, rather than during a sync.
///
/// One at a time, newest request first — the same arrangement as MPDArtworkFetcher and for the
/// same reasons: a screenful of rows would otherwise start a download each, and decoding them
/// all at once on the main actor is what froze the app mid-sync.
@MainActor
final class RemoteArtworkFetcher {
    static let shared = RemoteArtworkFetcher()

    /// Enough to cover a screen and a little scrolling; older requests are dropped first,
    /// having scrolled furthest away.
    private let maximumPendingRequests = 64

    private let download: (URL) async throws -> Data
    private var pendingIDs: [PersistentIdentifier] = []
    private var pendingSet: Set<PersistentIdentifier> = []
    /// Albums whose cover couldn't be fetched, so a scroll past doesn't retry endlessly.
    private var knownFailures: Set<PersistentIdentifier> = []
    private var isDraining = false
    private var activeScope: UUID?

    init(download: ((URL) async throws -> Data)? = nil) {
        self.download = download ?? { url in
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SpotifyError.requestFailed("artwork request failed")
            }
            return data
        }
    }

    /// - Parameter scope: the screen this request came from; when it changes, whatever the
    ///   previous screen queued is dropped in favour of what is on screen now.
    func fetchIfNeeded(album: Album, modelContext: ModelContext, scope: UUID? = nil) {
        if let scope, scope != activeScope {
            activeScope = scope
            pendingIDs.removeAll()
            pendingSet.removeAll()
        }

        guard album.artwork == nil, album.artworkURL != nil else { return }
        enqueue(album.persistentModelID, modelContext: modelContext)
    }


    private func enqueue(_ id: PersistentIdentifier, modelContext: ModelContext) {
        guard !knownFailures.contains(id) else { return }

        if !pendingSet.contains(id) {
            pendingSet.insert(id)
            pendingIDs.append(id)
            if pendingIDs.count > maximumPendingRequests {
                let dropped = pendingIDs.removeFirst()
                pendingSet.remove(dropped)
            }
        }
        drainIfNeeded(modelContext: modelContext)
    }

    private func drainIfNeeded(modelContext: ModelContext) {
        guard !isDraining else { return }
        isDraining = true

        Task { [weak self] in
            guard let self else { return }
            while let albumID = self.takeNextRequest() {
                await self.fetch(id: albumID, modelContext: modelContext)
                // Decoding a cover is the expensive part; give the UI a turn between them.
                await Task.yield()
            }
            self.isDraining = false
        }
    }

    private func takeNextRequest() -> PersistentIdentifier? {
        guard let albumID = pendingIDs.popLast() else { return nil }
        pendingSet.remove(albumID)
        return albumID
    }

    /// One cover, resolved from its row's identifier — a `PersistentIdentifier` does not say
    /// what it identifies, so the row is fetched to find out.
    private func fetch(id: PersistentIdentifier, modelContext: ModelContext) async {
        guard let target = target(for: id, modelContext: modelContext) else { return }
        guard let url = URL(string: target.urlString) else { return }

        do {
            let data = try await download(url)
            guard let processed = await ArtworkProcessor.processInBackground(data) else {
                knownFailures.insert(id)
                return
            }
            target.apply(processed)
            do {
                try modelContext.save()
            } catch {
                // Never swallowed. An unsaved cover leaves `artwork` nil, so the next launch
                // downloads and re-processes every one of them again — which is why relaunching
                // did not help and the same minutes-long stall repeated.
                knownFailures.insert(id)
                print("RemoteArtworkFetcher: couldn't save artwork for '\(target.name)' — \(error)")
            }
        } catch {
            knownFailures.insert(id)
            print("RemoteArtworkFetcher: couldn't fetch artwork for '\(target.name)' — \(error)")
        }
    }

    /// What to download and where to put it, for whichever row this identifier belongs to.
    private struct ArtworkTarget {
        let name: String
        let urlString: String
        let apply: (ArtworkProcessor.Processed) -> Void
    }

    private func target(for id: PersistentIdentifier, modelContext: ModelContext) -> ArtworkTarget? {
        var albums = FetchDescriptor<Album>(predicate: #Predicate<Album> { $0.persistentModelID == id })
        albums.fetchLimit = 1
        if let album = try? modelContext.fetch(albums).first {
            guard album.artwork == nil, let urlString = album.artworkURL else { return nil }
            return ArtworkTarget(name: album.name, urlString: urlString) { album.apply($0) }
        }
        return nil
    }
}
