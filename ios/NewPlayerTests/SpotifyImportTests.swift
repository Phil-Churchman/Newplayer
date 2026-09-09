import XCTest
import SwiftData
@testable import NewPlayer

@MainActor
final class SpotifyImportTests: XCTestCase {
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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSavedTracksLandInTheSharedSchema() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [
            .make(id: "1", title: "One", track: 1),
            .make(id: "2", title: "Two", track: 2),
            .make(id: "3", title: "Other", artist: "Bob", album: "Second", albumID: "album-2"),
        ]

        let result = try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 2)
    }

    /// The track's Spotify ID is stored, so a row can always be traced back to the catalogue.
    func testTheSpotifyTrackIDIsStored() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "spotify-track-42", title: "One")]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        let song = try XCTUnwrap(try context.fetch(FetchDescriptor<Song>()).first)
        XCTAssertEqual(song.relativePath, "spotify-track-42")
    }

    /// Same album-wide rules as the Music library import.
    func testAnAlbumWithSeveralTrackArtistsBecomesACompilation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [
            .make(id: "1", title: "One", artist: "Alice", albumID: "mix", albumArtist: "Various", track: 1),
            .make(id: "2", title: "Two", artist: "Bob", albumID: "mix", albumArtist: "Various", track: 2),
        ]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Compilation"])
    }

    /// The sync records where the cover lives; it does not fetch it.
    func testASyncRecordsTheCoverURLWithoutDownloadingIt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let url = URL(string: "https://i.scdn.co/image/album-1")!
        let client = FakeSpotifyClient()
        client.artworkByURL = [url: TestImage.jpegData()]
        client.tracks = (1...5).map {
            .make(id: "\($0)", title: "T\($0)", track: $0, artworkURL: url)
        }

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        // Nothing is downloaded during a sync any more: the URL is recorded and the cover
        // fetched when the album is first shown.
        XCTAssertTrue(client.artworkRequests.isEmpty, "a sync must not download covers")
        let album = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertEqual(album.artworkURL, url.absoluteString)
        XCTAssertNil(album.artwork, "the cover is fetched lazily, not during the sync")
    }

    /// An album whose cover fails to download still imports its tracks.
    func testTracksStillImportWhenArtworkFails() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient() // knows no artwork, so every fetch throws
        client.tracks = [.make(id: "1", title: "One", artworkURL: URL(string: "https://i.scdn.co/image/x")!)]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 1)
    }

    // MARK: - Sign-in

    func testAFreeAccountIsRefusedBeforeAnythingIsImported() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let auth = FakeSpotifyAuth()
        let client = FakeSpotifyClient()
        client.account = SpotifyAccount(displayName: "Phil", product: "free")
        client.tracks = [.make(id: "1", title: "One")]

        let viewModel = SourcesViewModel(
            spotifyAuth: auth, spotifyClient: client, spotifyTokens: InMemorySpotifyTokenStore()
        )
        viewModel.connectSpotify(clientID: "abc123", existingSource: nil, allSources: [], modelContext: context)

        await waitUntil { viewModel.errorMessage != nil }

        XCTAssertTrue(viewModel.errorMessage?.contains("Premium") == true, "got: \(viewModel.errorMessage ?? "nil")")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Song>()).isEmpty, "nothing should be imported")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Source>()).isEmpty, "no half-made source left behind")
    }

    func testAPremiumAccountImportsAndBecomesTheActiveSource() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let auth = FakeSpotifyAuth()
        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "1", title: "One"), .make(id: "2", title: "Two", track: 2)]

        let viewModel = SourcesViewModel(
            spotifyAuth: auth, spotifyClient: client, spotifyTokens: InMemorySpotifyTokenStore()
        )
        viewModel.connectSpotify(clientID: "abc123", existingSource: nil, allSources: [], modelContext: context)

        await waitUntil { viewModel.spotifyImportSummary != nil }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 2)
        let source = try XCTUnwrap(try context.fetch(FetchDescriptor<Source>()).first)
        XCTAssertEqual(source.kind, .spotify)
        XCTAssertTrue(source.isActive)
        XCTAssertEqual(source.spotifyAccountName, "Phil")
    }

    /// A stored token is reused rather than sending the user back to the browser.
    func testAValidStoredTokenSkipsTheBrowserSignIn() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let auth = FakeSpotifyAuth()
        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "1", title: "One")]
        let store = InMemorySpotifyTokenStore(tokens: SpotifyTokens(
            accessToken: "stored", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)
        ))

        let viewModel = SourcesViewModel(spotifyAuth: auth, spotifyClient: client, spotifyTokens: store)
        viewModel.connectSpotify(clientID: "abc123", existingSource: nil, allSources: [], modelContext: context)

        await waitUntil { viewModel.spotifyImportSummary != nil }
        XCTAssertEqual(auth.signInCount, 0, "a valid token shouldn't reopen the sign-in page")
    }

    /// An expired token is refreshed silently; only a failed refresh reopens the browser.
    func testAnExpiredTokenIsRefreshedWithoutSigningInAgain() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let auth = FakeSpotifyAuth()
        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "1", title: "One")]
        let store = InMemorySpotifyTokenStore(tokens: SpotifyTokens(
            accessToken: "stale", refreshToken: "r", expiresAt: Date().addingTimeInterval(-10)
        ))

        let viewModel = SourcesViewModel(spotifyAuth: auth, spotifyClient: client, spotifyTokens: store)
        viewModel.connectSpotify(clientID: "abc123", existingSource: nil, allSources: [], modelContext: context)

        await waitUntil { viewModel.spotifyImportSummary != nil }
        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(auth.signInCount, 0)
    }

    func testMissingClientIDIsReportedWithoutTouchingTheNetwork() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let auth = FakeSpotifyAuth()
        let viewModel = SourcesViewModel(
            spotifyAuth: auth, spotifyClient: FakeSpotifyClient(), spotifyTokens: InMemorySpotifyTokenStore()
        )
        viewModel.connectSpotify(clientID: "   ", existingSource: nil, allSources: [], modelContext: context)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(auth.signInCount, 0)
    }

    // MARK: - What counts as "the library"

    /// The reported gap: a Spotify library is Liked Songs *and* saved albums. The albums'
    /// tracks are not in /me/tracks, so fetching only that imported a fraction of what the
    /// user sees in Spotify.
    func testSavedAlbumsAreImportedAsWellAsLikedSongs() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "liked-1", title: "Liked One")]
        client.savedAlbumTracks = [
            .make(id: "album-track-1", title: "Album One", albumID: "saved-album", track: 1),
            .make(id: "album-track-2", title: "Album Two", albumID: "saved-album", track: 2),
        ]

        let result = try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(result.imported, 3)
        let titles = Set(try context.fetch(FetchDescriptor<Song>()).map(\.title))
        XCTAssertEqual(titles, ["Liked One", "Album One", "Album Two"])
    }

    /// Liking a track from an album you have also saved must not import it twice.
    func testATrackInBothLikedSongsAndASavedAlbumIsImportedOnce() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "shared", title: "Both")]
        client.savedAlbumTracks = [.make(id: "shared", title: "Both")]

        let result = try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 1)
    }

    func testDeduplicationKeepsTheFirstOccurrenceAndOrder() {
        let tracks: [SpotifyTrack] = [
            .make(id: "a", title: "A"),
            .make(id: "b", title: "B"),
            .make(id: "a", title: "A again"),
        ]
        let deduped = SpotifyImportService.deduplicated(tracks)
        XCTAssertEqual(deduped.map(\.id), ["a", "b"])
        XCTAssertEqual(deduped.first?.title, "A")
    }

    // MARK: - Device selection in Sources

    func testLoadingDevicesListsWhatSpotifyCanSee() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.devices = [
            SpotifyDevice(id: "phone-1", name: "Phil's iPhone", isActive: true, isRestricted: false, type: "Smartphone"),
            SpotifyDevice(id: "speaker", name: "Kitchen", isActive: false, isRestricted: false, type: "Speaker"),
        ]

        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            ))
        )
        viewModel.loadSpotifyDevices(source: source)

        await waitUntil { viewModel.spotifyDevices.count == 2 }
        XCTAssertEqual(viewModel.spotifyDevices.map(\.name), ["Phil's iPhone", "Kitchen"])
        // A note always accompanies the list now: it can legitimately be shorter than the one in
        // the Spotify app, and that needs explaining rather than leaving the user to wonder.
        XCTAssertNotNil(viewModel.spotifyDeviceMessage)
    }

    /// Loading devices runs when the screen appears, so it must never prompt for sign-in.
    func testLoadingDevicesNeverOpensASignInPage() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let auth = FakeSpotifyAuth()
        let viewModel = SourcesViewModel(
            spotifyAuth: auth,
            spotifyClient: FakeSpotifyClient(),
            spotifyTokens: InMemorySpotifyTokenStore() // nothing stored
        )
        viewModel.loadSpotifyDevices(source: source)

        await waitUntil { viewModel.isLoadingSpotifyDevices == false }
        XCTAssertEqual(auth.signInCount, 0)
        XCTAssertNotNil(viewModel.spotifyDeviceMessage, "it should say why the list is empty")
    }

    /// The choice is remembered on the source, so it survives relaunching.
    func testChoosingADeviceIsPersistedOnTheSource() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: FakeSpotifyClient(),
            spotifyTokens: InMemorySpotifyTokenStore()
        )
        viewModel.selectSpotifyDevice("speaker", source: source, modelContext: context)
        XCTAssertEqual(source.spotifyDeviceID, "speaker")

        viewModel.selectSpotifyDevice(nil, source: source, modelContext: context)
        XCTAssertNil(source.spotifyDeviceID)
    }

    /// Selecting the source hands the remembered device to the player, or nothing would use it.
    func testTheRememberedDeviceIsGivenToThePlayerWhenTheSourceBecomesActive() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = Source(name: "Spotify", isActive: true, kind: .spotify)
        source.spotifyClientID = "abc"
        source.spotifyDeviceID = "speaker"

        manager.setActiveSource(source)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(remote.selectedDeviceID, "speaker")
    }

    /// Signing in again must reuse the Spotify source that already exists. Creating a second one
    /// leaves the first and its whole library behind, so a sync appears to add and remove
    /// nothing — the library on screen belongs to the abandoned source.
    func testSigningInAgainReusesTheExistingSpotifySource() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let existing = try makeSource(in: context)
        existing.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "1", title: "One")]

        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            ))
        )
        // As the sign-in button does: no source passed in.
        viewModel.connectSpotify(clientID: "abc", existingSource: nil, allSources: [existing], modelContext: context)

        await waitUntil { viewModel.spotifyImportSummary != nil }

        let spotifySources = try context.fetch(FetchDescriptor<Source>()).filter { $0.kind == .spotify }
        XCTAssertEqual(spotifySources.count, 1, "there should never be two Spotify sources")
        XCTAssertEqual(spotifySources.first?.persistentModelID, existing.persistentModelID)
    }

    /// The whole point of a re-sync: what has gone from the account goes from here.
    func testResyncingRemovesWhatIsNoLongerInTheAccount() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "1", title: "One"), .make(id: "2", title: "Two")]
        client.savedAlbumTracks = [.make(id: "3", title: "Three", album: "Saved", albumID: "saved")]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 3)

        // The user unlikes one track and removes the saved album.
        client.tracks = [.make(id: "1", title: "One")]
        client.savedAlbumTracks = []

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.relativePath), ["1"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1, "the removed album should go")
    }

    // MARK: - Track artist versus release artist

    /// A track row is about the track, so it shows that track's performer. The release artist
    /// still names the album and groups the Artists screen — showing it against every track hid
    /// exactly the difference a compilation exists to express.
    func testEachTrackKeepsItsOwnArtist() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [
            .make(id: "1", title: "One", artist: "Alice", albumID: "mix", albumArtist: "Various", track: 1),
            .make(id: "2", title: "Two", artist: "Bob", albumID: "mix", albumArtist: "Various", track: 2),
        ]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        let songs = try context.fetch(FetchDescriptor<Song>()).sorted { $0.track < $1.track }
        XCTAssertEqual(songs.map(\.artist), ["Alice", "Bob"], "each row shows its own performer")
        // The release is still one album, grouped under one artist.
        XCTAssertEqual(Set(songs.map(\.albumArtist)), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Compilation"])
    }

    /// A track with no artist of its own falls back to the release artist rather than blank.
    func testATrackWithNoArtistFallsBackToTheReleaseArtist() {
        let track = SpotifyTrack(
            id: "1", title: "One", artistNames: [], albumName: "Record",
            albumArtistNames: ["Alice"], trackNumber: 1, durationSeconds: 200,
            albumID: "a", albumArtworkURL: nil
        )
        let rows = SpotifyImportService.makeRawSongs(from: [track])
        XCTAssertEqual(rows.first?.artist, "Alice")
    }
}
