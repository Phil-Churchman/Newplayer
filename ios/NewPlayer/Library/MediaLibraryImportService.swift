import Foundation
import SwiftData

enum MediaLibraryImportError: Error, Equatable {
    case accessDenied
    case accessRestricted
}

/// Imports the device's own Music (iTunes) library into the same Artist/Album/Song schema the
/// folder scan and the MPD sync use, so every browsing screen works unchanged regardless of
/// where the tracks came from.
///
/// Unlike the folder source there is no security-scoped bookmark: tracks are addressed by the
/// library's persistent ID, resolved to a playable asset URL at the moment of playback.
@MainActor
enum MediaLibraryImportService {
    struct Result: Equatable {
        var imported: Int
        /// Tracks this app can't play: DRM-protected, or not downloaded to the device.
        var skippedProtected: Int
    }

    @discardableResult
    static func rescan(
        source: Source,
        provider: MediaLibraryProviding,
        modelContext: ModelContext,
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> Result {
        // Ask only if the user hasn't already answered — `??` can't wrap an async call.
        let access: MediaLibraryAccess
        if let existing = provider.currentAccess() {
            access = existing
        } else {
            access = await provider.requestAccess()
        }

        switch access {
        case .authorized: break
        case .denied: throw MediaLibraryImportError.accessDenied
        case .restricted: throw MediaLibraryImportError.accessRestricted
        }

        source.lastSyncStatus = .syncing
        try? modelContext.save()

        let tracks = provider.fetchTracks()
        let playable = tracks.filter(\.isPlayableLocally)
        let skipped = tracks.count - playable.count
        print("MediaLibraryImportService: \(playable.count) playable track(s), \(skipped) skipped as DRM-protected or not downloaded")

        let rawSongs = makeRawSongs(from: playable, artworkForTrack: provider.artworkData(forPersistentID:))

        do {
            try await LibraryRowBuilder.merge(
                from: rawSongs,
                source: source,
                modelContext: modelContext,
                onProgress: onProgress
            )
            source.lastSyncStatus = .success
        } catch {
            source.lastSyncStatus = .failed
            print("MediaLibraryImportService.rescan failed: \(error)")
        }
        source.lastSyncDate = .now
        try? modelContext.save()

        return Result(imported: rawSongs.count, skippedProtected: skipped)
    }
}

extension MediaLibraryImportService {
    /// Builds the rows for a whole library, album by album.
    ///
    /// Three rules specific to this source, all of which need the album seen as a whole rather
    /// than a track at a time:
    ///
    /// - The artist shown is the *album* artist, not the per-track artist. On a well-tagged
    ///   iTunes library that is what keeps a release together under one name.
    /// - An album whose tracks credit several different artists is shown as "Compilation", for
    ///   every track in it. Otherwise a Various Artists record scatters itself across the
    ///   Artists list, one entry per guest.
    /// - The cover is taken from the album's first track and applied to the album, so every
    ///   track in it shows the same art from a single render.
    static func makeRawSongs(
        from tracks: [MediaLibraryTrack],
        artworkForTrack: (String) -> Data?
    ) -> [RawSong] {
        // Grouped on the library's own album ID where there is one, so two different releases
        // sharing a title stay apart.
        let grouped = Dictionary(grouping: tracks) { track -> String in
            track.albumPersistentID.isEmpty
                ? "\(track.albumTitle ?? "")|\(track.albumArtist ?? "")"
                : track.albumPersistentID
        }

        var rows: [RawSong] = []
        rows.reserveCapacity(tracks.count)

        for (_, albumTracks) in grouped {
            // Track order decides which one is "first"; the library hands them back unordered.
            let ordered = albumTracks.sorted { $0.trackNumber < $1.trackNumber }
            let albumName = ordered.first?.albumTitle.nilIfBlank ?? "Unknown Album"
            let artistName = artistName(for: ordered)

            // One render for the whole album, from its first track.
            let cover = ordered.first.flatMap { artworkForTrack($0.persistentID) }

            for (index, track) in ordered.enumerated() {
                rows.append(RawSong(
                    title: track.title.nilIfBlank ?? "Unknown Title",
                    artist: artistName,
                    album: albumName,
                    albumArtist: artistName,
                    track: track.trackNumber,
                    duration: track.duration,
                    relativePath: track.persistentID,
                    // LibraryRowBuilder keeps the cover carried by the first song it sees for an
                    // album and drops the rest, so only the first row carries it.
                    artworkData: index == 0 ? cover : nil
                ))
            }
        }
        return rows
    }

    /// "Compilation" when the album credits more than one track artist, otherwise the album
    /// artist — falling back to the track artist when the album-artist tag is missing.
    private static func artistName(for albumTracks: [MediaLibraryTrack]) -> String {
        let trackArtists = Set(albumTracks.compactMap { $0.artist.nilIfBlank })
        if trackArtists.count > 1 {
            return "Compilation"
        }
        return albumTracks.first?.albumArtist.nilIfBlank
            ?? trackArtists.first
            ?? "Unknown Artist"
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
