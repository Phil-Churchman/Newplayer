import Foundation
@testable import NewPlayer

/// Test double recording every call made to it, so tests can assert on what commands
/// PlaybackManager/MPDLibrarySyncService actually sent without a live MPD server.
actor MockMPDClient: MPDClientProtocol {
    enum Call: Equatable {
        case connect(host: String, port: UInt16)
        case disconnect
        case setPause(Bool)
        case stop
        case next
        case previous
        case seek(Double)
        case replaceQueue(uris: [String], startAt: Int)
        case addToQueue(uri: String)
        case clearQueue
        case playAtQueuePosition(Int)
        case deleteFromQueue(position: Int)
        case updateDatabase
        case fetchAlbumArt(file: String)
        case fetchQueue
    }

    private(set) var calls: [Call] = []

    private var statusToReturn = MPDStatus(state: "stop", elapsed: 0, duration: 0, songPosition: nil, isUpdatingDatabase: false)
    /// When non-empty, `fetchStatus()` pops one value per call instead of returning
    /// `statusToReturn` — lets tests simulate a status changing across repeated polls.
    private var statusSequence: [MPDStatus] = []
    private var songsToReturn: [MPDSongInfo] = []
    private var songsError: Error?
    private var artworkToReturn: [String: Data] = [:]
    private var connectError: Error?
    private var updateDatabaseError: Error?
    private var statusError: Error?
    private var commandError: Error?
    private var queueToReturn: [String] = []

    func setQueue(_ queue: [String]) {
        queueToReturn = queue
    }

    func setStatus(_ status: MPDStatus) {
        statusToReturn = status
    }

    func setStatusSequence(_ statuses: [MPDStatus]) {
        statusSequence = statuses
    }

    /// Simulates a connection that has died — every status poll fails until cleared.
    func setStatusError(_ error: Error?) {
        statusError = error
    }

    /// Simulates a dead socket for transport commands.
    func setCommandError(_ error: Error?) {
        commandError = error
        statusError = error
    }

    func setUpdateDatabaseError(_ error: Error) {
        updateDatabaseError = error
    }

    func setSongs(_ songs: [MPDSongInfo]) {
        songsToReturn = songs
        songsError = nil
    }

    func setSongsError(_ error: Error) {
        songsError = error
    }

    func setArtwork(_ artwork: [String: Data]) {
        artworkToReturn = artwork
    }

    func setConnectError(_ error: Error?) {
        connectError = error
    }

    func connect(host: String, port: UInt16) async throws {
        calls.append(.connect(host: host, port: port))
        if let connectError { throw connectError }
    }

    func disconnect() async {
        calls.append(.disconnect)
        // Widens the teardown window so a test can slip a request into it, which is where the
        // artwork queue could strand one.
        if disconnectDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: disconnectDelayNanoseconds)
        }
    }

    private var disconnectDelayNanoseconds: UInt64 = 0

    func setDisconnectDelay(nanoseconds: UInt64) {
        disconnectDelayNanoseconds = nanoseconds
    }

    private(set) var statusFetchCount = 0

    func fetchStatus() async throws -> MPDStatus {
        statusFetchCount += 1
        if let statusError { throw statusError }
        if !statusSequence.isEmpty {
            return statusSequence.removeFirst()
        }
        return statusToReturn
    }

    func fetchAllSongs() async throws -> [MPDSongInfo] {
        if let songsError { throw songsError }
        return songsToReturn
    }

    func fetchQueue() async throws -> [String] {
        calls.append(.fetchQueue)
        return queueToReturn
    }

    // MARK: - Artwork instrumentation
    //
    // The fetcher's contract is about *when* and *how many* requests it makes, not just their
    // results, so the fake records concurrency and order.
    private var artworkDelayNanoseconds: UInt64 = 0
    private var defaultArtwork: Data?
    private var inFlightArtworkFetches = 0
    private(set) var maxConcurrentArtworkFetches = 0
    private(set) var artworkFetchCount = 0
    private(set) var artworkFilesFetched: [String] = []

    /// Makes each download take a measurable amount of time, so overlap is observable.
    func setArtworkDelay(nanoseconds: UInt64) {
        artworkDelayNanoseconds = nanoseconds
    }

    /// Artwork returned for any file; nil simulates a server with no cover.
    func setDefaultArtwork(_ data: Data?) {
        defaultArtwork = data
    }

    func fetchAlbumArt(forFile file: String) async -> Data? {
        calls.append(.fetchAlbumArt(file: file))
        artworkFetchCount += 1
        artworkFilesFetched.append(file)

        inFlightArtworkFetches += 1
        maxConcurrentArtworkFetches = max(maxConcurrentArtworkFetches, inFlightArtworkFetches)
        if artworkDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: artworkDelayNanoseconds)
        }
        inFlightArtworkFetches -= 1

        return artworkToReturn[file] ?? defaultArtwork
    }

    func setPause(_ paused: Bool) async throws {
        calls.append(.setPause(paused))
        if let commandError { throw commandError }
    }

    func stop() async throws {
        calls.append(.stop)
    }

    func next() async throws {
        calls.append(.next)
    }

    func previous() async throws {
        calls.append(.previous)
    }

    func seek(seconds: Double) async throws {
        calls.append(.seek(seconds))
    }

    func replaceQueue(uris: [String], startAt: Int) async throws {
        calls.append(.replaceQueue(uris: uris, startAt: startAt))
    }

    func clearQueue() async throws {
        calls.append(.clearQueue)
    }

    func addToQueue(uri: String) async throws {
        calls.append(.addToQueue(uri: uri))
    }

    func playAtQueuePosition(_ position: Int) async throws {
        calls.append(.playAtQueuePosition(position))
        // Behave like a real server: after `play <pos>` the status reports that position and a
        // playing state. Without this the fake contradicted its own commands, and any code that
        // reconciles against the server after issuing one looked broken.
        statusToReturn.songPosition = position
        statusToReturn.state = "play"
    }

    func deleteFromQueue(position: Int) async throws {
        calls.append(.deleteFromQueue(position: position))
    }

    func updateDatabase() async throws {
        calls.append(.updateDatabase)
        if let updateDatabaseError { throw updateDatabaseError }
    }
}
