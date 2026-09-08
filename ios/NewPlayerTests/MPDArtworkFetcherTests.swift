import XCTest
import SwiftData
@testable import NewPlayer

/// Pins the three properties the artwork queue is supposed to have: one download at a time,
/// a screen change discards what the old screen queued, and the new screen's albums are then
/// fetched. A modest MPD host is easily buried by parallel cover downloads, which starves the
/// separate playback connection.
@MainActor
final class MPDArtworkFetcherTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    /// Builds `count` albums, each with one song, all on one network source.
    private func seed(_ count: Int, in context: ModelContext) throws -> (Source, [Album]) {
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        context.insert(source)
        let artist = Artist(name: "A", source: source)
        context.insert(artist)
        var albums: [Album] = []
        for index in 0..<count {
            let album = Album(name: "Album \(index)", artist: artist, source: source)
            context.insert(album)
            context.insert(Song(
                title: "T\(index)", artist: "A", albumTitle: album.name, albumArtist: "A",
                track: 1, duration: 100, relativePath: "a\(index).flac", album: album, source: source
            ))
            albums.append(album)
        }
        try context.save()
        return (source, albums)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testDownloadsHappenOneAtATime() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(6, in: context)

        let mock = MockMPDClient()
        await mock.setArtworkDelay(nanoseconds: 60_000_000)
        await mock.setDefaultArtwork(TestImage.jpegData())

        let fetcher = MPDArtworkFetcher(makeClient: { mock })
        let scope = UUID()
        for album in albums {
            fetcher.fetchIfNeeded(album: album, modelContext: context, scope: scope)
        }

        await waitUntil { await mock.maxConcurrentArtworkFetches > 0 }
        await waitUntil(timeout: 10) { albums.allSatisfy { $0.artwork != nil } }

        let peak = await mock.maxConcurrentArtworkFetches
        XCTAssertEqual(peak, 1, "a second download must not start before the previous one finishes")
    }

    func testChangingScreenDropsTheOldScreensQueue() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(8, in: context)

        let mock = MockMPDClient()
        await mock.setArtworkDelay(nanoseconds: 120_000_000)
        await mock.setDefaultArtwork(TestImage.jpegData())

        let fetcher = MPDArtworkFetcher(makeClient: { mock })
        let firstScreen = UUID()
        for album in albums.prefix(6) {
            fetcher.fetchIfNeeded(album: album, modelContext: context, scope: firstScreen)
        }
        // One download is now in flight; the rest are queued behind it.
        await waitUntil { await mock.artworkFetchCount >= 1 }

        // The user navigates away: what the old screen queued is no longer wanted.
        let secondScreen = UUID()
        fetcher.fetchIfNeeded(album: albums[7], modelContext: context, scope: secondScreen)

        await waitUntil(timeout: 10) { albums[7].artwork != nil }

        let fetchedNames = await mock.artworkFilesFetched
        XCTAssertLessThanOrEqual(
            fetchedNames.count, 3,
            "the abandoned screen's queue should have been dropped, not worked through: \(fetchedNames)"
        )
        XCTAssertNotNil(albums[7].artwork, "the new screen's album should still be fetched")
    }

    func testAlbumsThatAlreadyHaveArtworkAreNotRefetched() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(1, in: context)
        albums[0].artwork = TestImage.jpegData()
        try context.save()

        let mock = MockMPDClient()
        await mock.setDefaultArtwork(TestImage.jpegData())
        let fetcher = MPDArtworkFetcher(makeClient: { mock })
        fetcher.fetchIfNeeded(album: albums[0], modelContext: context, scope: UUID())

        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await mock.artworkFetchCount
        XCTAssertEqual(count, 0)
    }

    /// A server with no cover for an album must not be asked again and again as the row scrolls
    /// past — that was a full multi-track probe every time, for nothing.
    func testAnAlbumWithNoArtworkIsNotProbedRepeatedly() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(1, in: context)

        let mock = MockMPDClient()
        await mock.setDefaultArtwork(nil) // server has nothing
        let fetcher = MPDArtworkFetcher(makeClient: { mock })

        fetcher.fetchIfNeeded(album: albums[0], modelContext: context, scope: UUID())
        await waitUntil { await mock.artworkFetchCount >= 1 }
        let afterFirst = await mock.artworkFetchCount

        fetcher.fetchIfNeeded(album: albums[0], modelContext: context, scope: UUID())
        try await Task.sleep(nanoseconds: 200_000_000)

        let afterSecond = await mock.artworkFetchCount
        XCTAssertEqual(afterSecond, afterFirst, "a known-missing cover must not be probed again")
    }

    /// An unreachable host must not cost one connection attempt per queued album — that is a
    /// burst of connects at exactly the moment the server is least able to take them.
    func testAnUnreachableHostIsNotRetriedOncePerQueuedAlbum() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(10, in: context)

        let mock = MockMPDClient()
        await mock.setConnectError(MPDError.connectionFailed("refused"))

        let fetcher = MPDArtworkFetcher(makeClient: { mock })
        let scope = UUID()
        for album in albums {
            fetcher.fetchIfNeeded(album: album, modelContext: context, scope: scope)
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        let connects = await mock.calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count
        XCTAssertLessThanOrEqual(connects, 2, "should back off, not try once per album (got \(connects))")
    }

    /// And having backed off, the work is not lost: the next request drains the queue.
    func testTheQueueSurvivesAFailedConnectionAndResumes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (_, albums) = try seed(3, in: context)

        let mock = MockMPDClient()
        await mock.setConnectError(MPDError.connectionFailed("refused"))
        let fetcher = MPDArtworkFetcher(makeClient: { mock })
        let scope = UUID()
        for album in albums {
            fetcher.fetchIfNeeded(album: album, modelContext: context, scope: scope)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(albums.allSatisfy { $0.artwork == nil })

        // Host comes back; a new request (a scroll, say) restarts the drain.
        await mock.setConnectError(nil)
        await mock.setDefaultArtwork(TestImage.jpegData())
        fetcher.fetchIfNeeded(album: albums[0], modelContext: context, scope: scope)

        await waitUntil(timeout: 10) { albums.allSatisfy { $0.artwork != nil } }
        XCTAssertTrue(albums.allSatisfy { $0.artwork != nil }, "queued albums should still be fetched")
    }
}
