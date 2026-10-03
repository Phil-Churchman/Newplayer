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
    /// Tells the controller where Spotify is actually playing, so a device discovered earlier is
    /// not used forever after Spotify has moved somewhere else. Never pins anything.
    func noteActiveDevice(id: String?)
    /// Claims a device for this account, taking it from another account if one is using it.
    /// - Parameter play: whether playback should continue on the new device.
    func takeOverDevice(id: String, play: Bool) async throws
    func play(trackIDs: [String], startAt index: Int) async throws
    /// Adds one track to the end of Spotify's queue without disturbing what is playing.
    func addToQueue(trackID: String) async throws
    func resume() async throws
    func pause() async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func seek(to seconds: TimeInterval) async throws
    /// Plays on the Spotify app on this phone, bypassing Connect entirely.
    ///
    /// The Web API cannot reliably start playback there — it refuses with 403, or accepts with
    /// 204 and then stops — while the same commands drive a Mac or a speaker without trouble.
    /// This is the fallback for that, and it only makes sense for this device.
    func playOnLocalApp(trackIDs: [String], startAt index: Int) async throws
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
    /// Nil in tests that don't exercise local playback.
    private let appRemote: SpotifyAppRemoteControlling?
    private var clientID = ""
    /// The device the user chose in Sources, if any.
    private var preferredDeviceID: String?
    /// The device found automatically after a refusal. Remembered so every later command goes to
    /// the same place rather than each one re-deciding.
    private var discoveredDeviceID: String?

    /// The user's choice wins; otherwise whatever was found last.
    private var deviceID: String? { preferredDeviceID ?? discoveredDeviceID }

    init(
        session: SpotifySession,
        client: SpotifyAPIClient,
        appRemote: SpotifyAppRemoteControlling? = nil
    ) {
        self.session = session
        self.client = client
        self.appRemote = appRemote
    }

    func playOnLocalApp(trackIDs: [String], startAt index: Int) async throws {
        guard let appRemote else { throw SpotifyAppRemoteError.spotifyNotInstalled }
        try await appRemote.play(
            trackIDs: trackIDs,
            startAt: index,
            clientID: clientID,
            accessToken: try await token()
        )
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

    /// Forgets an automatically-discovered device once Spotify is playing somewhere else.
    ///
    /// `discoveredDeviceID` is remembered so that every command after a refusal goes to the same
    /// place instead of re-deciding. The flaw was that it was remembered *forever*: pick up a
    /// speaker once and every later command kept going there, even after playback had moved to
    /// the phone. Those commands succeed — the speaker is a real device — so nothing ever
    /// corrected it, and choosing a track in the app dragged playback back off the phone.
    ///
    /// This only ever clears, and that is the whole point. An earlier attempt at following the
    /// active device *set* this from the same signal, which pinned commands to whatever
    /// /me/player last named — and /me/player goes on naming a device after it has gone, so a
    /// dead id got pinned and every command 404'd. Clearing cannot go stale: with nothing
    /// discovered, commands are sent unaddressed and Spotify routes them to whatever is really
    /// active, which is the behaviour wanted in the first place.
    func noteActiveDevice(id: String?) {
        guard discoveredDeviceID != nil, let id, id != discoveredDeviceID else { return }
        print("SpotifyPlaybackController: Spotify moved to \(id) — forgetting the discovered device")
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

        // Logged before the request rather than only on failure: what was sent, and where, is
        // the first thing needed when Spotify accepts a play and then stops anyway.
        print("SpotifyPlaybackController: play \(uris.count) uri(s) at offset \(window.offset), device=\(deviceID ?? "none"), first \(uris.prefix(3))")

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

    func addToQueue(trackID: String) async throws {
        try await command {
            try await self.client.addToQueue(
                trackURI: "spotify:track:\(trackID)",
                deviceID: $1,
                accessToken: $0
            )
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
        } catch SpotifyError.actionNotAllowed(let reason) {
            // "Restriction violated" is how Spotify refuses a command it considers out of
            // context, and two different situations produce it — needing opposite answers.
            //
            // With no device named there is nothing active to act on: the same state as the 404
            // above, reported differently. Find a device and name it.
            guard let target = deviceID else {
                print("SpotifyPlaybackController: refused (\(reason ?? "no reason")) with nothing named; finding a device")
                let device = try await chooseDevice()
                discoveredDeviceID = device.id
                try await withRetryOnRefusedPermissions { try await body($0, device.id) }
                return
            }

            // With one named, the device is real and reachable but is not the one currently in
            // charge, and Spotify will not start playback on it from a plain play request —
            // naming a device in `/me/player/play` is not enough to claim it. A transfer is what
            // claims it, which is what `/me/player` is for; the command then goes to a device
            // that is already ours.
            //
            // This is the refusal seen when Spotify was paused on a speaker and the app was
            // asked to play on the phone.
            print("SpotifyPlaybackController: refused (\(reason ?? "no reason")) on \(target); taking the device over first")
            try await takeOverDevice(id: target, play: false)
            // Spotify answers the transfer before the device has picked it up, and a command
            // sent into that gap is refused exactly as the first one was.
            try? await Task.sleep(nanoseconds: Self.transferSettleNanoseconds)
            try await withRetryOnRefusedPermissions { try await body($0, target) }
        }
    }

    /// How long to let a transfer land before sending the command that follows it.
    private static let transferSettleNanoseconds: UInt64 = 600_000_000

    /// Prefers a device already playing, then any Spotify will let us drive, favouring a phone —
    /// which is this one, in the usual case of the app running alongside Spotify.
    private func chooseDevice() async throws -> SpotifyDevice {
        let devices = try await client.fetchDevices(accessToken: try await token())

        // An empty list is taken at face value. It is tempting to fall back on the device
        // /me/player names — the two endpoints do disagree — but that reads the disagreement
        // backwards. /me/player serves the *last known* context and keeps doing so after the
        // device has gone; the device list reports what is registered with Connect right now.
        // When they differ it is the list that is current, so the id from /me/player is a dead
        // one, and naming it earns a 404 "Device not found" on the command and again on the
        // retry — which is exactly the loop that stopped playback working.
        //
        // The error below is the honest answer, and its message tells the user to open Spotify,
        // which is the thing that actually fixes it.
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

    /// The slice to send, and where the chosen track sits within it.
    ///
    /// The window slides back from the end of the queue rather than always starting at the
    /// chosen track. Starting there looks right until the chosen track is near the end: taking
    /// a hundred from index 249 of 250 leaves exactly one, so replacing Spotify's context with
    /// it reduced the whole queue to a single track. Appending hit that every time, because a
    /// freshly appended track *is* the last one — add to a queue of more than a hundred and
    /// everything else vanished.
    ///
    /// Anchoring the end instead keeps the window full whenever there are enough tracks to fill
    /// it, so what is sent is the hundred tracks ending with the queue's end, and `offset` says
    /// where in that the chosen track sits. Tracks before it are worth carrying for their own
    /// sake: they are what Spotify's "previous" has to go back to.
    static func window(of trackIDs: [String], around index: Int) -> (ids: [String], offset: Int) {
        let chosen = min(max(index, 0), max(trackIDs.count - 1, 0))
        guard trackIDs.count > maximumURIsPerRequest else {
            return (trackIDs, chosen)
        }
        let start = min(chosen, trackIDs.count - maximumURIsPerRequest)
        return (Array(trackIDs[start..<(start + maximumURIsPerRequest)]), chosen - start)
    }
}
