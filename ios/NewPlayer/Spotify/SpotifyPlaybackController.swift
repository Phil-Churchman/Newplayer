import Foundation

/// Drives playback on whichever Spotify client is currently active — normally the Spotify app on
/// this same phone. The audio never passes through this app: Spotify does not hand it over, so
/// this is a remote control, the same arrangement as the MPD source.
@MainActor
protocol SpotifyPlaybackControlling {
    /// The client ID to authenticate with, taken from the active Spotify source.
    func configure(clientID: String)
    /// Pins playback to one Connect device. Nil restores the automatic choice.
    func selectDevice(id: String?)
    /// Claims a device for this account, taking it from another account if one is using it.
    /// - Parameter play: whether playback should continue on the new device.
    func takeOverDevice(id: String, play: Bool) async throws
    func play(trackIDs: [String], startAt index: Int) async throws
    func resume() async throws
    func pause() async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func seek(to seconds: TimeInterval) async throws
    /// Nil when no Spotify client is active.
    func playerState() async throws -> SpotifyPlayerState?
    /// Spotify's own queue, so tracks queued from the Spotify app show up here too.
    func playbackQueue() async throws -> SpotifyQueueSnapshot
}

@MainActor
final class SpotifyPlaybackController: SpotifyPlaybackControlling {
    /// Spotify caps how many track URIs one play request may carry. A queue longer than this is
    /// sent as a window starting at the chosen track, which is what the user is about to hear.
    private static let maximumURIsPerRequest = 100

    private let session: SpotifySession
    private let client: SpotifyAPIClient
    private var clientID = ""
    /// The device the user chose in Sources, if any.
    private var preferredDeviceID: String?
    /// The device found automatically after a refusal. Remembered so every later command goes to
    /// the same place rather than each one re-deciding.
    private var discoveredDeviceID: String?

    /// The user's choice wins; otherwise whatever was found last.
    private var deviceID: String? { preferredDeviceID ?? discoveredDeviceID }

    init(session: SpotifySession, client: SpotifyAPIClient) {
        self.session = session
        self.client = client
    }

    func configure(clientID: String) {
        self.clientID = clientID
        discoveredDeviceID = nil
    }

    func selectDevice(id: String?) {
        preferredDeviceID = id
        // A new choice supersedes anything found automatically before it.
        discoveredDeviceID = nil
    }

    func takeOverDevice(id: String, play: Bool) async throws {
        // A transfer carries the current track and position across, which is the whole point of
        // Connect — so `play` simply follows whether music was playing before the switch.
        try await withRetryOnRefusedPermissions {
            try await self.client.transferPlayback(toDeviceID: id, play: play, accessToken: $0)
        }
    }

    func play(trackIDs: [String], startAt index: Int) async throws {
        guard !trackIDs.isEmpty else { return }
        let window = Self.window(of: trackIDs, around: index)
        let uris = window.ids.map { "spotify:track:\($0)" }

        // A malformed or unplayable URI is refused by Spotify with a message about links, which
        // gives no clue which track was at fault. Logged so the next report can say.
        if let malformed = uris.first(where: { !Self.isPlausibleTrackURI($0) }) {
            print("SpotifyPlaybackController: refusing to send a malformed URI — \(malformed)")
            throw SpotifyError.actionNotAllowed("a track in this album has no Spotify id")
        }

        do {
            try await command { token, device in
                try await self.client.play(
                    trackURIs: uris,
                    startAt: window.offset,
                    deviceID: device,
                    accessToken: token
                )
            }
        } catch {
            print("SpotifyPlaybackController: play failed for \(uris.count) uri(s), first \(uris.prefix(3)) — \(error)")
            throw error
        }
    }

    func resume() async throws {
        try await command { try await self.client.resume(deviceID: $1, accessToken: $0) }
    }

    func pause() async throws {
        try await command { try await self.client.pause(deviceID: $1, accessToken: $0) }
    }

    func skipToNext() async throws {
        try await command { try await self.client.skipToNext(deviceID: $1, accessToken: $0) }
    }

    func skipToPrevious() async throws {
        try await command { try await self.client.skipToPrevious(deviceID: $1, accessToken: $0) }
    }

    func seek(to seconds: TimeInterval) async throws {
        let milliseconds = Int(seconds * 1000)
        try await command {
            try await self.client.seek(toMilliseconds: milliseconds, deviceID: $1, accessToken: $0)
        }
    }

    func playerState() async throws -> SpotifyPlayerState? {
        try await client.fetchPlayerState(accessToken: try await token())
    }

    func playbackQueue() async throws -> SpotifyQueueSnapshot {
        try await client.fetchPlaybackQueue(accessToken: try await token())
    }

    /// Sends one command, dealing with the two ways Spotify refuses it.
    ///
    /// The important one is "no active device". An open Spotify app is *available* but stays
    /// inactive until something plays on it, and a command naming no device is refused in that
    /// state — which looks, from this app, exactly like Spotify not being open at all. So on
    /// refusal we look up the devices Spotify can see, pick one, and send the command again
    /// naming it, which both targets and wakes it.
    private func command(_ body: @escaping (String, String?) async throws -> Void) async throws {
        do {
            try await withRetryOnRefusedPermissions { try await body($0, self.deviceID) }
        } catch SpotifyError.noActiveDevice {
            let device = try await chooseDevice()
            discoveredDeviceID = device.id
            try await withRetryOnRefusedPermissions { try await body($0, device.id) }
        }
    }

    /// Prefers a device already playing, then any Spotify will let us drive, favouring a phone —
    /// which is this one, in the usual case of the app running alongside Spotify.
    private func chooseDevice() async throws -> SpotifyDevice {
        let devices = try await client.fetchDevices(accessToken: try await token())
        guard !devices.isEmpty else { throw SpotifyError.noActiveDevice }

        let controllable = devices.filter { !$0.isRestricted }
        guard !controllable.isEmpty else { throw SpotifyError.onlyRestrictedDevices }

        if let active = controllable.first(where: \.isActive) { return active }
        if let phone = controllable.first(where: { $0.type.caseInsensitiveCompare("Smartphone") == .orderedSame }) {
            return phone
        }
        return controllable[0]
    }

    /// Never interactive: playback commands and the state poll both run without the user having
    /// asked for anything just now, and neither may put a sign-in page on screen.
    private func token() async throws -> String {
        guard !clientID.isEmpty else { throw SpotifyError.missingClientID }
        return try await session.accessToken(clientID: clientID, interactive: false)
    }

    /// Runs a request and lets a permissions refusal stand.
    ///
    /// It must NOT throw the stored tokens away. This runs from the playback poll, every couple
    /// of seconds, and it cannot open a sign-in page to replace what it discarded — so a single
    /// refused poll would leave the app with no tokens at all, and the next sync would need a
    /// full re-approval on Spotify's site. Recovering from a refusal is the sign-in flow's job,
    /// where the user is present.
    private func withRetryOnRefusedPermissions(
        _ body: (String) async throws -> Void
    ) async throws {
        try await body(try await token())
    }

    /// A Spotify track id is 22 characters of base62. Anything else — an empty string, a file
    /// path, a Music-library persistent id — will be refused, and it is worth catching here
    /// rather than as an opaque complaint about links.
    static func isPlausibleTrackURI(_ uri: String) -> Bool {
        let id = uri.replacingOccurrences(of: "spotify:track:", with: "")
        guard id.count == 22 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The slice to send, and where the chosen track sits within it.
    static func window(of trackIDs: [String], around index: Int) -> (ids: [String], offset: Int) {
        guard trackIDs.count > maximumURIsPerRequest else {
            return (trackIDs, min(max(index, 0), max(trackIDs.count - 1, 0)))
        }
        let start = min(max(index, 0), trackIDs.count - 1)
        let end = min(start + maximumURIsPerRequest, trackIDs.count)
        return (Array(trackIDs[start..<end]), 0)
    }
}
