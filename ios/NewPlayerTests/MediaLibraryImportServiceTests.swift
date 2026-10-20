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
    /// and grouping by it splits a release across the Artists list. The album artist is what the
    /// album groups under — and the track credit is what each song keeps.
    func testTheAlbumArtistGroupsTheAlbumAndTheTrackKeepsItsOwn() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice & The Band", album: "Record", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice & The Band", album: "Record", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"], "one artist row")
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Alice"])
        XCTAssertEqual(Set(songs.map(\.artist)), ["Alice & The Band"], "the track credit is not overwritten")
    }

    /// The rule reads the album-artist tag, not the track artists. A guest credit used to make
    /// the whole record a compilation, which mislabelled any album with a feature on it.
    func testAFeaturedCreditDoesNotMakeAnAlbumACompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice feat. Bob", album: "Record", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "Record", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Alice"], "the album artist they agree on")
        XCTAssertEqual(Set(songs.map(\.artist)), ["Alice feat. Bob", "Alice"], "each track keeps its own")
    }

    /// A Various Artists record tagged as such is that artist, not a compilation: the tracks
    /// agree on an album artist, which is all the rule asks.
    func testAnAlbumWhoseTracksAgreeOnTheirAlbumArtistUsesIt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Mixtape", albumArtist: "Various", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Mixtape", albumArtist: "Various", track: 2)
        library.addTrack(id: "3", title: "Three", artist: "Carol", album: "Mixtape", albumArtist: "Various", track: 3)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Various"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
        // The point of the change: who actually played each song survives the import.
        XCTAssertEqual(Set(songs.map(\.artist)), ["Alice", "Bob", "Carol"])
    }

    /// No album artist, but one performer throughout: the record is that artist's. Calling it a
    /// compilation would have swamped the Artists list in a patchily tagged library.
    func testAnUntaggedAlbumByOneArtistUsesThatArtist() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Record", albumArtist: nil, track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "Record", albumArtist: nil, track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Alice"])
    }

    /// No album artist and the performers differ: a compilation, and one album.
    func testAnUntaggedAlbumWithSeveralPerformersIsACompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Record", albumID: "rec", albumArtist: nil, track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Record", albumID: "rec", albumArtist: nil, track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.artist)), ["Alice", "Bob"])
    }

    /// Album artists that disagree across one album: a compilation, and crucially *one* album.
    /// Renaming every track "Compilation" is what keeps it together — they all then key to the
    /// same Album row instead of one row per artist.
    func testAnAlbumWhoseAlbumArtistsDisagreeIsOneCompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Split", albumID: "rec", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Split", albumID: "rec", albumArtist: "Bob", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.count, 1, "one album, not one per artist")
        XCTAssertEqual(albums.first?.songs.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Compilation"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Compilation"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.artist)), ["Alice", "Bob"])
    }

    /// Decided per album — one record must not drag another with it.
    func testOnlyTheCompilationAlbumIsAffected() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Mixtape", albumID: "mix", albumArtist: nil, track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Bob", album: "Mixtape", albumID: "mix", albumArtist: nil, track: 2)
        library.addTrack(id: "3", title: "Solo", artist: "Carol", album: "Carol's Record", albumID: "solo", albumArtist: "Carol", track: 1)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        let albumArtists = Dictionary(uniqueKeysWithValues: songs.map { ($0.title, $0.albumArtist) })
        XCTAssertEqual(albumArtists["One"], "Compilation")
        XCTAssertEqual(albumArtists["Two"], "Compilation")
        XCTAssertEqual(albumArtists["Solo"], "Carol")
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

    /// The reported split: Apple Music gives different album IDs to tracks of one album added
    /// by different routes — some purchased, some matched — and grouping on that ID showed the
    /// record twice. Title and album artist hold it together.
    func testOneAlbumWithDifferentAlbumIDsStaysOneAlbum() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let library = FakeMediaLibrary()
        library.addTrack(id: "1", title: "One", artist: "Alice", album: "Record", albumID: "bought", albumArtist: "Alice", track: 1)
        library.addTrack(id: "2", title: "Two", artist: "Alice", album: "Record", albumID: "matched", albumArtist: "Alice", track: 2)

        try await MediaLibraryImportService.rescan(source: source, provider: library, modelContext: context)

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.count, 1, "one album, however the library filed its tracks")
        XCTAssertEqual(albums.first?.songs.count, 2)
    }

    /// Two releases sharing a name are kept apart by their album artists.
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
}
