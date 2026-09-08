import XCTest
import SwiftData
@testable import NewPlayer

@MainActor
final class MPDLibrarySyncServiceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testRescanImportsSongsFromServerWithFallbackMetadata() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "192.168.1.50", port: 6600, kind: .network)
        context.insert(source)
        try context.save()

        let mock = MockMPDClient()
        await mock.setSongs([
            MPDSongInfo(file: "Artist A/Album A/01.flac", title: "Song One", artist: "Artist A", album: "Album A", albumArtist: "Artist A", track: 1, duration: 200),
            MPDSongInfo(file: "Artist A/Album A/02.flac", title: "Song Two", artist: "Artist A", album: "Album A", albumArtist: "Artist A", track: 2, duration: 210),
            MPDSongInfo(file: "untagged.flac", title: nil, artist: nil, album: nil, albumArtist: nil, track: nil, duration: 90),
        ])

        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(songs.map(\.title), ["Song One", "Song Two", "untagged"])

        let untagged = try XCTUnwrap(songs.first { $0.relativePath == "untagged.flac" })
        XCTAssertEqual(untagged.artist, "Unknown Artist")
        XCTAssertEqual(untagged.albumTitle, "Unknown Album")

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(Set(albums.map(\.name)), ["Album A", "Unknown Album"])

        XCTAssertEqual(source.lastSyncStatus, .success)
    }

    func testRescanNeverFetchesArtwork() async throws {
        // Artwork is deliberately left for on-demand fetching (MPDArtworkFetcher) when an
        // Artist/Album view actually shows a given album, since fetching it eagerly for every
        // album during the sync is what made large-library syncs take too long to look like
        // they'd ever finish.
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "host", port: 6600, kind: .network)
        context.insert(source)
        try context.save()

        let mock = MockMPDClient()
        await mock.setSongs([
            MPDSongInfo(file: "A/Al/01.flac", title: "One", artist: "A", album: "Al", albumArtist: "A", track: 1, duration: 100),
            MPDSongInfo(file: "A/Al/02.flac", title: "Two", artist: "A", album: "Al", albumArtist: "A", track: 2, duration: 100),
        ])
        let fakeArtwork = try XCTUnwrap("fake-art".data(using: .utf8))
        await mock.setArtwork(["A/Al/01.flac": fakeArtwork])

        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context)

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.count, 1)
        XCTAssertNil(albums.first?.artwork)

        let calls = await mock.calls
        XCTAssertFalse(calls.contains { if case .fetchAlbumArt = $0 { return true } else { return false } })
    }

    /// Progress is reported per save-batch rather than per song — per song it published a view
    /// update for every track, which is a few thousand invalidations for a label showing one
    /// number. What callers actually rely on is that progress arrives and ends at the total.
    func testRescanReportsProgressEndingAtTheTotal() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "host", port: 6600, kind: .network)
        context.insert(source)
        try context.save()

        let mock = MockMPDClient()
        await mock.setSongs([
            MPDSongInfo(file: "1.flac", title: "One", artist: "A", album: "Al", albumArtist: "A", track: 1, duration: 100),
            MPDSongInfo(file: "2.flac", title: "Two", artist: "A", album: "Al", albumArtist: "A", track: 2, duration: 100),
            MPDSongInfo(file: "3.flac", title: "Three", artist: "A", album: "Al", albumArtist: "A", track: 3, duration: 100),
        ])

        var progressUpdates: [(Int, Int)] = []
        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context) { processed, total in
            progressUpdates.append((processed, total))
        }

        XCTAssertFalse(progressUpdates.isEmpty, "the sync screen needs progress to show")
        XCTAssertEqual(progressUpdates.last?.0, 3, "progress must finish at the song count")
        XCTAssertTrue(progressUpdates.allSatisfy { $0.1 == 3 })
    }

    func testRescanWipesPreviousRowsForSameSource() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "host", port: 6600, kind: .network)
        context.insert(source)
        try context.save()

        let mock = MockMPDClient()
        await mock.setSongs([
            MPDSongInfo(file: "old.flac", title: "Old Track", artist: "A", album: "Al", albumArtist: "A", track: 1, duration: 100),
        ])
        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 1)

        await mock.setSongs([
            MPDSongInfo(file: "new.flac", title: "New Track", artist: "A", album: "Al", albumArtist: "A", track: 1, duration: 100),
        ])
        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.title, "New Track")
    }

    func testRescanMarksFailedWhenServerThrows() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "host", port: 6600, kind: .network)
        context.insert(source)
        try context.save()

        let mock = MockMPDClient()
        await mock.setSongsError(MPDError.serverError("ACK boom"))

        await MPDLibrarySyncService.rescan(source: source, client: mock, modelContext: context)

        XCTAssertEqual(source.lastSyncStatus, .failed)
    }
}
