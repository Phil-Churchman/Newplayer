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
            // A liked track from a saved album appears in both; keep one row per track. Twice
            // over: once by id, then once by recording, because Spotify's per-market relinking
            // hands the same recording back under two different ids.
            let tracks = Self.collapsingRelinkedTracks(Self.deduplicated(likedTracks + albumTracks))
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

    /// Keeps the first occurrence of each track id, preserving order.
    ///
    /// Deliberately id-only. Matching on title/artist/album as well was tried, to catch the same
    /// recording arriving under two ids from Spotify's per-market relinking — but it changes
    /// *which* id is stored for a track, and a relinked id is not always playable when handed
    /// straight back in a play request. That showed up as Spotify refusing to open the link.
    static func deduplicated(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// One recording, one row — even when Spotify reports it under more than one id.
    ///
    /// Spotify relinks tracks per market, so the copy in Liked Songs and the copy on a saved
    /// album can carry different ids for the same recording. `deduplicated` matches on the id,
    /// so both survive it and both import: the song is then listed twice in its album, queued
    /// twice when the album is played, and no resync can ever fix it, because every sync
    /// legitimately reports both ids.
    ///
    /// The id kept is the first one seen, and liked tracks are passed in ahead of album tracks,
    /// so what is stored is the id belonging to the copy the user actually saved. This is the
    /// part to be careful with: an earlier attempt at matching on title/artist/album made a
    /// *relinked* id the stored one, and a relinked id is not always playable when handed back
    /// in a play request, which showed up as Spotify refusing to open the link. Hence the
    /// first-wins rule and the log below, so a refusal can be traced to what was collapsed.
    ///
    /// The key is deliberately tight — same album, same track number, same title — so two
    /// genuinely different songs have to agree on all three to be treated as one. Track numbers
    /// repeat across the discs of a multi-disc album, which is why the title is in the key.
    static func collapsingRelinkedTracks(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        struct RecordingKey: Hashable {
            let title: String
            let album: String
            let track: Int
        }

        func folded(_ value: String) -> String {
            value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var keptIDByKey: [RecordingKey: String] = [:]
        var kept: [SpotifyTrack] = []
        var collapsed: [String] = []
        kept.reserveCapacity(tracks.count)

        for track in tracks {
            let key = RecordingKey(
                title: folded(track.title),
                album: folded(track.albumName),
                track: track.trackNumber
            )
            if let keptID = keptIDByKey[key] {
                collapsed.append("\(track.title) [\(track.id) → \(keptID)]")
            } else {
                keptIDByKey[key] = track.id
                kept.append(track)
            }
        }

        if !collapsed.isEmpty {
            print("""
            SpotifyImportService: collapsed \(collapsed.count) relinked duplicate(s) — \
            \(collapsed.prefix(10).joined(separator: ", "))\
            \(collapsed.count > 10 ? ", …" : "")
            """)
        }
        return kept
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
            let albumArtist = albumArtistName(for: ordered)
            // One URL for the album, from its first track — every track in it shows the same
            // cover once that URL has been fetched.
            let coverURL = ordered.first?.albumArtworkURL?.absoluteString

            for (index, track) in ordered.enumerated() {
                rows.append(RawSong(
                    title: track.title.nilIfBlank ?? "Unknown Title",
                    // The track's own performers, not the album's. On a compilation the album
                    // artist is a label for the record as a whole — "Compilation", or whatever
                    // Spotify calls it — and writing that onto every track threw away the one
                    // piece of information that makes a compilation worth browsing: who is
                    // actually playing each song.
                    //
                    // Safe to vary within an album because LibraryRowBuilder builds its Artist
                    // and Album rows from `albumArtist` alone. The per-track name is carried on
                    // the Song and changes no grouping.
                    artist: trackArtistName(for: track) ?? albumArtist,
                    album: albumName,
                    albumArtist: albumArtist,
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

    /// The one name an album is filed under. Every track in the album shares it, because it is
    /// what the Artist and Album rows are keyed on — it decides grouping, not display.
    static func albumArtistName(for albumTracks: [SpotifyTrack]) -> String {
        let trackArtists = Set(albumTracks.compactMap { $0.artistNames.first?.nilIfBlank })
        if trackArtists.count > 1 {
            return "Compilation"
        }
        return albumTracks.first?.albumArtistNames.first?.nilIfBlank
            ?? trackArtists.first
            ?? "Unknown Artist"
    }

    /// Everyone credited on a single track, in Spotify's own order.
    ///
    /// All of them rather than just the first: a feature is part of who performed the track, and
    /// showing only the lead credit is how "X, Y" quietly becomes "X". Nil when Spotify credits
    /// nobody, which leaves the caller to fall back on the album's name.
    static func trackArtistName(for track: SpotifyTrack) -> String? {
        let names = track.artistNames.compactMap(\.nilIfBlank)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
