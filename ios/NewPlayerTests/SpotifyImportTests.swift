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

        // Filed as one compilation: a single Artist row, and one Album under it.
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.albumArtist)), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Compilation"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Album>()).count, 1)
    }

    /// Filing an album as a compilation must not cost the tracks their performers.
    ///
    /// Every row used to be written with the album's name — so a compilation's songs all read
    /// "Compilation" and who actually played each one was gone from the library entirely.
    func testACompilationKeepsEachTracksOwnArtist() async throws {
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

        let byTitle = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Song>()).map { ($0.title, $0.artist) }
        )
        XCTAssertEqual(byTitle["One"], "Alice")
        XCTAssertEqual(byTitle["Two"], "Bob")
    }

    /// A track credited to several artists keeps all of them: a feature is part of who performed
    /// it, and keeping only the lead credit is how "X, Y" quietly becomes "X".
    func testATrackWithSeveralCreditsKeepsThemAll() {
        let track = SpotifyTrack(
            id: "1", title: "Duet", artistNames: ["Alice", "Bob"],
            albumName: "Record", albumArtistNames: ["Alice"], trackNumber: 1,
            durationSeconds: 100, albumID: "album-1", albumArtworkURL: nil
        )

        XCTAssertEqual(SpotifyImportService.trackArtistName(for: track), "Alice, Bob")
    }

    /// A single-artist album is unaffected — the track name and the album name agree.
    func testAnOrdinaryAlbumStillFilesEveryTrackUnderItsArtist() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [
            .make(id: "1", title: "One", artist: "Alice", albumID: "solo", albumArtist: "Alice", track: 1),
            .make(id: "2", title: "Two", artist: "Alice", albumID: "solo", albumArtist: "Alice", track: 2),
        ]

        try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Song>()).map(\.artist)), ["Alice"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Artist>()).map(\.name), ["Alice"])
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

    /// The reported bug: a song listed twice in its album, queued twice when the album played,
    /// and no resync ever fixing it. Spotify relinks per market, so the Liked Songs copy and the
    /// saved-album copy of one recording can carry different ids — and matching on the id alone
    /// let both through as separate songs.
    func testOneRecordingUnderTwoIDsBecomesOneSong() {
        let tracks: [SpotifyTrack] = [
            .make(id: "liked-id", title: "Blue in Green", track: 3),
            .make(id: "relinked-id", title: "Blue in Green", track: 3),
        ]

        let collapsed = SpotifyImportService.collapsingRelinkedTracks(tracks)

        XCTAssertEqual(collapsed.count, 1)
        // The saved copy's id is the one kept: liked tracks are passed in first, and a relinked
        // id is not reliably playable when handed back in a play request.
        XCTAssertEqual(collapsed.first?.id, "liked-id")
    }

    /// End to end, which is what the user sees: one row in the album, so one entry in the queue.
    func testARelinkedDuplicateImportsAsASingleSong() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "liked-id", title: "Blue in Green", track: 3)]
        client.savedAlbumTracks = [.make(id: "relinked-id", title: "Blue in Green", track: 3)]

        let result = try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(result.imported, 1)
        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.map(\.relativePath), ["liked-id"])
        let album = try XCTUnwrap(try context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertEqual(album.songs.count, 1, "one row in the album is the whole point")
    }

    /// And the resync clears what earlier syncs already stored, which is the half the user was
    /// stuck on: the row for the id no longer reported stops being seen and is deleted.
    func testAResyncClearsADuplicateAnEarlierSyncStored() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)

        // Stand in for what the old id-only matching left behind: both ids as separate songs.
        try await LibraryRowBuilder.merge(
            from: SpotifyImportService.makeRawSongs(from: [
                .make(id: "liked-id", title: "Blue in Green", track: 3),
                .make(id: "relinked-id", title: "Blue in Green", track: 3),
            ]),
            source: source,
            modelContext: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 2)

        let client = FakeSpotifyClient()
        client.tracks = [.make(id: "liked-id", title: "Blue in Green", track: 3)]
        client.savedAlbumTracks = [.make(id: "relinked-id", title: "Blue in Green", track: 3)]
        _ = try await SpotifyImportService.rescan(
            source: source, client: client, accessToken: "token", modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).map(\.relativePath), ["liked-id"])
    }

    /// The key is tight on purpose: two different songs must not be collapsed into one just
    /// because they sit on the same album.
    func testDifferentSongsOnOneAlbumAreNotCollapsed() {
        let tracks: [SpotifyTrack] = [
            .make(id: "a", title: "So What", track: 1),
            .make(id: "b", title: "Freddie Freeloader", track: 2),
            // Same track number as track 1, different title: a second disc.
            .make(id: "c", title: "Flamenco Sketches", track: 1),
        ]

        XCTAssertEqual(SpotifyImportService.collapsingRelinkedTracks(tracks).map(\.id), ["a", "b", "c"])
    }

    // MARK: - Device selection in Sources

    /// Pressing Refresh brings this phone up so Spotify registers it — the only way it ever
    /// appears in the list — but only when nothing else is playing. Taking the music off a
    /// speaker because the user asked to refresh a list would be its own kind of wrong.
    func testRefreshingDevicesBringsThisPhoneIntoTheListWhenNothingIsPlaying() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.devices = [SpotifyDevice(id: "speaker", name: "Kitchen", isActive: false, isRestricted: false, type: "Speaker")]
        let appRemote = FakeSpotifyAppRemote()
        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            )),
            spotifyAppRemote: appRemote
        )

        viewModel.loadSpotifyDevices(source: source, activatingThisPhone: true)
        await waitUntil { appRemote.activateCount > 0 }

        XCTAssertEqual(appRemote.activateCount, 1)
    }

    /// Something already playing is left alone.
    func testRefreshingDevicesLeavesAnActiveDeviceAlone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.devices = [SpotifyDevice(id: "speaker", name: "Kitchen", isActive: true, isRestricted: false, type: "Speaker")]
        let appRemote = FakeSpotifyAppRemote()
        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            )),
            spotifyAppRemote: appRemote
        )

        viewModel.loadSpotifyDevices(source: source, activatingThisPhone: true)
        await waitUntil { !viewModel.spotifyDevices.isEmpty }

        XCTAssertEqual(appRemote.activateCount, 0, "the Kitchen speaker is playing; leave it")
    }

    /// The reported bug: opening the Sources screen woke Spotify and started music, in any mode.
    /// This screen lists a Spotify source whenever one exists rather than only when it is the
    /// active one, so merely reading the device list must never activate anything. Activation is
    /// for switching into Spotify mode and for Refresh Devices, and both ask for it by name.
    func testReadingTheDeviceListDoesNotWakeSpotify() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeSource(in: context)
        source.spotifyClientID = "abc"

        let client = FakeSpotifyClient()
        client.devices = [SpotifyDevice(id: "speaker", name: "Kitchen", isActive: false, isRestricted: false, type: "Speaker")]
        let appRemote = FakeSpotifyAppRemote()
        let viewModel = SourcesViewModel(
            spotifyAuth: FakeSpotifyAuth(),
            spotifyClient: client,
            spotifyTokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "t", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            )),
            spotifyAppRemote: appRemote
        )

        viewModel.loadSpotifyDevices(source: source)
        await waitUntil { !viewModel.spotifyDevices.isEmpty }

        XCTAssertEqual(appRemote.activateCount, 0, "nothing asked for this phone to be activated")
        XCTAssertEqual(viewModel.spotifyDevices.map(\.name), ["Kitchen"], "the list still loads")
    }

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
        XCTAssertNil(viewModel.spotifyDeviceMessage, "a list with devices in it needs no note")
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
}
