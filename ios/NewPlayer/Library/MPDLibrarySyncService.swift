import Foundation
import SwiftData

/// Syncs an MPD server's own music library into the same Song/Album/Artist schema the local
/// folder import uses, via LibraryRowBuilder, so existing Songs/Artists/Albums screens work
/// unchanged regardless of whether the active source is Local or a network MPD host.
///
/// Deliberately does NOT fetch album artwork here. Fetching a picture per album over MPD's
/// binary protocol is a full network round trip each — for a library of any real size that
/// makes the sync take far longer than just mirroring the tag data, to the point it can look
/// like it never finishes. Artwork is instead fetched lazily and on demand by
/// MPDArtworkFetcher, the first time a given album is actually shown in the Artists/Albums UI.
@MainActor
enum MPDLibrarySyncService {
    static func rescan(
        source: Source,
        client: MPDClientProtocol,
        modelContext: ModelContext,
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async {
        source.lastSyncStatus = .syncing
        try? modelContext.save()

        do {
            let mpdSongs = try await client.fetchAllSongs()
            print("MPDLibrarySyncService: found \(mpdSongs.count) song(s) on the server")

            let rawSongs = mpdSongs.map { info -> RawSong in
                let resolvedArtist = info.artist.nilIfBlank ?? "Unknown Artist"
                return RawSong(
                    title: info.title.nilIfBlank ?? ((info.file as NSString).lastPathComponent as NSString).deletingPathExtension,
                    artist: resolvedArtist,
                    album: info.album.nilIfBlank ?? "Unknown Album",
                    albumArtist: info.albumArtist.nilIfBlank ?? resolvedArtist,
                    track: info.track ?? 0,
                    duration: info.duration,
                    relativePath: info.file,
                    artworkData: nil
                )
            }
            try await LibraryRowBuilder.merge(from: rawSongs, source: source, modelContext: modelContext, onProgress: onProgress)

            source.lastSyncStatus = .success
        } catch {
            source.lastSyncStatus = .failed
            print("MPDLibrarySyncService.rescan failed: \(error)")
        }
        source.lastSyncDate = .now
        try? modelContext.save()
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
