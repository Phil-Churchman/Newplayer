import Foundation
import SwiftData

/// Mirrors a Spotify account's saved tracks into the same Artist/Album/Song schema the other
/// sources use, so every browsing screen works against it unchanged.
///
/// Metadata only, and deliberately so: the Web API returns no audio. Streaming a Spotify track
/// requires Spotify's own playback SDK driving the Spotify app, so tracks imported here can be
/// browsed but not played through this app's player — PlaybackManager says as much rather than
/// failing silently.
@MainActor
enum SpotifyImportService {
    struct Result: Equatable {
        var imported: Int
    }

    @discardableResult
    static func rescan(
        source: Source,
        client: SpotifyAPIClient,
        accessToken: String,
        modelContext: ModelContext,
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> Result {
        source.lastSyncStatus = .syncing
        try? modelContext.save()

        do {
            // A Spotify library is Liked Songs *and* saved albums; the albums' tracks are not
            // in /me/tracks, so fetching only that quietly imports a fraction of what the user
            // sees in Spotify.
            //
            // Total isn't known until paging finishes, so progress during the fetch reports the
            // running count against itself rather than inventing a denominator.
            let likedTracks = try await client.fetchSavedTracks(accessToken: accessToken) { count in
                Task { @MainActor in onProgress(count, count) }
            }
            let albumTracks = try await client.fetchSavedAlbumTracks(accessToken: accessToken) { count in
                Task { @MainActor in onProgress(likedTracks.count + count, likedTracks.count + count) }
            }
            // A liked track from a saved album appears in both; keep one row per track.
            let tracks = Self.deduplicated(likedTracks + albumTracks)
            print("""
            SpotifyImportService: \(likedTracks.count) liked, \(albumTracks.count) from saved \
            albums, \(tracks.count) after removing duplicates
            """)

            // No covers are fetched here. Downloading and decoding one per album during a sync
            // makes every re-sync as slow as the first, holds them all in memory at once, and
            // does the image work on the main actor — which froze the app on a second sync of a
            // large library. The URL is stored instead and the cover fetched when first shown,
            // the same way the MPD source works.
            let rawSongs = makeRawSongs(from: tracks)

            try await LibraryRowBuilder.merge(
                from: rawSongs,
                source: source,
                modelContext: modelContext,
                onProgress: onProgress
            )
            source.lastSyncStatus = .success
            source.lastSyncDate = .now
            try? modelContext.save()

            return Result(imported: rawSongs.count)
        } catch {
            source.lastSyncStatus = .failed
            source.lastSyncDate = .now
            try? modelContext.save()
            throw error
        }
    }

    /// Removes duplicates, keeping the first occurrence and the original order.
    ///
    /// Matching on the track id alone isn't enough. Spotify relinks tracks per market, so the
    /// same recording comes back with a different id from `/me/tracks` than from `/me/albums`,
    /// and a saved album whose songs are also liked then imports twice over.
    ///
    /// The second pass therefore matches on what the track *is* — title, lead artist and album,
    /// compared case- and accent-insensitively. Album is deliberately part of the key: the same
    /// song on a single and on the album it later appeared on are different releases, and
    /// collapsing those would quietly lose music rather than tidy it.
    static func deduplicated(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var seenIDs = Set<String>()
        var seenTracks = Set<String>()
        return tracks.filter { track in
            guard seenIDs.insert(track.id).inserted else { return false }
            return seenTracks.insert(identityKey(for: track)).inserted
        }
    }

    /// A track's identity independent of which id Spotify happened to return for it.
    private static func identityKey(for track: SpotifyTrack) -> String {
        [track.title, track.artistNames.first ?? "", track.albumName]
            .map(normalised)
            .joined(separator: "\u{1F}")
    }

    private static func normalised(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same album-wide rules as the Music library import: the album artist names the release,
    /// an album crediting several track artists is a "Compilation", and the cover belongs to
    /// the album rather than to each track.
    static func makeRawSongs(from tracks: [SpotifyTrack]) -> [RawSong] {
        let grouped = Dictionary(grouping: tracks, by: \.albumID)

        var rows: [RawSong] = []
        rows.reserveCapacity(tracks.count)

        for (_, albumTracks) in grouped {
            let ordered = albumTracks.sorted { $0.trackNumber < $1.trackNumber }
            let albumName = ordered.first?.albumName.nilIfBlank ?? "Unknown Album"
            let artist = artistName(for: ordered)
            // One URL for the album, from its first track — every track in it shows the same
            // cover once that URL has been fetched.
            let coverURL = ordered.first?.albumArtworkURL?.absoluteString

            for (index, track) in ordered.enumerated() {
                rows.append(RawSong(
                    title: track.title.nilIfBlank ?? "Unknown Title",
                    artist: artist,
                    album: albumName,
                    albumArtist: artist,
                    track: track.trackNumber,
                    duration: track.durationSeconds,
                    relativePath: track.id,
                    // LibraryRowBuilder keeps what the first song of an album carries.
                    artworkData: nil,
                    artworkURL: index == 0 ? coverURL : nil
                ))
            }
        }
        return rows
    }

    static func artistName(for albumTracks: [SpotifyTrack]) -> String {
        let trackArtists = Set(albumTracks.compactMap { $0.artistNames.first?.nilIfBlank })
        if trackArtists.count > 1 {
            return "Compilation"
        }
        return albumTracks.first?.albumArtistNames.first?.nilIfBlank
            ?? trackArtists.first
            ?? "Unknown Artist"
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
