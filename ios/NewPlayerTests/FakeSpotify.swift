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

    /// Track URIs handed to the queue endpoint, in order.
    private(set) var queuedURIs: [String] = []

    func addToQueue(trackURI: String, deviceID: String?, accessToken: String) async throws {
        lock.lock(); queuedURIs.append(trackURI); commands.append("addToQueue"); deviceIDsUsed.append(deviceID); lock.unlock()
        try requireDevice(deviceID)
        if let commandError { throw commandError }
    }

    func transferPlayback(toDeviceID deviceID: String, play: Bool, accessToken: String) async throws {
        lock.lock(); commands.append("transfer:\(deviceID):\(play)"); lock.unlock()
        if let commandError { throw commandError }
        // A transfer is the thing that actually claims a device.
        activeDeviceID = deviceID
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
    /// How Spotify refuses a command sent with no device named. It answers 404 in some states
    /// and 403 "Restriction violated" in others, and both mean the same thing to this app.
    var refusalForUnnamedDevice: SpotifyError = .noActiveDevice

    /// Whether naming a device that isn't in `devices` is refused, as Spotify refuses it with a
    /// 404 "Device not found".
    ///
    /// This matters more than it looks. While the only refusal modelled here was "no device
    /// named", any non-nil id — including one for a device that had long since gone — was
    /// accepted, so a bug that pinned commands to a dead device could not be written down as a
    /// failing test. Device ids are per-session on real Spotify, so going stale is the normal
    /// case, not an exotic one.
    var rejectsUnknownDeviceIDs = true

    /// Which device is currently in charge. A transfer moves it; naming a device in a play
    /// request does not.
    var activeDeviceID: String?

    /// Whether a command aimed at a device that isn't in charge is refused with "Restriction
    /// violated", as Spotify refuses it.
    ///
    /// Naming a device in `/me/player/play` reads as though it claims that device. It does not:
    /// with Spotify paused on a speaker, asking it to play on the phone comes back 403. Only a
    /// transfer claims a device, and until this was modelled here no test could say so.
    var refusesCommandsToInactiveDevices = false

    private func requireDevice(_ deviceID: String?) throws {
        guard let deviceID else {
            if requiresNamedDevice { throw refusalForUnnamedDevice }
            return
        }
        if rejectsUnknownDeviceIDs, !devices.contains(where: { $0.id == deviceID }) {
            throw SpotifyError.noActiveDevice
        }
        if refusesCommandsToInactiveDevices, deviceID != activeDeviceID {
            throw SpotifyError.actionNotAllowed("Player command failed: Restriction violated")
        }
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

    private(set) var notedActiveDeviceIDs: [String?] = []
    func noteActiveDevice(id: String?) {
        notedActiveDeviceIDs.append(id)
    }

    /// Plays handed to the Spotify app on this phone rather than sent over Connect.
    var localPlayError: Error?
    private(set) var localPlayRequests: [(ids: [String], index: Int)] = []

    func playOnLocalApp(trackIDs: [String], startAt index: Int) async throws {
        localPlayRequests.append((trackIDs, index))
        record("playOnLocalApp:\(trackIDs.count)@\(index)")
        if let localPlayError { throw localPlayError }
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
        // Spotify starts playing what it was told to. Leaving the reported track unchanged made
        // the fake claim the *previous* track forever, which no real device does.
        if trackIDs.indices.contains(index) {
            state?.trackID = trackIDs[index]
        }
    }
    /// Tracks appended to Spotify's queue rather than sent as a new context.
    private(set) var queuedTrackIDs: [String] = []

    func addToQueue(trackID: String) async throws {
        try failIfNeeded()
        queuedTrackIDs.append(trackID)
        record("addToQueue:\(trackID)")
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
