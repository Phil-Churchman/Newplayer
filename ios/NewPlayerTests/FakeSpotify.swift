import Foundation
@testable import NewPlayer

@MainActor
final class FakeSpotifyAuth: SpotifyAuthorizing {
    var tokensToReturn = SpotifyTokens(
        accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)
    )
    var signInError: Error?
    private(set) var signInCount = 0
    private(set) var refreshCount = 0

    func signIn(clientID: String) async throws -> SpotifyTokens {
        signInCount += 1
        if let signInError { throw signInError }
        return tokensToReturn
    }

    /// When set, a refresh hangs for this long — standing in for a stalled network call, which
    /// is what wedged the shared session.
    var refreshHangsForNanoseconds: UInt64?

    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyTokens {
        refreshCount += 1
        if let refreshHangsForNanoseconds {
            try await Task.sleep(nanoseconds: refreshHangsForNanoseconds)
        }
        return tokensToReturn
    }
}

final class FakeSpotifyClient: SpotifyAPIClient, @unchecked Sendable {
    var account = SpotifyAccount(displayName: "Phil", product: "premium")
    var tracks: [SpotifyTrack] = []
    var artworkByURL: [URL: Data] = [:]
    var accountError: Error?
    private(set) var artworkRequests: [URL] = []
    private let lock = NSLock()

    func fetchAccount(accessToken: String) async throws -> SpotifyAccount {
        if let accountError { throw accountError }
        return account
    }

    /// Tracks from saved albums, which /me/tracks does not return.
    var savedAlbumTracks: [SpotifyTrack] = []

    func fetchSavedTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack] {
        onPage(tracks.count)
        return tracks
    }

    func fetchSavedAlbumTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack] {
        onPage(savedAlbumTracks.count)
        return savedAlbumTracks
    }

    var playerState: SpotifyPlayerState?
    var commandError: Error?
    /// Rejects commands carrying this exact token, as Spotify does for a token whose grant is
    /// too narrow — so a test can prove the retry gets a different one.
    var failCommandsUntilTokenChanges: String?
    private(set) var playRequests: [(uris: [String], offset: Int)] = []
    private(set) var commands: [String] = []

    func fetchPlayerState(accessToken: String) async throws -> SpotifyPlayerState? {
        playerState
    }

    var devices: [SpotifyDevice] = []
    /// Refuses commands that name no device, exactly as Spotify does when nothing is active.
    var requiresNamedDevice = false
    private(set) var deviceIDsUsed: [String?] = []

    func resetCommands() {
        lock.lock(); commands.removeAll(); deviceIDsUsed.removeAll(); lock.unlock()
    }

    func transferPlayback(toDeviceID deviceID: String, play: Bool, accessToken: String) async throws {
        lock.lock(); commands.append("transfer:\(deviceID):\(play)"); lock.unlock()
        if let commandError { throw commandError }
    }

    var queueSnapshot = SpotifyQueueSnapshot(currentTrackID: nil, entries: [])

    func fetchPlaybackQueue(accessToken: String) async throws -> SpotifyQueueSnapshot {
        lock.lock(); commands.append("fetchQueue"); lock.unlock()
        return queueSnapshot
    }

    func fetchDevices(accessToken: String) async throws -> [SpotifyDevice] {
        lock.lock(); commands.append("fetchDevices"); lock.unlock()
        return devices
    }

    func play(trackURIs: [String], startAt index: Int, deviceID: String?, accessToken: String) async throws {
        lock.lock(); playRequests.append((trackURIs, index)); commands.append("play"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    private func requireDevice(_ deviceID: String?) throws {
        if requiresNamedDevice, deviceID == nil { throw SpotifyError.noActiveDevice }
    }

    func resume(deviceID: String?, accessToken: String) async throws {
        lock.lock(); commands.append("resume"); deviceIDsUsed.append(deviceID); lock.unlock()
        try check(accessToken)
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    private func check(_ accessToken: String) throws {
        if let failCommandsUntilTokenChanges, accessToken == failCommandsUntilTokenChanges {
            throw SpotifyError.permissionsMissing
        }
    }

    func pause(deviceID: String?, accessToken: String) async throws {
        lock.lock(); commands.append("pause"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    func skipToNext(deviceID: String?, accessToken: String) async throws {
        lock.lock(); commands.append("next"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    func skipToPrevious(deviceID: String?, accessToken: String) async throws {
        lock.lock(); commands.append("previous"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    func seek(toMilliseconds position: Int, deviceID: String?, accessToken: String) async throws {
        lock.lock(); commands.append("seek:\(position)"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    func fetchArtwork(url: URL) async throws -> Data {
        lock.lock()
        artworkRequests.append(url)
        lock.unlock()
        guard let data = artworkByURL[url] else { throw SpotifyError.requestFailed("no artwork") }
        return data
    }
}

final class InMemorySpotifyTokenStore: SpotifyTokenStoring, @unchecked Sendable {
    private var tokens: SpotifyTokens?
    init(tokens: SpotifyTokens? = nil) { self.tokens = tokens }
    func load() -> SpotifyTokens? { tokens }
    func save(_ tokens: SpotifyTokens) { self.tokens = tokens }
    func clear() { tokens = nil }
}

extension SpotifyTrack {
    static func make(
        id: String,
        title: String,
        artist: String = "Alice",
        album: String = "Record",
        albumID: String = "album-1",
        albumArtist: String? = nil,
        track: Int = 1,
        artworkURL: URL? = nil
    ) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            title: title,
            artistNames: [artist],
            albumName: album,
            albumArtistNames: [albumArtist ?? artist],
            trackNumber: track,
            durationSeconds: 200,
            albumID: albumID,
            albumArtworkURL: artworkURL
        )
    }
}

/// A stand-in for the Connect controller, for tests about routing rather than about HTTP.
@MainActor
final class FakeSpotifyPlayback: SpotifyPlaybackControlling {
    private(set) var configuredClientID: String?
    /// Commands that would go over the wire.
    private(set) var commands: [String] = []
    /// Everything in order, wire commands and local configuration alike — for tests about
    /// sequencing, where "which device was this sent to" depends on what happened first.
    private(set) var events: [String] = []
    private(set) var playRequests: [(ids: [String], index: Int)] = []
    var errorToThrow: Error?
    var state: SpotifyPlayerState?

    private(set) var selectedDeviceID: String?

    func configure(clientID: String) { configuredClientID = clientID }
    func selectDevice(id: String?) {
        selectedDeviceID = id
        events.append("selectDevice")
    }

    /// When true, a transfer is accepted but the device never actually picks it up — Spotify
    /// answers before the device has, and some decline quietly.
    var transferSilentlyFails = false

    func takeOverDevice(id: String, play: Bool) async throws {
        try failIfNeeded()
        record("takeOver:\(id):\(play)")
        if !transferSilentlyFails {
            state?.activeDeviceID = id
        }
    }

    func play(trackIDs: [String], startAt index: Int) async throws {
        try failIfNeeded()
        playRequests.append((trackIDs, index))
        record("play")
    }

    func resume() async throws { try failIfNeeded(); record("resume") }
    func pause() async throws { try failIfNeeded(); record("pause") }
    /// What Spotify will actually play on the next skip — a queued track, a shuffle pick,
    /// anything. The point is that the app cannot predict it.
    var trackAfterNextSkip: String?
    var trackAfterPreviousSkip: String?

    func skipToNext() async throws {
        try failIfNeeded()
        record("next")
        if let trackAfterNextSkip { state?.trackID = trackAfterNextSkip }
    }

    /// Spotify refuses "previous" at the start of a context — there is nothing before the track.
    var previousIsRefused = false

    func skipToPrevious() async throws {
        try failIfNeeded()
        record("previous")
        if previousIsRefused {
            throw SpotifyError.actionNotAllowed("Cannot skip to previous track")
        }
        if let trackAfterPreviousSkip { state?.trackID = trackAfterPreviousSkip }
    }
    func seek(to seconds: TimeInterval) async throws { try failIfNeeded(); record("seek") }
    func playerState() async throws -> SpotifyPlayerState? {
        // Reads go to `events` only: `commands` is the wire-command sequence transport tests
        // assert on, and a poll running underneath them isn't part of that.
        events.append("state")
        return state
    }

    var queueSnapshot = SpotifyQueueSnapshot(currentTrackID: nil, entries: [])
    func playbackQueue() async throws -> SpotifyQueueSnapshot {
        try failIfNeeded()
        events.append("queue")
        return queueSnapshot
    }

    func resetCommands() {
        commands.removeAll()
        events.removeAll()
        playRequests.removeAll()
    }

    private func record(_ command: String) {
        commands.append(command)
        events.append(command)
    }

    private func failIfNeeded() throws {
        if let errorToThrow { throw errorToThrow }
    }
}

/// Stands in for the Spotify app on the device.
@MainActor
final class FakeSpotifyAppLink: SpotifyAppLinking {
    var isInstalled: Bool
    private(set) var openCount = 0

    init(isInstalled: Bool = true) {
        self.isInstalled = isInstalled
    }

    func open() { openCount += 1 }
}
