import XCTest
import SwiftData
@testable import NewPlayer

/// The merge replaced a wipe-and-reinsert, so what matters most is what it *doesn't* do: it
/// doesn't delete and recreate rows that haven't changed, doesn't throw away artwork it already
/// holds, and doesn't gut the library when a sync goes wrong.
@MainActor
final class LibraryMergeTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeSource(in context: ModelContext) throws -> Source {
        let source = Source(name: "Spotify", isActive: true, kind: .spotify)
        context.insert(source)
        try context.save()
        return source
    }

    private func raw(
        _ id: String,
        title: String? = nil,
        album: String = "Record",
        albumArtist: String = "Alice",
        track: Int = 1,
        artwork: Data? = nil,
        artworkURL: String? = nil
    ) -> RawSong {
        RawSong(
            title: title ?? id,
            artist: albumArtist,
            album: album,
            albumArtist: albumArtist,
            track: track,
            duration: 200,
            relativePath: id,
            artworkData: artwork,
            artworkURL: artworkURL
        )
    }

    /// Rows that haven't changed keep their identity. Under the old wipe every row was destroyed
    /// and rebuilt, which is what made a re-sync cost the size of the library rather than the
    /// size of the change.
    func testUnchangedSongsKeepTheirIdentity() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a"), raw("b")], source: source, modelContext: context)
        let firstPass = try context.fetch(FetchDescriptor<Song>())
        let idsBefore = Set(firstPass.map(\.persistentModelID))

        try await LibraryRowBuilder.merge(from: [raw("a"), raw("b")], source: source, modelContext: context)
        let secondPass = try context.fetch(FetchDescriptor<Song>())

        XCTAssertEqual(Set(secondPass.map(\.persistentModelID)), idsBefore,
                       "an unchanged sync should leave the same rows in place")
    }

    /// A cover already held is kept rather than decoded again — the expense the merge exists to
    /// avoid, and what made a second sync of a large library lock the app up.
    func testExistingArtworkIsKeptAndNotReprocessed() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let cover = TestImage.jpegData()
        try await LibraryRowBuilder.merge(from: [raw("a", artwork: cover)], source: source, modelContext: context)

        let album = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        let storedArtwork = album.artwork
        XCTAssertNotNil(storedArtwork)

        // A later sync carries no artwork at all, as the Spotify one does.
        try await LibraryRowBuilder.merge(from: [raw("a")], source: source, modelContext: context)

        let after = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertEqual(after.artwork, storedArtwork, "the cover should survive a re-sync untouched")
    }

    /// A cover that is missing is still filled in when one turns up.
    func testMissingArtworkIsFilledInWhenItArrives() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a")], source: source, modelContext: context)
        XCTAssertNil(try context.fetch(FetchDescriptor<Album>()).first?.artwork)

        try await LibraryRowBuilder.merge(
            from: [raw("a", artwork: TestImage.jpegData())],
            source: source,
            modelContext: context
        )
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Album>()).first?.artwork)
    }

    func testChangedFieldsAreUpdatedInPlace() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a", title: "Old Title")], source: source, modelContext: context)
        let original = try XCTUnwrap(try context.fetch(FetchDescriptor<Song>()).first)
        let id = original.persistentModelID

        try await LibraryRowBuilder.merge(from: [raw("a", title: "New Title")], source: source, modelContext: context)

        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<Song>()).first)
        XCTAssertEqual(updated.title, "New Title")
        XCTAssertEqual(updated.persistentModelID, id, "it should be the same row, edited")
    }

    /// Tracks removed from the account are removed here too.
    func testVanishedSongsAreDeleted() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a"), raw("b"), raw("c")], source: source, modelContext: context)
        try await LibraryRowBuilder.merge(from: [raw("a"), raw("c")], source: source, modelContext: context)

        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.relativePath)), ["a", "c"])
    }

    /// And an album whose every track has gone should go with them, rather than lingering empty.
    func testAlbumsAndArtistsWithNothingLeftAreRemoved() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(
            from: [raw("a", album: "First", albumArtist: "Alice"),
                   raw("b", album: "Second", albumArtist: "Bob")],
            source: source,
            modelContext: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 2)

        try await LibraryRowBuilder.merge(
            from: [raw("a", album: "First", albumArtist: "Alice")],
            source: source,
            modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).map(\.name), ["First"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"])
    }

    /// One source's rows are none of another's business.
    func testAnotherSourcesLibraryIsUntouched() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let spotify = try makeSource(in: context)
        let local = Source(name: "Local", kind: .local)
        context.insert(local)
        try context.save()

        try await LibraryRowBuilder.merge(from: [raw("a")], source: local, modelContext: context)
        try await LibraryRowBuilder.merge(from: [raw("z")], source: spotify, modelContext: context)
        try await LibraryRowBuilder.merge(from: [], source: spotify, modelContext: context)

        let localSongs = try context.fetch(FetchDescriptor<Song>()).filter { $0.source?.kind == .local }
        XCTAssertEqual(localSongs.map(\.relativePath), ["a"], "emptying one source must not touch another")
    }

    /// The point of merging over wiping: a sync that never delivers can't destroy what's there.
    /// The old builder deleted everything before it inserted anything.
    func testAFailedFetchLeavesTheExistingLibraryIntact() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a"), raw("b")], source: source, modelContext: context)

        // A sync that fails before producing rows never reaches the merge at all — which is the
        // behaviour worth pinning, since the old builder had already deleted by this point.
        let client = FakeSpotifyClient()
        client.accountError = SpotifyError.requestFailed("network down")
        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            ))
        )
        viewModel.connectSpotify(clientID: "abc", existingSource: source, allSources: [source], modelContext: context)

        let deadline = Date().addingTimeInterval(5)
        while viewModel.errorMessage == nil && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 2,
                       "a failed sync must leave the library it couldn't replace")
    }

    // MARK: - Clearing out what Spotify no longer has

    /// Albums removed from the account go with their tracks, rather than lingering as empty rows
    /// in Albums and Artists.
    func testAnAlbumRemovedFromTheAccountDisappearsEntirely() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(
            from: [raw("a", album: "Kept", albumArtist: "Alice"),
                   raw("b", album: "Removed", albumArtist: "Bob")],
            source: source,
            modelContext: context
        )

        try await LibraryRowBuilder.merge(
            from: [raw("a", album: "Kept", albumArtist: "Alice")],
            source: source,
            modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.relativePath), ["a"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).map(\.name), ["Kept"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"])
    }

    /// Everything going means everything goes.
    func testAnEmptyAccountEmptiesTheLibrary() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        try await LibraryRowBuilder.merge(from: [raw("a"), raw("b")], source: source, modelContext: context)
        try await LibraryRowBuilder.merge(from: [], source: source, modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Song>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Artist>()).isEmpty)
    }
}
