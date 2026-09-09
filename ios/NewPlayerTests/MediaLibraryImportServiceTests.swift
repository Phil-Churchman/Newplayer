import XCTest
import SwiftData
@testable import NewPlayer

@MainActor
final class MediaLibraryImportServiceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeSource(in context: ModelContext) throws -> Source {
        let source = Source(name: "Music Library", isActive: true, kind: .mediaLibrary)
        context.insert(source)
        try context.save()
        return source
    }

    func testImportsTracksIntoTheSharedSchema() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "First", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "First", track: 2)
        library.addTrack(id: "3", title: "Three", artist: "Bob", album: "Second", track: 1)

        let result = try await MediaLibraryImportService.rescan(
            source: source, provider: library, modelContext: context
        )

        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).count, 2)
    }

    /// The persistent ID is what makes a track findable again at playback time; asset URLs are
    /// not durable, so the ID is what has to be stored.
    func testSongsStoreTheLibraryPersistentID() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "998877", title: "One")

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let song = try XCTUnwrap(try context.fetch(FetchDescriptor<Song>()).first)
        XCTAssertEqual(song.relativePath, "998877")
    }

    /// DRM'd Apple Music items have no local asset. Importing them would fill the library with
    /// rows that silently fail to play.
    func testProtectedItemsAreSkippedAndCounted() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "Owned")
        library.addTrack(id: "2", title: "Apple Music", playable: false)
        library.addTrack(id: "3", title: "Also Apple Music", playable: false)

        let result = try await MediaLibraryImportService.rescan(
            source: source, provider: library, modelContext: context
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skippedProtected, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.title), ["Owned"])
    }

    /// Only one cover per album is ever kept, so rendering one per track would be thousands of
    /// full-size image renders thrown straight away.
    func testArtworkIsRenderedOncePerAlbumNotOncePerTrack() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        for index in 1...10 {
            library.addTrack(id: "\(index)", title: "T\(index)", album: "One Album", track: index)
        }
        for index in 11...15 {
            library.addTrack(id: "\(index)", title: "T\(index)", album: "Other Album", track: index)
        }

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(library.artworkRenderCount, 2, "one render per album, not per track")
    }

    func testUntaggedTracksStillAppear() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.tracks = [MediaLibraryTrack(
            persistentID: "1", albumPersistentID: "", title: nil, artist: nil, albumTitle: nil, albumArtist: nil,
            trackNumber: 0, duration: 100, isPlayableLocally: true
        )]
        library.assetURLs["1"] = URL(string: "ipod-library://item/item.m4a?id=1")!

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let song = try XCTUnwrap(try context.fetch(FetchDescriptor<Song>()).first)
        XCTAssertEqual(song.artist, "Unknown Artist")
        XCTAssertEqual(song.albumTitle, "Unknown Album")
    }

    func testPermissionIsRequestedOnlyWhenNotYetAnswered() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary(access: nil) // never asked
        library.addTrack(id: "1", title: "One")

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)
        XCTAssertEqual(library.requestCount, 1)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)
        XCTAssertEqual(library.requestCount, 1, "already answered — don't ask again")
    }

    func testDeniedAccessThrowsRatherThanImportingNothingSilently() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary(access: .denied)

        do {
            try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)
            XCTFail("expected accessDenied")
        } catch {
            XCTAssertEqual(error as? MediaLibraryImportError, .accessDenied)
        }
    }

    /// A re-import replaces the previous contents rather than accumulating.
    func testReimportReplacesPreviousRows() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One")
        library.addTrack(id: "2", title: "Two")
        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        library.tracks.removeLast()
        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.title), ["One"])
    }

    // MARK: - Album artist, compilations, and album covers

    /// iTunes libraries are tagged album-first: the per-track artist is often a featured credit,
    /// and grouping by it splits a release across the Artists list. The album artist therefore
    /// names the release — while each row keeps its own performer, asserted separately.
    func testTheAlbumArtistNamesTheRelease() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        // One consistent track credit that differs from the album artist — the album artist wins.
        library.addTrack(id: "1", title: "One", artist: "Alice & The Band", album: "Record", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice & The Band", album: "Record", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Alice"], "the album artist names the release")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"])
    }

    /// Documents a consequence of the compilation rule rather than endorsing it: the rule keys
    /// purely on the number of distinct *track* artists, so a single-artist album carrying one
    /// "feat." credit is labelled a compilation too, even though every track shares an album
    /// artist. Whether that is wanted depends on how the library tags featured guests — if they
    /// live in the track title rather than the artist field, this never fires.
    func testAFeaturedCreditAlsoCountsAsMultipleTrackArtists() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice feat. Bob", album: "Record", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "Record", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Compilation"])
    }

    /// A Various Artists record would otherwise appear once per guest in the Artists list.
    func testAnAlbumWithSeveralTrackArtistsBecomesACompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Mixtape", albumArtist: "Various", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Mixtape", albumArtist: "Various", track: 2)
        library.addTrack(id: "3", title: "Three", artist: "Carol", album: "Mixtape", albumArtist: "Various", track: 3)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Compilation"], "every track in the album, not just some")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
    }

    /// One artist across the album is an ordinary record, however it is tagged.
    func testAnAlbumWithOneTrackArtistIsNotACompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Record", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "Record", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Alice"])
    }

    /// Compilations are decided per album — a mixed record must not drag a normal one with it.
    func testOnlyTheCompilationAlbumIsAffected() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Mixtape", albumID: "mix", albumArtist: "Various", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Mixtape", albumID: "mix", albumArtist: "Various", track: 2)
        library.addTrack(id: "3", title: "Solo", artist: "Carol", album: "Carol's Record", albumID: "solo", albumArtist: "Carol", track: 1)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        // Compared on albumArtist: that is what the compilation rule sets, while `artist` stays
        // the track's own performer.
        let byTitle = Dictionary(uniqueKeysWithValues: songs.map { ($0.title, $0.albumArtist) })
        XCTAssertEqual(byTitle["One"], "Compilation")
        XCTAssertEqual(byTitle["Two"], "Compilation")
        XCTAssertEqual(byTitle["Solo"], "Carol")
    }

    /// The cover comes from track 1, and every track in the album shows it — the library hands
    /// tracks back unordered, so this must not depend on query order.
    func testTheAlbumCoverComesFromTheFirstTrackAndAppliesToAllOfThem() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let firstTrackArt = TestImage.jpegData(width: 80, height: 80)
        let library = FakeMediaLibrary()
        // Deliberately added out of order, with different art on a later track.
        library.addTrack(id: "3", title: "Three", album: "Record", track: 3, artwork: TestImage.jpegData(width: 40, height: 40))
        library.addTrack(id: "1", title: "One", album: "Record", track: 1, artwork: firstTrackArt)
        library.addTrack(id: "2", title: "Two", album: "Record", track: 2, artwork: nil)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let album = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertNotNil(album.artwork, "the album should have the first track's cover")
        XCTAssertNotNil(album.thumbnail)

        // Every song in the album resolves its art through that one album row.
        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 3)
        XCTAssertTrue(songs.allSatisfy { $0.album?.artwork != nil })

        XCTAssertEqual(library.artworkRenderCount, 1, "one render for the album, from its first track")
    }

    /// Two releases sharing a name are kept apart by the library's own album identity.
    func testTwoAlbumsWithTheSameNameAreNotMerged() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "A", artist: "Alice", album: "Greatest Hits", albumID: "alice-hits", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "B", artist: "Bob", album: "Greatest Hits", albumID: "bob-hits", albumArtist: "Bob", track: 1)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 2)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Artist>()).map(\.name)), ["Alice", "Bob"])
    }

    /// Guards the bug that shipped: covers were fetched through a closure capturing the
    /// MPMediaItemArtwork, which nothing retained, so it was deallocated before the closure ran
    /// and every album imported without art. Artwork is now looked up by track ID at the moment
    /// it is needed — this asserts the import actually asks, and stores what comes back.
    func testTheImportAsksTheLibraryForTheFirstTracksCoverAndStoresIt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let cover = TestImage.jpegData(width: 300, height: 300)
        let library = FakeMediaLibrary()
        library.addTrack(id: "10", title: "One", album: "Record", track: 1, artwork: cover)
        library.addTrack(id: "11", title: "Two", album: "Record", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(library.artworkRequests, ["10"], "asked for the first track's cover, once")
        let album = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertNotNil(album.artwork, "the cover the library returned should have been saved")
        XCTAssertNotNil(album.thumbnail)
    }

    /// The same rule for the Music library: rows show the track's performer, while the release
    /// artist still names the album and groups the Artists screen.
    func testEachTrackKeepsItsOwnArtist() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Mixtape", albumArtist: "Various", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Mixtape", albumArtist: "Various", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>()).sorted { $0.track < $1.track }
        XCTAssertEqual(songs.map(\.artist), ["Alice", "Bob"])
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
    }

    // MARK: - Confirming tracks open, during the scan

    /// The metadata checks are answered from the library's own records. A track can satisfy them
    /// and still refuse to open — an encoding AVFoundation won't decode, or a download the
    /// system has evicted. Caught during the scan rather than on a tap.
    func testATrackThatWontOpenIsExcludedByTheScan() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "good", title: "Plays")
        library.addTrack(id: "broken", title: "Refuses")
        library.unopenableIDs = ["broken"]

        let result = try await MediaLibraryImportService.rescan(
            source: source, provider: library, modelContext: context
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skippedUnplayable, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.title), ["Plays"])
    }

    /// Every candidate is checked — a track quietly assumed good is the case this exists to stop.
    func testEveryCandidateIsChecked() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        for index in 1...20 {
            library.addTrack(id: "\(index)", title: "T\(index)", track: index)
        }

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(Set(library.playabilityChecks).count, 20)
    }

    /// DRM and undownloaded tracks are ruled out before any of this, so they cost no checks.
    func testTracksRuledOutByMetadataAreNotChecked() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "playable", title: "Plays")
        library.addTrack(id: "protected", title: "Apple Music", playable: false)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(library.playabilityChecks, ["playable"])
    }

    /// Checking happens in batches, so order must be restored afterwards — track order decides
    /// which cover an album takes.
    func testTrackOrderSurvivesTheConcurrentCheck() async {
        let library = FakeMediaLibrary()
        for index in 1...25 {
            library.addTrack(id: "\(index)", title: "T\(index)", track: index)
        }

        let verified = await MediaLibraryImportService.verifiedPlayable(library.tracks, provider: library)

        XCTAssertEqual(verified.map(\.persistentID), library.tracks.map(\.persistentID))
    }
}
