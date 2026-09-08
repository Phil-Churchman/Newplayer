import Foundation
import SwiftData

struct RawSong {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var track: Int
    var duration: TimeInterval
    var relativePath: String
    var artworkData: Data?
    /// Where the cover can be fetched from later, for sources that publish one over HTTP.
    var artworkURL: String?
}

/// Brings a Source's Artist/Album/Song rows into line with what a sync found, used by the folder
/// scan, the Music-library import, the MPD sync and the Spotify sync so all four land in the same
/// schema.
///
/// This *merges* rather than wiping and reinserting. The wipe-and-reinsert it replaced deleted
/// every row for the source and built them again from scratch, which meant:
///
/// - a re-sync cost thousands of deletes and inserts however little had changed, and every
///   intermediate save made the `@Query`-backed screens re-fetch, which is what locked the app up
///   on a second sync of a large library;
/// - artwork was discarded and had to be downloaded and decoded again each time;
/// - a failure partway through left the library gutted, having already deleted everything.
///
/// Merging makes the work proportional to what actually changed, keeps covers that are already
/// held, and leaves existing rows untouched if a sync fails before it finishes.
@MainActor
enum LibraryRowBuilder {
    private static let saveBatchSize = 200

    /// Albums are identified by their name and album artist, the same pairing the browsing
    /// screens group by. Two releases sharing both are one album as far as this app is concerned.
    private struct AlbumKey: Hashable {
        let name: String
        let artistName: String
    }

    static func merge(
        from rawSongs: [RawSong],
        source: Source,
        modelContext: ModelContext,
        onProgress: (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws {
        LibraryRebuildState.shared.begin()
        defer { LibraryRebuildState.shared.finish() }

        let sourceID = source.persistentModelID
        let existing = try existingRows(sourceID: sourceID, modelContext: modelContext)
        var artistsByName = existing.artistsByName
        var albumsByKey = existing.albumsByKey
        let songsByPath = existing.songsByPath

        var seenArtists = Set<String>()
        var seenAlbums = Set<AlbumKey>()
        var seenSongs = Set<String>()
        var inserted = 0

        let total = rawSongs.count
        var sinceSave = 0

        for (index, raw) in rawSongs.enumerated() {
            let artist = artistsByName[raw.albumArtist] ?? {
                let created = Artist(name: raw.albumArtist, source: source)
                modelContext.insert(created)
                artistsByName[raw.albumArtist] = created
                return created
            }()
            seenArtists.insert(raw.albumArtist)

            let albumKey = AlbumKey(name: raw.album, artistName: raw.albumArtist)
            let album = albumsByKey[albumKey] ?? {
                let created = Album(name: raw.album, artist: artist, source: source)
                modelContext.insert(created)
                albumsByKey[albumKey] = created
                return created
            }()
            seenAlbums.insert(albumKey)

            // Only ever fills gaps. A cover already held is kept as it is — decoding one again to
            // produce the image we already had is the expense this merge exists to avoid.
            if album.artwork == nil, let artworkData = raw.artworkData {
                // Off the main actor: this is the expensive part of an import, and doing it here
                // held the interface for as long as the covers took.
                if let processed = await ArtworkProcessor.processInBackground(artworkData) {
                    album.apply(processed)
                }
            }
            if album.artworkURL == nil, let artworkURL = raw.artworkURL {
                album.artworkURL = artworkURL
            }

            if let existing = songsByPath[raw.relativePath] {
                update(existing, from: raw, album: album)
            } else {
                inserted += 1
                modelContext.insert(Song(
                    title: raw.title,
                    artist: raw.artist,
                    albumTitle: raw.album,
                    albumArtist: raw.albumArtist,
                    track: raw.track,
                    duration: raw.duration,
                    relativePath: raw.relativePath,
                    album: album,
                    source: source
                ))
            }
            seenSongs.insert(raw.relativePath)

            sinceSave += 1
            if sinceSave.isMultiple(of: saveBatchSize) {
                try modelContext.save()
                onProgress(index + 1, total)
                LibraryRebuildState.shared.report(processed: index + 1, total: total)
                await Task.yield()
            }
        }
        try modelContext.save()

        let deletedCount = try await removeVanishedRows(
            existing: existing,
            keptSongsByPath: songsByPath,
            keptAlbumsByKey: albumsByKey,
            keptArtistsByName: artistsByName,
            seenSongs: seenSongs,
            seenAlbums: seenAlbums,
            seenArtists: seenArtists,
            modelContext: modelContext
        )

        onProgress(total, total)
        LibraryRebuildState.shared.report(processed: total, total: total)

        // Logged because "the sync didn't remove anything" is otherwise impossible to tell apart
        // from "the sync never ran" or "everything came back again".
        print("""
        LibraryRowBuilder: \(source.name) — \(rawSongs.count) track(s) reported, \
        \(existing.allSongs.count) already held, \(inserted) added, \(deletedCount) removed
        """)
    }

    /// Applies the incoming values to a row that is already there, touching only what differs so
    /// unchanged rows produce no SwiftData change at all.
    private static func update(_ song: Song, from raw: RawSong, album: Album) {
        if song.title != raw.title { song.title = raw.title }
        if song.artist != raw.artist { song.artist = raw.artist }
        if song.albumTitle != raw.album { song.albumTitle = raw.album }
        if song.albumArtist != raw.albumArtist { song.albumArtist = raw.albumArtist }
        if song.track != raw.track { song.track = raw.track }
        if song.duration != raw.duration { song.duration = raw.duration }
        if song.album?.persistentModelID != album.persistentModelID { song.album = album }
    }

    /// Deletes what the sync no longer reports, and any surplus rows sharing an identity.
    ///
    /// Driven from every row fetched, not from the lookup tables. Those keep one row per key, so
    /// duplicates left behind by earlier syncs were discarded when the table was built and the
    /// deletion pass never saw them — they could not be removed by syncing at all.
    @discardableResult
    private static func removeVanishedRows(
        existing: ExistingRows,
        keptSongsByPath: [String: Song],
        keptAlbumsByKey: [AlbumKey: Album],
        keptArtistsByName: [String: Artist],
        seenSongs: Set<String>,
        seenAlbums: Set<AlbumKey>,
        seenArtists: Set<String>,
        modelContext: ModelContext
    ) async throws -> Int {
        var deleted = 0

        for song in existing.allSongs {
            let isStillWanted = seenSongs.contains(song.relativePath)
            let isTheRowKept = keptSongsByPath[song.relativePath]?.persistentModelID == song.persistentModelID
            guard !isStillWanted || !isTheRowKept else { continue }

            modelContext.delete(song)
            deleted += 1
            if deleted.isMultiple(of: saveBatchSize) {
                try modelContext.save()
                await Task.yield()
            }
        }
        try modelContext.save()

        for album in existing.allAlbums {
            let key = AlbumKey(name: album.name, artistName: album.artist?.name ?? "")
            let isStillWanted = seenAlbums.contains(key)
            let isTheRowKept = keptAlbumsByKey[key]?.persistentModelID == album.persistentModelID
            if !isStillWanted || !isTheRowKept {
                modelContext.delete(album)
                deleted += 1
            }
        }
        for artist in existing.allArtists {
            let isStillWanted = seenArtists.contains(artist.name)
            let isTheRowKept = keptArtistsByName[artist.name]?.persistentModelID == artist.persistentModelID
            if !isStillWanted || !isTheRowKept {
                modelContext.delete(artist)
                deleted += 1
            }
        }
        try modelContext.save()
        return deleted
    }

    // MARK: - Existing rows

    /// Every row this source owns: the full lists, so nothing is invisible to the deletion pass,
    /// and lookup tables keyed the way incoming data identifies things.
    private struct ExistingRows {
        var allSongs: [Song]
        var allAlbums: [Album]
        var allArtists: [Artist]
        var songsByPath: [String: Song]
        var albumsByKey: [AlbumKey: Album]
        var artistsByName: [String: Artist]
    }

    private static func existingRows(
        sourceID: PersistentIdentifier,
        modelContext: ModelContext
    ) throws -> ExistingRows {
        let songs = try modelContext.fetch(FetchDescriptor<Song>(
            predicate: #Predicate { $0.source?.persistentModelID == sourceID }
        ))
        let albums = try modelContext.fetch(FetchDescriptor<Album>(
            predicate: #Predicate { $0.source?.persistentModelID == sourceID }
        ))
        let artists = try modelContext.fetch(FetchDescriptor<Artist>(
            predicate: #Predicate { $0.source?.persistentModelID == sourceID }
        ))

        return ExistingRows(
            allSongs: songs,
            allAlbums: albums,
            allArtists: artists,
            songsByPath: Dictionary(songs.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }),
            albumsByKey: Dictionary(
                albums.map { (AlbumKey(name: $0.name, artistName: $0.artist?.name ?? ""), $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            artistsByName: Dictionary(artists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
