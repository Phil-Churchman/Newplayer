import XCTest
import SwiftData
@testable import NewPlayer

@MainActor
final class SourcesViewModelTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Waits for a condition to become true, polling frequently — used instead of a fixed
    /// sleep since the sync flow's own poll loop uses a near-zero interval in these tests.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// `waitUntil` for conditions that have to reach into an actor.
    private func waitUntilAsync(timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeNetworkSource(in context: ModelContext) throws -> Source {
        let source = Source(name: "Network", host: "host", port: 6600, isActive: true, kind: .network)
        context.insert(source)
        try context.save()
        return source
    }

    private func updating(_ isUpdating: Bool) -> MPDStatus {
        MPDStatus(state: "stop", elapsed: 0, duration: 0, songPosition: nil, isUpdatingDatabase: isUpdating)
    }

    /// Opening Sources should surface an update already running on the server — whether this
    /// app asked for it, another client did, or it was running before launch.
    func testMonitorReportsAnUpdateAlreadyRunningOnTheServer() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setStatus(updating(true))

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)
        let monitor = Task { await viewModel.monitorServerSync(source: source, modelContext: context) }

        await waitUntil { viewModel.serverSyncPhase == .syncing }
        XCTAssertEqual(viewModel.serverSyncPhase, .syncing)

        monitor.cancel()
    }

    /// Once the server stops reporting the update, the mirrored catalogue is stale — pull it,
    /// then settle back to idle. Only ever in-progress or done.
    func testMonitorRefreshesTheLibraryOnceTheServerFinishes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setSongs([
            MPDSongInfo(file: "new.flac", title: "New", artist: "A", album: "Al", albumArtist: "A", track: 1, duration: 100),
        ])
        await mock.setStatusSequence([updating(true), updating(false)])

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)
        let monitor = Task { await viewModel.monitorServerSync(source: source, modelContext: context) }

        await waitUntil(timeout: 5) { (try? context.fetch(FetchDescriptor<Song>()).count) == 1 }

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.first?.title, "New")
        await waitUntil { viewModel.serverSyncPhase == .idle }
        XCTAssertEqual(viewModel.serverSyncPhase, .idle)

        monitor.cancel()
    }

    /// The reported bug: backgrounding the app or the phone sleeping dropped the connection and
    /// the app declared the sync interrupted, telling the user to restart it. The sync runs on
    /// the server — losing sight of it must never change the reported state, and once the
    /// connection returns the app should simply report what the server says.
    func testLosingTheConnectionNeverReportsTheSyncAsInterrupted() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setStatus(updating(true))

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)
        let monitor = Task { await viewModel.monitorServerSync(source: source, modelContext: context) }
        await waitUntil { viewModel.serverSyncPhase == .syncing }

        // The connection dies, exactly as it does when iOS suspends the app.
        await mock.setStatusError(MPDError.connectionFailed("socket closed"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            viewModel.serverSyncPhase, .syncing,
            "losing the connection means we can't see the sync — not that it stopped"
        )

        // Connection returns and the server is still working: still syncing, nothing to restart.
        await mock.setStatusError(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.serverSyncPhase, .syncing)

        monitor.cancel()
    }

    /// Requesting a sync is fire-and-forget; the server owns it from there. Nothing about the
    /// app's own lifecycle should be able to put the UI into a failed state.
    func testRequestingASyncOnlySendsTheCommand() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)

        viewModel.syncWithMusicServer(source: source, modelContext: context)

        // The phase flips synchronously; the command itself is sent on a detached task, so wait
        // for the call rather than the phase.
        await waitUntilAsync { await mock.calls.contains(.updateDatabase) }

        // Still "requested": having sent the command, the app hands ownership to the server and
        // waits for the monitor to report what it says.
        XCTAssertEqual(viewModel.serverSyncPhase, .requested)
    }

    /// If the server can't even be reached to ask, drop straight back to idle and say so via
    /// the general error line — never a sync-specific "interrupted, restart it" state.
    func testUnreachableServerFallsBackToIdleRatherThanAFailedSync() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setConnectError(MPDError.connectionFailed("refused"))

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)
        viewModel.syncWithMusicServer(source: source, modelContext: context)

        await waitUntil { viewModel.serverSyncPhase == .idle && viewModel.errorMessage != nil }
        XCTAssertEqual(viewModel.serverSyncPhase, .idle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testSyncWithMusicServerIgnoresConcurrentTrigger() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 1_000_000)

        viewModel.syncWithMusicServer(source: source, modelContext: context)
        viewModel.syncWithMusicServer(source: source, modelContext: context) // ignored: already requested

        await waitUntil { viewModel.serverSyncPhase == .requested }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let calls = await mock.calls
        let updateCount = calls.filter { $0 == .updateDatabase }.count
        XCTAssertEqual(updateCount, 1)
    }

    /// A TabView keeps the Sources tab alive after its first visit, so the monitor's task is
    /// never cancelled. Left ungated it polls the host every couple of seconds for the rest of
    /// the session, from behind whatever tab you're on — load the host doesn't need, and a
    /// connection that competes with playback and artwork downloads.
    func testMonitorStopsPollingWhenTheSourcesScreenIsNotVisible() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setStatus(updating(false))

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 10_000_000)
        let monitor = Task { await viewModel.monitorServerSync(source: source, modelContext: context) }

        await waitUntilAsync { await mock.statusFetchCount >= 1 }

        viewModel.setSourcesScreenVisible(false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let whenHidden = await mock.statusFetchCount

        try? await Task.sleep(nanoseconds: 300_000_000)
        let stillHidden = await mock.statusFetchCount
        XCTAssertEqual(stillHidden, whenHidden, "the monitor must not poll while the screen is hidden")

        // And it picks straight back up when the screen comes back.
        viewModel.setSourcesScreenVisible(true)
        await waitUntilAsync { await mock.statusFetchCount > stillHidden }

        monitor.cancel()
    }

    /// It must also let go of the connection, not merely stop asking on it.
    func testMonitorReleasesTheConnectionWhileHidden() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = try makeNetworkSource(in: context)

        let mock = MockMPDClient()
        await mock.setStatus(updating(false))

        let viewModel = SourcesViewModel(makeMPDClient: { mock }, monitorIntervalNanoseconds: 10_000_000)
        let monitor = Task { await viewModel.monitorServerSync(source: source, modelContext: context) }
        await waitUntilAsync { await mock.statusFetchCount >= 1 }

        viewModel.setSourcesScreenVisible(false)
        await waitUntilAsync { await mock.calls.contains(.disconnect) }

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.disconnect))

        monitor.cancel()
    }
}
