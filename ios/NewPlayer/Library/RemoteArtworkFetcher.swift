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
        let albumID = album.persistentModelID
        guard !knownFailures.contains(albumID) else { return }

        if !pendingSet.contains(albumID) {
            pendingSet.insert(albumID)
            pendingIDs.append(albumID)
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
                await self.fetch(albumID: albumID, modelContext: modelContext)
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

    private func fetch(albumID: PersistentIdentifier, modelContext: ModelContext) async {
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate<Album> { $0.persistentModelID == albumID })
        descriptor.fetchLimit = 1
        guard let album = try? modelContext.fetch(descriptor).first,
              album.artwork == nil,
              let urlString = album.artworkURL,
              let url = URL(string: urlString) else { return }

        do {
            let data = try await download(url)
            guard let processed = await ArtworkProcessor.processInBackground(data) else {
                knownFailures.insert(albumID)
                return
            }
            album.apply(processed)
            do {
                try modelContext.save()
            } catch {
                // Never swallowed. An unsaved cover leaves `artwork` nil, so the next launch
                // downloads and re-processes every one of them again — which is why relaunching
                // did not help and the same minutes-long stall repeated.
                knownFailures.insert(albumID)
                print("RemoteArtworkFetcher: couldn't save artwork for '\(album.name)' — \(error)")
            }
        } catch {
            knownFailures.insert(albumID)
            print("RemoteArtworkFetcher: couldn't fetch artwork for '\(album.name)' — \(error)")
        }
    }
}
