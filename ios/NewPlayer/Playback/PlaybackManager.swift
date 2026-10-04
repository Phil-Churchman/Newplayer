import AVFoundation
import Foundation
import SwiftData
import UIKit

/// Uses `@Observable` rather than `ObservableObject` deliberately: with the latter, every
/// published change invalidates every observing view, so the twice-a-second `currentTime`
/// tick during playback re-ran the body of the big library lists — which only ever call a
/// method on this and read none of its state — making scrolling stutter while playing.
/// `@Observable` tracks which properties a view actually reads, so those lists are no longer
/// touched by clock ticks at all.
@MainActor
@Observable
final class PlaybackManager {
    /// Storage for `queue`/`currentIndex`. Private so that every mutation has to go through the
    /// setters below, which keep `currentSongID` in step — the compiler enforces it, since the
    /// public properties are get-only.
    private var queueStorage: [Song] = []
    private var currentIndexStorage: Int?

    var queue: [Song] { queueStorage }
    var currentIndex: Int? { currentIndexStorage }

    /// The identity of the track currently loaded, published separately from `queue` and
    /// `currentIndex` on purpose. The library lists highlight the playing track by reading this
    /// and nothing else, so appending to the queue — or the remote poll re-mirroring it — no
    /// longer invalidates a list of several thousand rows. Only an actual change of track does.
    private(set) var currentSongID: PersistentIdentifier?
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Whether the MPD host is currently rebuilding its own database. Taken from the status
    /// poll this already runs, so it costs no extra connection or request — and it's read
    /// app-wide to hold the library screens back while the server's catalogue is in flux.
    private(set) var isHostSyncingDatabase = false
    /// Spotify's queue exactly as Spotify reports it, including tracks that were never imported.
    /// This is what the Queue screen shows in Spotify mode; `queue` remains the library-backed
    /// list, which is what the Songs and Albums screens highlight against.
    private(set) var spotifyQueue: [SpotifyQueueEntry] = []

    /// Whether Spotify owns playback, so the Queue screen knows to show Spotify's queue rather
    /// than falling back to the library-backed one.
    var isSpotifySource: Bool { isSpotifyMode }

    /// What Spotify says is playing, for the times it is a track with no row in the library.
    var spotifyCurrentEntry: SpotifyQueueEntry? {
        guard isSpotifyMode else { return nil }
        return spotifyQueue.first
    }

    /// Surfaced when a remote player refuses a command — most usefully Spotify's "nothing is
    /// active to control", which otherwise looks like the buttons simply not working.
    private(set) var playbackErrorMessage: String?

    /// Set when a Spotify play failed for want of authorization, and offline mode would not have
    /// needed it.
    ///
    /// Worth offering rather than just reporting, because the two are the same situation seen
    /// from different ends: authorizing goes over the network, so "Spotify needs authorizing
    /// again" is what losing the connection looks like from here. Offline mode hands the track
    /// to the Spotify app with a deep link, which needs no permission — so the error names a
    /// remedy the user cannot reach, while the thing that would work sits behind a switch they
    /// have no reason to connect with it.
    private(set) var isSuggestingSpotifyOfflineMode = false

    func dismissSpotifyOfflineModeSuggestion() {
        isSuggestingSpotifyOfflineMode = false
    }

    @ObservationIgnored
    let player = AVPlayer()

    @ObservationIgnored
    private var timeObserverToken: Any?
    @ObservationIgnored
    private var endObserver: NSObjectProtocol?
    @ObservationIgnored
    private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored
    private var currentlyScopedURL: URL?

    @ObservationIgnored
    private let makeMPDClient: () -> MPDClientProtocol
    /// Resolves Music-library songs to a playable asset URL. Injected so tests can drive the
    /// media-library path without a real device library.
    @ObservationIgnored
    private let mediaLibrary: MediaLibraryProviding
    /// Drives playback on an active Spotify client. Built lazily: the real one reaches for
    /// URLSession.shared, and a manager that never touches Spotify shouldn't pay for that.
    @ObservationIgnored
    private let makeSpotify: () -> SpotifyPlaybackControlling
    @ObservationIgnored
    private lazy var spotify: SpotifyPlaybackControlling = makeSpotify()
    @ObservationIgnored
    private var spotifyPollTask: Task<Void, Never>?
    @ObservationIgnored
    private var isSpotifyMode = false
    /// Whether to skip Spotify Connect entirely and drive the Spotify app on this phone.
    ///
    /// Connect is a web service: with no network every command waits out its timeout before
    /// failing, so a play took the better part of a minute to reach the fallback that was always
    /// going to handle it. The state poll is no better off — it can only report what it cannot
    /// reach. In offline mode both are skipped and playback goes straight to the Spotify app,
    /// which is a local connection and needs no network at all.
    @ObservationIgnored
    private var isSpotifyOfflineMode = false
    /// Which source is loaded, so a repeated call for the same one can be recognised.
    @ObservationIgnored
    private var activeSourceID: PersistentIdentifier?
    /// Spotify has no queue-version counter the way MPD does, so its queue is re-read on a
    /// slower cadence than the transport state rather than on every tick.
    @ObservationIgnored
    private var spotifyPollsSinceQueueRead = 0
    /// Set while a play this app sent is still being resolved — including the fallback onto the
    /// Spotify app when Connect refuses.
    ///
    /// Spotify's queue is meaningless during that window: the Connect play empties it before
    /// anything replaces it, and `mirrorSpotifyQueue` would take that at face value, wipe the
    /// app's queue and leave `currentSong` nil — which is the mini player vanishing mid-track.
    @ObservationIgnored
    private var isSpotifyPlayInFlight = false
    /// Which confirm run is the current one.
    ///
    /// Each skip starts a run of re-reads spread over a second or more. Tapping skip twice used
    /// to leave two runs going at once, both writing the track and position from whenever their
    /// own poll happened to land — so an older, staler answer could arrive after a newer one and
    /// drag the player back to the previous track. Only the newest run is allowed to write.
    @ObservationIgnored
    private var spotifyConfirmGeneration = 0
    @ObservationIgnored
    /// Read on every poll by default. Spotify has no change signal for its queue, and the app's
    /// copy drifting from it is precisely the complaint this is here to prevent.
    private let spotifyPollsPerQueueRead: Int
    @ObservationIgnored
    private var mpdClient: MPDClientProtocol?
    @ObservationIgnored
    private var isRemoteMode = false
    @ObservationIgnored
    private var statusPollTask: Task<Void, Never>?
    /// Resolves one of MPD's queue file URIs back to our SwiftData Song for the active
    /// network source, supplied by whoever calls setActiveSource (RootView, in practice).
    @ObservationIgnored
    private var songResolver: (String) -> Song? = { _ in nil }
    /// MPD's queue version last reconciled against. Nil forces a fetch on the next poll —
    /// used both at startup and whenever setActiveSource runs, so a freshly (re)connected
    /// client always confirms the real queue at least once before trusting a local guess.
    @ObservationIgnored
    private var lastKnownPlaylistVersion: Int?
    /// Kept so a dropped remote session can be rebuilt without re-selecting the source.
    @ObservationIgnored
    private var remoteEndpoint: (host: String, port: UInt16)?
    @ObservationIgnored
    private var consecutivePollFailures = 0
    /// The server's own transport state ("play"/"pause"/"stop"), as of the last poll. MPD
    /// distinguishes *paused* from *stopped*, and only the former responds to `pause 0` — so
    /// resuming out of a stop has to be sent as `play <pos>` instead.
    @ObservationIgnored
    private var remoteServerState: String?
    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Holds the system "now playing" slot while the server is playing — see the type's docs.
    @ObservationIgnored
    private let remoteKeepAlive: NowPlayingSessionHolding
    /// Foreground cadence keeps the UI in step; the background one exists mainly to stop MPD
    /// closing the connection as idle (its `connection_timeout` defaults to 60s), which is what
    /// made the lock-screen controls die after about a minute.
    /// The last elapsed time the server reported, and when we heard it. Between polls the clock
    /// is advanced locally from this rather than by asking the host again — MPD's `elapsed` only
    /// moves at wall-clock speed, so a poll per UI frame told us nothing we couldn't work out,
    /// and it put a request per tick on a host that also has artwork and playback to serve.
    @ObservationIgnored
    private var remoteTimeAnchor: (elapsed: TimeInterval, at: Date)?
    /// Drives the interpolated clock. Purely local — it issues no requests.
    @ObservationIgnored
    private var remoteClockTask: Task<Void, Never>?
    /// Set once the interpolated clock runs past the track length, so the poll that confirms the
    /// track change is requested once rather than on every tick.
    @ObservationIgnored
    private var hasRequestedEndOfTrackPoll = false
    @ObservationIgnored
    private static let remoteClockTickNanoseconds: UInt64 = 250_000_000
    /// Polls are for state the app can't derive — track changes, queue edits, someone else's
    /// pause. The clock between them is interpolated, so this no longer has to be fast.
    @ObservationIgnored
    private static let foregroundPollIntervalNanoseconds: UInt64 = 2_000_000_000
    @ObservationIgnored
    private var pollIntervalNanoseconds: UInt64 = foregroundPollIntervalNanoseconds
    @ObservationIgnored
    private static let backgroundPollIntervalNanoseconds: UInt64 = 20_000_000_000

    private func setQueue(_ newQueue: [Song]) {
        queueStorage = newQueue
        refreshCurrentSongID()
    }

    private func setCurrentIndex(_ newIndex: Int?) {
        currentIndexStorage = newIndex
        refreshCurrentSongID()
    }

    /// Assign-on-change: writing the same value would still notify observers, and the whole
    /// point of this property is to leave the library lists alone unless the track really moved.
    private func refreshCurrentSongID() {
        let id = currentSong?.persistentModelID
        if currentSongID != id {
            currentSongID = id
        }
    }

    var currentSong: Song? {
        guard let currentIndexStorage, queueStorage.indices.contains(currentIndexStorage) else { return nil }
        return queueStorage[currentIndexStorage]
    }

    /// Whether `song` is the track the player currently has loaded. Matched on identity rather
    /// than queue position, so it holds for library lists (where a song appears once) as well as
    /// the queue, and in remote mode as well as local — the MPD queue is resolved back to these
    /// same SwiftData songs.
    func isCurrent(_ song: Song) -> Bool {
        currentSongID == song.persistentModelID
    }

    /// Where a queue's transport commands go. Three routes now: this device's own AVPlayer, an
    /// MPD server, or whichever Spotify client is active. Derived from the song rather than a
    /// mode flag, so routing can't disagree with the data.
    enum PlaybackRoute {
        case local
        case mpd
        case spotify
    }

    private func route(for song: Song) -> PlaybackRoute {
        switch song.source?.kind {
        case .network: return .mpd
        case .spotify: return .spotify
        default: return .local
        }
    }

    /// The route for the *current* queue. Falls back to `queue.first` when nothing is loaded
    /// (e.g. right after `setActiveSource` clears `currentIndex`), so it stays correct across
    /// the whole queue, not just whatever's presently playing.
    private var currentRoute: PlaybackRoute {
        if let song = currentSong ?? queue.first {
            return route(for: song)
        }
        // With nothing loaded, fall back to the active source. Spotify's queue can hold only
        // tracks this app never imported, which leaves the library-backed queue empty — and
        // routing to the local player then would be plainly wrong.
        if isSpotifyMode { return .spotify }
        if isRemoteMode { return .mpd }
        return .local
    }

    /// Whether transport controls acting on the current queue route through MPD.
    private var isRemoteQueue: Bool { currentRoute == .mpd }
    private var isSpotifyQueue: Bool { currentRoute == .spotify }

    init(
        makeMPDClient: @escaping () -> MPDClientProtocol = { MPDClient() },
        // Defaulted to nil and built inside: a default argument expression is evaluated at the
        // call site, which isn't main-actor isolated.
        remoteKeepAlive: NowPlayingSessionHolding? = nil,
        mediaLibrary: MediaLibraryProviding? = nil,
        spotify: SpotifyPlaybackControlling? = nil,
        // How many transport polls pass between reads of Spotify's queue. Spotify has no
        // queue-version counter, so this is a plain cadence rather than a change signal.
        spotifyPollsPerQueueRead: Int = 1,
        spotifyConfirmSpacingNanoseconds: UInt64 = 500_000_000
    ) {
        self.spotifyConfirmSpacingNanoseconds = spotifyConfirmSpacingNanoseconds
        self.spotifyPollsPerQueueRead = max(1, spotifyPollsPerQueueRead)
        self.makeMPDClient = makeMPDClient
        self.remoteKeepAlive = remoteKeepAlive ?? SilentAudioKeepAlive()
        self.mediaLibrary = mediaLibrary ?? SystemMediaLibrary()
        self.makeSpotify = {
            spotify ?? SpotifyPlaybackController(
                session: .shared,
                client: SpotifyWebAPIClient(),
                appRemote: SpotifyAppRemote.shared
            )
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Safe: this closure is dispatched on `.main`, so it always runs on the main actor
            // even though the AVFoundation callback type isn't annotated as such.
            MainActor.assumeIsolated {
                guard let self, !self.isRemoteQueue else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.updateNowPlayingElapsedTime()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRemoteQueue else { return }
                self.skipToNext()
            }
        }

        registerRemoteCommands()

        // Both of these concern *this app's* audio session, so they apply only to the local
        // player — the same rule the two observers above already follow.
        //
        // Unguarded, they were fatal to Spotify. An interruption notification means something
        // else took audio focus, and in Spotify mode that something is Spotify itself starting
        // to play. The app answered by sending Spotify a pause, so every attempt to play killed
        // the playback it had just started. A route change is the same story: unplugging
        // headphones from this phone says nothing about a speaker on the other side of Connect,
        // and nothing about MPD playing through a server's own output.
        AudioSessionManager.shared.onInterruptionBegan = { [weak self] in
            guard let self, self.currentRoute == .local else { return }
            self.pause()
        }
        AudioSessionManager.shared.onRouteChangedDeviceUnavailable = { [weak self] in
            guard let self, self.currentRoute == .local else { return }
            self.pause()
        }

        observeAppLifecycle()
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendRemotePolling() }
            }
        )
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeRemoteSession() }
            }
        )
    }

    deinit {
        statusPollTask?.cancel()
        spotifyPollTask?.cancel()
        remoteClockTask?.cancel()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Active source

    /// Switches playback between local (AVPlayer) and remote (MPD) modes based on the
    /// currently active Source. Only one source is active at a time, so switching always
    /// tears down whatever was playing before.
    func setActiveSource(_ source: Source?, resolveSong: @escaping (String) -> Song? = { _ in nil }) {
        // Switching source is destructive — it stops playback and empties the queue — so it must
        // happen only when the source has genuinely changed. This is driven by `onChange` on a
        // value computed over a `@Query`, and any transient recomputation that momentarily
        // yields a different result would otherwise clear the queue out from under the user,
        // which looks like the mini player vanishing for no reason.
        let newSourceID = source?.persistentModelID
        if newSourceID == activeSourceID {
            // The resolver closes over the source's songs, so it is refreshed even on a repeat
            // call: a resync replaces those rows.
            songResolver = resolveSong
            return
        }
        activeSourceID = newSourceID

        statusPollTask?.cancel()
        statusPollTask = nil
        // Leaving a Spotify source stops its music, the same courtesy the MPD path extends —
        // otherwise it plays on from a source the app is no longer showing. Sent whether or not
        // this app believes it is playing: the device may have been started from Spotify itself.
        if isSpotifyMode {
            print("PlaybackManager: pausing Spotify — active source changed")
            performSpotifyCommand { try await $0.pause() }
        }
        if let previousClient = mpdClient {
            // Tell the server to stop before dropping the connection — otherwise switching
            // away from a network source leaves it playing on the server indefinitely, since
            // disconnecting a control client doesn't stop MPD's playback.
            Task {
                try? await previousClient.stop()
                await previousClient.disconnect()
            }
        }
        mpdClient = nil
        isRemoteMode = false
        remoteEndpoint = nil
        songResolver = resolveSong
        lastKnownPlaylistVersion = nil
        remoteServerState = nil

        stopAndClear()
        remoteClockTask?.cancel()
        remoteClockTask = nil
        remoteTimeAnchor = nil
        remoteKeepAlive.stop()
        setQueue([])
        setCurrentIndex(nil)
        isHostSyncingDatabase = false

        spotifyPollTask?.cancel()
        spotifyPollTask = nil
        isSpotifyMode = false
        isSpotifyOfflineMode = false
        playbackErrorMessage = nil
        spotifyQueue = []

        if let source, source.kind == .spotify {
            isSpotifyMode = true
            isSpotifyOfflineMode = source.isOfflineMode
            spotify.configure(clientID: source.spotifyClientID)
            spotify.selectDevice(id: source.spotifyDeviceID)
            // No poll offline: it asks Spotify's servers what is playing, which is exactly what
            // cannot be reached. The local clock still advances, so the player keeps time.
            if !isSpotifyOfflineMode { startSpotifyPolling() }
            return
        }

        guard let source, source.kind == .network, !source.host.isEmpty else { return }

        isRemoteMode = true
        remoteEndpoint = (source.host, UInt16(clamping: max(0, source.port)))
        openRemoteSession()
    }

    /// Builds a fresh client and connects. Always a *new* client rather than reusing the old
    /// one: a connection torn down while suspended can leave its actor blocked on a read that
    /// will never complete, and abandoning it sidesteps that entirely. This is also why
    /// switching source and back was the only way to recover — that path already built a new one.
    private func openRemoteSession() {
        guard let endpoint = remoteEndpoint else { return }
        let client = makeMPDClient()
        mpdClient = client
        consecutivePollFailures = 0
        lastKnownPlaylistVersion = nil // force a queue re-sync against the server
        Task { [weak self] in
            do {
                try await client.connect(host: endpoint.host, port: endpoint.port)
                self?.startStatusPolling()
            } catch {
                print("PlaybackManager: failed to connect to MPD host \(endpoint.host):\(endpoint.port) — \(error)")
            }
        }
    }

    /// Backgrounding. If the server is playing we're holding the audio session, so the app
    /// stays alive and the lock-screen widget is live — in that case keep a slow poll going,
    /// both to refresh the widget and, crucially, to stop MPD dropping the connection as idle.
    /// Otherwise stop entirely: there's no UI to update and iOS will suspend us anyway.
    func suspendRemotePolling() {
        // Spotify's poll is a web API call, not a socket read against a server on the LAN, and
        // it was left running when the app went to the background — indefinitely, every couple
        // of seconds. That is both wasted battery and a straight path to being rate limited.
        spotifyPollTask?.cancel()
        spotifyPollTask = nil

        guard remoteEndpoint != nil else {
            statusPollTask?.cancel()
            statusPollTask = nil
            return
        }
        if remoteKeepAlive.isRunning {
            pollIntervalNanoseconds = Self.backgroundPollIntervalNanoseconds
            startStatusPolling()
        } else {
            statusPollTask?.cancel()
            statusPollTask = nil
        }
    }

    /// Foregrounding: resume polling, reconnecting first if the session was lost while away.
    func resumeRemoteSession() {
        if isSpotifyMode, spotifyPollTask == nil {
            startSpotifyPolling()
        }
        guard remoteEndpoint != nil else { return }
        pollIntervalNanoseconds = Self.foregroundPollIntervalNanoseconds
        lastKnownPlaylistVersion = nil // re-sync the queue against the server
        if mpdClient == nil {
            openRemoteSession()
        } else {
            startStatusPolling()
        }
    }

    /// Runs a command against the server, reconnecting and retrying once if the connection has
    /// gone away — which it will whenever iOS has suspended the app. Without this, a transport
    /// command from the lock screen after a spell in the background would silently do nothing.
    /// - Parameter reconcile: whether to re-read server state straight after. Queue-mutating
    ///   commands need it so the queue and index reflect what the server actually did. Plain
    ///   transport toggles must not: the poll can still report the pre-command state, which
    ///   would undo the optimistic update and flicker the play/pause button.
    private func performRemoteCommand(
        reconcile: Bool = true,
        _ body: @escaping (MPDClientProtocol) async throws -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            if let client = self.mpdClient {
                do {
                    try await body(client)
                    // Reconcile straight away rather than waiting for the next poll tick, so
                    // the queue and index reflect what the server actually did.
                    if reconcile { await self.pollRemoteStatus() }
                    return
                } catch {
                    print("PlaybackManager: remote command failed, reconnecting — \(error)")
                }
            }
            guard let client = await self.reconnectedClient() else { return }
            do {
                try await body(client)
                if reconcile { await self.pollRemoteStatus() }
            } catch {
                print("PlaybackManager: remote command failed after reconnect — \(error)")
            }
        }
    }

    /// Moves playback to a particular Spotify Connect device, or back to automatic when nil.
    ///
    /// The queue and the playing track are carried across rather than discarded: a Connect
    /// transfer moves the session — track, position and all — to the new device, which is what
    /// the endpoint exists for. Stopping and clearing first bought nothing.
    /// Switches offline mode on or off while a Spotify source stays active.
    ///
    /// Needed because the flag is otherwise only read in `setActiveSource`, which runs when the
    /// *source* changes — and flipping the switch mutates the source without changing which one
    /// is active. So the setting never reached here, and every command kept going out to Connect
    /// and failing: `404 Device not found`, `0 device(s)`, over and over.
    func setSpotifyOfflineMode(_ isOn: Bool) {
        guard isSpotifyOfflineMode != isOn else { return }
        isSpotifyOfflineMode = isOn
        guard isSpotifyMode else { return }

        if isOn {
            // The poll can only ask Spotify's servers what is playing, which is the one thing
            // that cannot be reached.
            spotifyPollTask?.cancel()
            spotifyPollTask = nil
        } else {
            startSpotifyPolling()
        }
    }

    func selectSpotifyDevice(id: String?) {
        playbackErrorMessage = nil
        guard isSpotifyMode else {
            spotify.selectDevice(id: id)
            return
        }

        let shouldKeepPlaying = isPlaying
        spotify.selectDevice(id: id)

        guard let id else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.spotify.takeOverDevice(id: id, play: shouldKeepPlaying)
            } catch {
                self.playbackErrorMessage = (error as? SpotifyError)?.errorDescription
                    ?? error.localizedDescription
                return
            }
            await self.confirmTransfer(toDeviceID: id)
        }
    }

    /// Checks the transfer actually landed. Spotify accepts the request before the device has
    /// picked it up, and a device can decline it quietly — so an unverified switch is exactly
    /// the "sometimes it works" behaviour this is meant to remove.
    private func confirmTransfer(toDeviceID id: String) async {
        for _ in 0..<Self.spotifyTransferConfirmAttempts {
            try? await Task.sleep(nanoseconds: spotifyConfirmSpacingNanoseconds)
            guard isSpotifyMode, !Task.isCancelled else { return }

            if let state = try? await spotify.playerState() {
                await applySpotifyState(state)
                if state.activeDeviceID == id {
                    playbackErrorMessage = nil
                    return
                }
            }
        }
        // The transfer didn't land. If the target is this phone, Connect was never going to move
        // it — the same refusal that stops Connect *playing* here — and the Spotify app has to
        // be driven directly instead.
        //
        // Reached only after the transfer has actually failed, never in anticipation. Driving it
        // directly means launching Spotify, which puts its authorization screen in front of the
        // user; doing that on every switch to the phone, as this briefly did, is far worse than
        // a transfer that usually works.
        if id == localSpotifyDeviceID, !queue.isEmpty {
            let ids = queue.map(\.relativePath)
            let startIndex = currentIndex ?? 0
            do {
                print("PlaybackManager: transfer to this phone didn't land — driving the Spotify app directly")
                try await spotify.playOnLocalApp(
                    trackIDs: ids,
                    startAt: startIndex,
                    canUseConnection: !isSpotifyOfflineMode
                )
                showQueueHandedToLocalSpotify(trackIDs: ids, startAt: startIndex)
                playbackErrorMessage = nil
                await confirmSpotifyState()
                return
            } catch {
                print("PlaybackManager: couldn't move playback to this phone — \(error)")
            }
        }

        playbackErrorMessage = "Spotify didn't move playback to that device. It may have gone offline — try Refresh Devices."
    }

    @ObservationIgnored
    private static let spotifyTransferConfirmAttempts = 6

    /// Reports a refused command and undoes the optimistic state that went with it — otherwise
    /// the UI keeps claiming to play something that never started.
    private func reportSpotifyFailure(_ error: Error) {
        reportSpotifyFailure(message: (error as? SpotifyError)?.errorDescription ?? error.localizedDescription)
        // Only worth offering when it isn't already on, and only for the failures offline mode
        // actually answers. A refused command or an unreachable device is a different problem,
        // and offering offline mode for those would be noise.
        if !isSpotifyOfflineMode, Self.isSpotifyAuthorizationFailure(error) {
            isSuggestingSpotifyOfflineMode = true
        }
    }

    /// Reports a failure in this app's own words, and undoes the optimistic playing state that
    /// went with the attempt.
    ///
    /// The state reset is the point. The fallback's own failures set a message and nothing else,
    /// so when Connect refused *and* the Spotify app couldn't be used, the player went on
    /// claiming to play something that never started.
    private func reportSpotifyFailure(message: String) {
        playbackErrorMessage = message
        isPlaying = false
        syncRemoteClock()
        updateNowPlayingPlaybackState()
    }

    /// Choosing a track in Spotify mode plays it the way Spotify does: it replaces what is
    /// queued with that track and the rest of its album, starting there.
    ///
    /// Inserting into Spotify's queue instead — which this used to do — reads as arbitrary,
    /// because the inserted track waits behind whatever was already lined up rather than
    /// playing, and the two lists then disagree about what "the queue" is.
    private func playSpotifyFromAlbum(startingAt song: Song) {
        let tail = albumTail(from: song)
        seedSpotifyQueue(with: tail)
        sendSpotifyContext(tail.map(\.relativePath))
    }

    /// Shows what has just been asked for, without waiting for Spotify to confirm it.
    ///
    /// Choosing a track left the queue and the mini player on the previous one until the mirror
    /// caught up, because this path populated them from Spotify's own report and nothing else —
    /// a round trip and a poll away. `play(songs:)` never had that lag, for the simple reason
    /// that it sets the queue itself before sending anything.
    ///
    /// Safe to show first and check afterwards: this app chose the context, so what it is about
    /// to send is almost always exactly what Spotify will report back. When it isn't — shuffle
    /// being on, say — the confirm that follows corrects it within a fraction of a second, and
    /// `isSpotifyPlayInFlight` keeps the empty read in between from wiping it meanwhile.
    private func seedSpotifyQueue(with songs: [Song]) {
        guard !songs.isEmpty else { return }

        setQueue(songs)
        setCurrentIndex(0)
        currentTime = 0
        duration = songs[0].duration
        showSpotifyQueue(from: songs, startAt: 0)
        updateNowPlayingInfo()
    }

    /// Fills the Queue screen from what is about to be sent, so it is right on tap rather than a
    /// poll later. Spotify's own report replaces it as soon as the mirror next runs.
    private func showSpotifyQueue(from songs: [Song], startAt index: Int) {
        let start = min(max(index, 0), max(songs.count - 1, 0))
        spotifyQueue = songs[start...].enumerated().map { position, song in
            SpotifyQueueEntry(
                trackID: song.relativePath,
                title: song.title,
                artist: song.artist,
                // The row draws its cover from this. Seeding it nil is what made the artwork
                // vanish the moment a track was tapped and come back only when Spotify's own
                // report arrived, carrying the same URL the library already had.
                artworkURL: song.album?.artworkURL,
                position: position
            )
        }
    }

    /// A track and everything after it on its album, in track order. Just the track itself when
    /// it belongs to no album this app knows about.
    private func albumTail(from song: Song) -> [Song] {
        guard let album = song.album else { return [song] }
        let ordered = album.songs.sorted { $0.track < $1.track }
        guard let index = ordered.firstIndex(where: { $0.persistentModelID == song.persistentModelID }) else {
            return [song]
        }
        return Array(ordered[index...])
    }

    /// Replaces what Spotify is playing with this list, from its first track, then re-reads so
    /// the queue on screen is Spotify's rather than a guess at it.
    private func sendSpotifyContext(_ trackIDs: [String]) {
        guard !trackIDs.isEmpty else { return }
        currentTime = 0
        remoteTimeAnchor = (elapsed: 0, at: Date())
        isPlaying = true
        syncRemoteClock()
        Task { [weak self] in
            guard let self else { return }
            self.isSpotifyPlayInFlight = true
            // Cleared however this Task ends. A play that throws returns straight out of the
            // catch below, and clearing only on the success path left the flag stuck on —
            // which switches the queue mirror off for the rest of the session, on every
            // device, not just the one that failed.
            defer { self.isSpotifyPlayInFlight = false }

            // Connect is a web service, so with no network every command waits out its timeout
            // before failing through to the fallback that was always going to handle it. Offline
            // mode skips straight past, which is the whole point of the setting.
            if self.isSpotifyOfflineMode {
                await self.driveLocalSpotify(trackIDs: trackIDs, startAt: 0)
                return
            }
            self.logAudioSessionState("before play")
            do {
                try await self.spotify.play(trackIDs: trackIDs, startAt: 0)
                self.playbackErrorMessage = nil
            } catch where Self.meansConnectHasNowhereToPlay(error) {
                // Connect found no device it can drive. Reporting that gave up while a perfectly
                // good player sat on this very phone — so the Spotify app is launched and told
                // to play instead, which is the one thing Connect cannot do.
                await self.driveLocalSpotify(trackIDs: trackIDs, startAt: 0)
                return
            } catch {
                self.reportSpotifyFailure(error)
                return
            }
            await self.confirmSpotifyState()
            await self.recoverOnLocalSpotifyIfNotPlaying(trackIDs: trackIDs, startAt: 0)
        }
    }

    /// Reports this app's audio session state around a Spotify command.
    ///
    /// Spotify on *this* phone is the only target that can be harmed by it. `.playback` is an
    /// exclusive category, so if this app holds an active session while Spotify is asked to
    /// change what it is playing, Spotify has to re-acquire the session to start the new context
    /// — and a backgrounded app that is refused it cannot get it back. It stops, and clears what
    /// it was playing. A Mac is untouched by any of this, which is the asymmetry being chased.
    private func logAudioSessionState(_ moment: String) {
        let session = AVAudioSession.sharedInstance()
        print("""
        PlaybackManager[session/\(moment)]: category=\(session.category.rawValue) \
        options=\(session.categoryOptions.rawValue) \
        otherAudioPlaying=\(session.isOtherAudioPlaying) \
        keepAliveRunning=\(remoteKeepAlive.isRunning)
        """)
    }

    /// Falls back to driving the Spotify app on this phone directly when Connect would not.
    ///
    /// The Web API drives a Mac or a speaker without trouble, and fails on the Spotify app
    /// running on this same phone in three different ways — refusing with 403 "Restriction
    /// violated", or accepting with 204 and then stopping with no track and an empty queue.
    /// Some of those arrive as errors and some as apparent success, so the only reliable test
    /// is whether Spotify is actually playing once the confirm polls have had their say.
    ///
    /// App Remote talks to the local Spotify process directly and can launch it when it isn't
    /// running, so it succeeds where the Connect command did not.
    /// Which Connect device *is* this phone, learned rather than guessed.
    ///
    /// Nothing in the device list says "this one is you" — the name is whatever the phone is
    /// called and the id changes between Spotify app sessions, so matching on either is
    /// guesswork, and guessing it wrong is what caused two earlier bugs. But App Remote only
    /// ever drives the Spotify app on this phone, so after it has played, whatever `/me/player`
    /// then names *is* this phone. That is worth remembering: it is the only way to know that a
    /// device the user picks in Sources is the one Connect cannot start playback on.
    @ObservationIgnored
    private static let localDeviceIDKey = "spotify.localDeviceID"

    private var localSpotifyDeviceID: String? {
        get { UserDefaults.standard.string(forKey: Self.localDeviceIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.localDeviceIDKey) }
    }

    /// Shows the queue just handed to the Spotify app, without waiting for Spotify to report it.
    ///
    /// Only a head start: Spotify's own account takes over as soon as the mirror next runs, and
    /// is the better one. This exists so the Queue screen is right the instant playback starts
    /// rather than a poll later.
    private func showQueueHandedToLocalSpotify(trackIDs: [String], startAt index: Int) {
        let start = min(max(index, 0), max(trackIDs.count - 1, 0))
        let lined = Array(trackIDs[start...])
        let songsByID = Dictionary(queue.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        spotifyQueue = lined.enumerated().map { position, id in
            let song = songsByID[id]
            return SpotifyQueueEntry(
                trackID: id,
                title: song?.title ?? "",
                artist: song?.artist ?? "",
                artworkURL: song?.album?.artworkURL,
                position: position
            )
        }
    }

    /// How many tracks to line up behind the playing one. Spotify's queue endpoint takes a
    /// single track per request, so a whole library's worth would be hundreds of round trips.
    @ObservationIgnored
    private static let maximumSpotifyQueueAdds = 50

    /// Builds Spotify's own queue behind a track the Spotify app was told to play.
    ///
    /// Starting playback and building a queue need different tools on this phone, and using the
    /// wrong one for either fails silently. App Remote can start playback where Connect cannot,
    /// but it cannot build a queue — its enqueue reports success for every track and Spotify
    /// keeps exactly one, so the next button had nothing to go to. Once something *is* playing,
    /// though, the phone takes ordinary Web API commands like any other device, and the queue
    /// endpoint appends without disturbing what is playing.
    ///
    /// So: App Remote starts it, the Web API queues behind it.
    private func buildSpotifyQueueBehindTheCurrentTrack(trackIDs: [String], startAt index: Int) async {
        // Not offline: this builds the queue over the Web API, which is the one thing that
        // cannot be reached. The Spotify app plays the track it was handed either way; only the
        // tracks behind it are lost, and waiting out a timeout each would be worse.
        guard !isSpotifyOfflineMode else { return }

        let start = min(max(index, 0), max(trackIDs.count - 1, 0))
        let remainder = Array(trackIDs[start...].dropFirst().prefix(Self.maximumSpotifyQueueAdds))
        guard !remainder.isEmpty else { return }

        var queued = 0
        for id in remainder {
            do {
                try await spotify.addToQueue(trackID: id)
                queued += 1
            } catch {
                // One refusal means the rest will be refused too; stop rather than hammering it.
                print("PlaybackManager: Spotify wouldn't queue \(id) — \(error)")
                break
            }
        }
        print("PlaybackManager: queued \(queued) of \(remainder.count) behind the playing track")

        // If Spotify took the whole queue then it can report it too, and its own account of what
        // is lined up is better than this app's guess — so the mirror is let back in. If it
        // didn't, the app's own list stays on screen, which is the more useful of two wrongs.
        if queued == remainder.count {
        }
    }


    /// Called only after App Remote has actually played, which is what makes the answer true.
    private func learnLocalSpotifyDeviceID() {
        // Reads /me/player, so there is nothing to learn offline.
        guard !isSpotifyOfflineMode else { return }
        Task { [weak self] in
            guard let self,
                  let state = try? await self.spotify.playerState(),
                  let id = state.activeDeviceID,
                  id != self.localSpotifyDeviceID
            else { return }
            print("PlaybackManager: this phone is Spotify device \(id)")
            self.localSpotifyDeviceID = id
        }
    }

    private func recoverOnLocalSpotifyIfNotPlaying(trackIDs: [String], startAt index: Int) async {
        guard isSpotifyMode, !isPlaying, !trackIDs.isEmpty else { return }
        await driveLocalSpotify(trackIDs: trackIDs, startAt: index)
    }

    /// Whether Spotify refused for want of authorization.
    ///
    /// Both of these mean the stored token cannot be used and cannot be renewed without the
    /// network — which is exactly what a lost connection produces.
    static func isSpotifyAuthorizationFailure(_ error: Error) -> Bool {
        switch error as? SpotifyError {
        case .notSignedIn, .permissionsMissing: true
        default: false
        }
    }

    /// Whether Connect has reported that it has nowhere to play at all.
    ///
    /// Distinct from a command being refused by a device: these mean Spotify could find no
    /// device it is able to drive. On this phone that is not the dead end it looks like — the
    /// Spotify app can be launched and told to play, which is the one thing Connect cannot do.
    static func meansConnectHasNowhereToPlay(_ error: Error) -> Bool {
        switch error as? SpotifyError {
        case .noActiveDevice, .onlyRestrictedDevices: true
        default: false
        }
    }

    /// Plays on the Spotify app on this phone, launching it if need be.
    private func driveLocalSpotify(trackIDs: [String], startAt index: Int) async {
        guard isSpotifyMode, !trackIDs.isEmpty else { return }

        do {
            print("PlaybackManager: driving the Spotify app on this phone directly")
            // Offline there is no point waiting for the handshake: Spotify cannot complete
            // authorization without the network, so the wait only delays the UI by its timeout.
            try await spotify.playOnLocalApp(
                trackIDs: trackIDs,
                startAt: index,
                canUseConnection: !isSpotifyOfflineMode
            )
            playbackErrorMessage = nil
            showQueueHandedToLocalSpotify(trackIDs: trackIDs, startAt: index)
            await confirmSpotifyState()
            learnLocalSpotifyDeviceID()
            await buildSpotifyQueueBehindTheCurrentTrack(trackIDs: trackIDs, startAt: index)
        } catch SpotifyAppRemoteError.spotifyNotInstalled {
            // Nothing on this phone to fall back on either, so the original complaint stands.
            reportSpotifyFailure(message: "Spotify has no device available to play on. Open the Spotify app on this phone, then try again.")
        } catch {
            print("PlaybackManager: the Spotify app wouldn't play either — \(error)")
            reportSpotifyFailure(message: "Couldn't start playback in the Spotify app. Open it and try again.")
        }
    }

    /// Plays from a given point in Spotify's own queue. Used by the Queue screen, which shows
    /// Spotify's queue rather than the library-backed one, so the entry tapped may be a track
    /// with no row here at all.
    func playSpotifyQueueEntry(at position: Int) {
        guard isSpotifyMode, spotifyQueue.indices.contains(position) else { return }
        // The same rule as tapping a track: what is chosen goes to the top and the rest follows.
        let chosen = Array(spotifyQueue[position...])

        // Shown straight away, for the same reason as choosing a track from the library. The
        // entries are Spotify's own, so they carry titles for tracks this app never imported —
        // renumbered from the top, since that is what the queue now is.
        spotifyQueue = chosen.enumerated().map { index, entry in
            var renumbered = entry
            renumbered.position = index
            return renumbered
        }
        let songs = chosen.compactMap { songResolver($0.trackID) }
        if !songs.isEmpty {
            setQueue(songs)
            setCurrentIndex(0)
        }
        currentTime = 0
        updateNowPlayingInfo()

        sendSpotifyContext(chosen.map(\.trackID))
    }

    /// Sends a skip and then reads Spotify's state back promptly, rather than predicting the
    /// result. Without the read-back the app would sit on a stale track for a whole poll
    /// interval; without dropping the prediction it would show a wrong one.
    private func skipSpotify(_ body: @escaping (SpotifyPlaybackControlling) async throws -> Void) {
        // Offline there is nothing to drive: the track was handed to Spotify with a deep link,
        // and every transport command goes out over the Web API. Sending them anyway just waits
        // out timeouts and reports failures the user can do nothing about.
        guard !isSpotifyOfflineMode else {
            playbackErrorMessage = "Offline mode hands tracks to the Spotify app — use its own controls to skip."
            return
        }
        currentTime = 0
        remoteTimeAnchor = (elapsed: 0, at: Date())
        Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self.spotify)
                self.playbackErrorMessage = nil
            } catch {
                self.reportSpotifyFailure(error)
                return
            }
            await self.confirmSpotifyState()
        }
    }

    /// Back is not quite a skip. Spotify's "previous" restarts the current track when it is more
    /// than a few seconds in, and refuses outright at the start of a context — there being
    /// nothing before it. A refusal there is not an error to report: restarting the track is what
    /// the button is for.
    private func skipSpotifyBack() {
        guard !isSpotifyOfflineMode else {
            playbackErrorMessage = "Offline mode hands tracks to the Spotify app — use its own controls to skip."
            return
        }
        currentTime = 0
        remoteTimeAnchor = (elapsed: 0, at: Date())
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.spotify.skipToPrevious()
                self.playbackErrorMessage = nil
            } catch SpotifyError.actionNotAllowed {
                // Nothing before this track: go back to its beginning instead.
                try? await self.spotify.seek(to: 0)
                self.playbackErrorMessage = nil
            } catch {
                self.reportSpotifyFailure(error)
                return
            }
            await self.confirmSpotifyState()
        }
    }

    /// Re-reads Spotify a few times in quick succession after a command it should have changed.
    /// A skip takes a moment to land, and the ordinary poll runs seconds apart.
    private func confirmSpotifyState(attempts: Int = 3) async {
        spotifyConfirmGeneration &+= 1
        let generation = spotifyConfirmGeneration

        for attempt in 0..<attempts {
            // The first read comes quickly. A skip usually lands in a fraction of a second, and
            // waiting the full spacing before even looking is most of what made skipping feel
            // slow — the button did nothing visible until the poll after it. Later reads keep
            // the original spacing, for the times Spotify takes longer to settle.
            let delay = attempt == 0
                ? spotifyConfirmSpacingNanoseconds / 4
                : spotifyConfirmSpacingNanoseconds
            try? await Task.sleep(nanoseconds: delay)

            // A newer skip supersedes this run: its answer is the current one, and letting both
            // write is what made rapid skipping jump about.
            guard isSpotifyMode, !Task.isCancelled, generation == spotifyConfirmGeneration else { return }
            await pollSpotifyState()
            // The queue moves with the track, so it comes along on the first read as well as the
            // last: waiting for the last one left the Queue screen a second behind a change the
            // player had already shown.
            if attempt == 0 || attempt == attempts - 1 {
                await mirrorSpotifyQueue()
            }
        }

        // Restart the ordinary poll from here.
        //
        // Its interval is chosen *before* it sleeps, from whatever `isPlaying` said at the time —
        // and a poll that catches Spotify between tracks, which is routine straight after a skip
        // or a context change, reads as "not playing" and commits the loop to the fifteen-second
        // idle wait. Nothing wakes it early, so the queue and player then sat unchanged for up to
        // twenty seconds while the music carried on. Restarting it here re-reads immediately and
        // picks the interval from state that is a moment old rather than a skip old.
        guard isSpotifyMode, !Task.isCancelled, generation == spotifyConfirmGeneration else { return }
        startSpotifyPolling()
    }

    /// How long to leave between the re-reads that confirm a Spotify command landed. An
    /// instance property rather than a constant so tests can collapse it: the confirm is what
    /// decides whether a play was silently ignored, and at the real spacing every test of that
    /// would sit for seconds.
    @ObservationIgnored
    private let spotifyConfirmSpacingNanoseconds: UInt64

    /// Runs a Spotify Connect command, reporting a refusal rather than leaving a button that
    /// silently does nothing. "No active device" is the common one and is not a fault: Spotify
    /// only accepts commands when one of its clients is running.
    private func performSpotifyCommand(_ body: @escaping (SpotifyPlaybackControlling) async throws -> Void) {
        // Same reasoning as the skips: offline these reach a service that cannot be reached.
        guard !isSpotifyOfflineMode else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self.spotify)
                self.playbackErrorMessage = nil
            } catch {
                let spotifyError = error as? SpotifyError
                self.playbackErrorMessage = spotifyError?.errorDescription ?? error.localizedDescription
                if spotifyError == .noActiveDevice {
                    self.isPlaying = false
                    self.syncRemoteClock()
                }
                print("PlaybackManager: Spotify command failed — \(error)")
            }
        }
    }

    /// Spotify is a rate-limited web API rather than a server on the local network, so this runs
    /// far slower than the MPD poll — and slower again when nothing is playing, since the only
    /// thing to notice then is somebody else starting something. The elapsed time between polls
    /// is interpolated locally, so a slow poll costs nothing visible.
    @ObservationIgnored
    private static let spotifyPlayingPollNanoseconds: UInt64 = 5_000_000_000
    @ObservationIgnored
    private static let spotifyIdlePollNanoseconds: UInt64 = 15_000_000_000

    private func startSpotifyPolling() {
        spotifyPollTask?.cancel()
        spotifyPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollSpotifyState()
                let interval = self.isPlaying
                    ? Self.spotifyPlayingPollNanoseconds
                    : Self.spotifyIdlePollNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Follows the active Spotify client, so the app reflects changes made from Spotify itself
    /// or another device. Same shape as the MPD poll, and it re-anchors the same local clock.
    private func pollSpotifyState() async {
        // Guarded here rather than at each caller: this asks Spotify's servers what is playing,
        // and offline there is nothing to ask. The player keeps time from the local clock.
        guard isSpotifyMode, !isSpotifyOfflineMode else { return }
        guard let state = try? await spotify.playerState() else { return }
        await applySpotifyState(state)

        spotifyPollsSinceQueueRead += 1
        if spotifyPollsSinceQueueRead >= spotifyPollsPerQueueRead {
            spotifyPollsSinceQueueRead = 0
            await mirrorSpotifyQueue()
        }
    }

    /// Takes what Spotify reports as the truth. Spotify owns playback in this mode, so nothing
    /// here second-guesses it.
    private func applySpotifyState(_ state: SpotifyPlayerState) async {
        // Where Spotify is playing is passed on, but only ever to *forget* a device discovered
        // earlier — never to pin commands to this one. /me/player keeps naming a device after it
        // has left Connect, so targeting what it reports sends commands somewhere that no longer
        // exists; but ignoring it entirely left the app talking to a speaker it picked up once,
        // long after playback had moved to the phone.
        spotify.noteActiveDevice(id: state.activeDeviceID)

        if isPlaying != state.isPlaying { isPlaying = state.isPlaying }
        remoteTimeAnchor = (elapsed: state.progressSeconds, at: Date())
        hasRequestedEndOfTrackPoll = false
        if currentTime != state.progressSeconds { currentTime = state.progressSeconds }

        let resolvedDuration = state.durationSeconds > 0 ? state.durationSeconds : (currentSong?.duration ?? duration)
        if duration != resolvedDuration { duration = resolvedDuration }

        // Follow the track Spotify says is playing, so skipping from the Spotify app moves the
        // highlight here too — but not in the moment just after this app has asked for a
        // different one. Spotify goes on reporting the outgoing track for a beat, and when that
        // track is also in the new queue (the usual case, since choosing a track replaces the
        // context with the rest of its own album) the player jumps back to it and sits showing
        // the wrong details until Spotify catches up. What was asked for is already on screen;
        // this only overrides it once the request has landed.
        if !isSpotifyPlayInFlight,
           let trackID = state.trackID,
           let index = queue.firstIndex(where: { $0.relativePath == trackID }),
           currentIndex != index {
            setCurrentIndex(index)
        }
        syncRemoteClock()
        updateNowPlayingInfo()
    }

    /// Reflects Spotify's own queue into the app's, so a track queued from the Spotify app —
    /// or from another device — appears here too.
    ///
    /// Tracks Spotify has lined up that aren't in this app's copy of the library can't be shown:
    /// the queue is made of the same Song rows the rest of the app browses, and something queued
    /// from a search was never imported. Those are skipped rather than faked.
    private func mirrorSpotifyQueue() async {
        // Offline the queue on screen is the one this app handed over; Spotify's own account of
        // it comes from a server that cannot be reached.
        guard !isSpotifyOfflineMode else { return }
        guard isSpotifyMode, let snapshot = try? await spotify.playbackQueue() else { return }

        // Kept whole, whether or not the tracks are in the library — this is what the Queue
        // screen shows, and a queue missing the rows Spotify actually has lined up is worse
        // than useless for following along.
        //
        // An empty read is only believed when Spotify also reports nothing playing. Right after
        // a context change it briefly returns nothing while it settles, and taking that at face
        // value emptied the queue and made it look as though playback had stopped.
        // Spotify reports a new context as it builds it, not all at once: for a second or two
        // after a play it answers with the first entry or two and the rest appear later. That is
        // not the user emptying the queue, so it is not applied — believing it collapsed a
        // freshly chosen album to a couple of tracks and refilled it seconds afterwards, which
        // is exactly what a queue "dropping to two songs" looked like.
        let isStillBuilding = isSpotifyPlayInFlight && snapshot.entries.count < spotifyQueue.count
        guard !isStillBuilding else { return }

        // `isSpotifyPlayInFlight` is the third reason not to believe an empty read, and the one
        // that was missing. A Connect play clears Spotify's queue before anything refills it, so
        // a mirror taken in that gap reports nothing queued and nothing playing — indistinguish-
        // able from the user having emptied it. Believing it wiped the app's queue, which left
        // `currentSong` nil and the mini player gone mid-track.
        //
        // Only the *empty* case is held back. A read that actually has entries is applied at
        // once, however in-flight the play is: suppressing those too meant the queue did not
        // catch up until the next poll, seconds later, which is its own kind of wrong.
        let isTransientlyEmpty = snapshot.entries.isEmpty
            && (snapshot.currentTrackID != nil || isPlaying || isSpotifyPlayInFlight)
        if snapshot.entries.isEmpty {
            // The moment the on-screen queue empties, and whether the app chose to believe it.
            print("PlaybackManager: Spotify queue read empty — playing=\(isPlaying), current=\(snapshot.currentTrackID ?? "none"), treatingAsTransient=\(isTransientlyEmpty)")
        }
        if !isTransientlyEmpty, spotifyQueue != snapshot.entries {
            spotifyQueue = snapshot.entries
        }
        guard !isTransientlyEmpty else { return }

        let ids = snapshot.orderedTrackIDs

        var mirrored: [Song] = []
        mirrored.reserveCapacity(ids.count)
        for id in ids {
            if let song = songResolver(id) {
                mirrored.append(song)
            }
        }

        // Emptied only when Spotify's queue is itself empty — never merely because none of what
        // Spotify reported could be resolved.
        //
        // `songResolver` maps Spotify's track ids back to library rows, and Spotify's queue
        // routinely holds tracks this app never imported: anything queued from a search, or
        // played from a context outside the saved library. Those resolve to nothing. Assigning
        // the result regardless emptied the app's queue whenever that happened, and an empty
        // queue means `currentSong` is nil — which is the mini player disappearing mid-track,
        // with the artwork and the track details going with it.
        //
        // Nothing is lost by keeping the old rows: the Queue screen reads `spotifyQueue` in
        // Spotify mode, which has already been updated from Spotify's own entries above.
        // Only ever replaced, never emptied.
        //
        // `songResolver` maps Spotify's ids back to library rows, and Spotify's queue routinely
        // holds tracks this app never imported — anything queued from a search, or a context
        // outside the saved library. Those resolve to nothing. An empty queue means `currentSong`
        // is nil, which is the mini player vanishing mid-track with the artwork and the track
        // details going with it, and that happened two ways: a read that resolved to nothing, and
        // an empty read believed after the in-flight flag had already been cleared by the poll
        // this confirm restarts.
        //
        // Nothing needs the clear. The Queue screen reads `spotifyQueue`, updated above from
        // Spotify's own entries, so an emptied Spotify queue still shows as empty there. Keeping
        // the library rows only means the player still knows what it is playing.
        let mirroredIDs = mirrored.map(\.relativePath)
        if !mirrored.isEmpty, queue.map(\.relativePath) != mirroredIDs {
            setQueue(mirrored)
        }
        // Spotify's queue starts at what is playing, so that is index 0 of the mirror.
        if let currentTrackID = snapshot.currentTrackID,
           let index = mirrored.firstIndex(where: { $0.relativePath == currentTrackID }),
           currentIndex != index {
            setCurrentIndex(index)
        }
    }

    private func reconnectedClient() async -> MPDClientProtocol? {
        guard let endpoint = remoteEndpoint else { return nil }
        if let previous = mpdClient {
            await previous.disconnect()
        }
        let client = makeMPDClient()
        do {
            try await client.connect(host: endpoint.host, port: endpoint.port)
            mpdClient = client
            consecutivePollFailures = 0
            lastKnownPlaylistVersion = nil
            return client
        } catch {
            print("PlaybackManager: reconnect failed — \(error)")
            mpdClient = nil
            return nil
        }
    }

    /// The widget only exists while the app holds the audio session, so this has to track
    /// remote play/pause exactly.
    private func syncRemoteKeepAlive() {
        if isRemoteMode, isPlaying {
            remoteKeepAlive.start()
        } else {
            remoteKeepAlive.stop()
        }
        // Covers and playback share the server. Told here rather than inferred, so covers slow
        // down while it is busy and pick up again the moment it isn't.
        MPDArtworkFetcher.shared.setPlaybackActive(isRemoteMode && isPlaying)
    }

    private func startStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollRemoteStatus()
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
            }
        }
    }

    /// Runs the interpolated clock only while the server is actually playing.
    private func syncRemoteClock() {
        let shouldRun = (isRemoteMode || isSpotifyMode) && isPlaying && remoteTimeAnchor != nil
        guard shouldRun else {
            remoteClockTask?.cancel()
            remoteClockTask = nil
            return
        }
        guard remoteClockTask == nil else { return }
        remoteClockTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.remoteClockTickNanoseconds)
                guard !Task.isCancelled else { return }
                self.advanceRemoteClock()
            }
        }
    }

    private func advanceRemoteClock() {
        guard isRemoteMode || isSpotifyMode, isPlaying, let anchor = remoteTimeAnchor else { return }
        let projected = anchor.elapsed + Date().timeIntervalSince(anchor.at)

        // Never run past the end of the track: overshooting would show a nonsense elapsed time
        // and a scrubber pinned past full. Reaching it means the server has almost certainly
        // moved on, so confirm with a poll straight away rather than waiting out the interval.
        if duration > 0, projected >= duration {
            if currentTime != duration { currentTime = duration }
            updateNowPlayingElapsedTime()
            if !hasRequestedEndOfTrackPoll {
                hasRequestedEndOfTrackPoll = true
                // Whichever remote is actually playing. This asked MPD unconditionally, so in
                // Spotify mode a track running out woke nothing at all and the change waited for
                // the ordinary poll — the track, the queue and the artwork all arriving seconds
                // after the music had moved on.
                Task { [weak self] in
                    guard let self else { return }
                    if self.isSpotifyMode {
                        await self.pollSpotifyState()
                        await self.mirrorSpotifyQueue()
                    } else {
                        await self.pollRemoteStatus()
                    }
                }
            }
            return
        }

        if currentTime != projected {
            currentTime = projected
        }
        updateNowPlayingElapsedTime()
    }

    private func pollRemoteStatus() async {
        guard let mpdClient else { return }

        let status: MPDStatus
        do {
            status = try await mpdClient.fetchStatus()
            consecutivePollFailures = 0
        } catch {
            // Previously this was `try?` and simply returned, so a connection that died — most
            // often because iOS suspended the app and tore the socket down — left the remote
            // player permanently unresponsive until the app was restarted.
            consecutivePollFailures += 1
            if consecutivePollFailures >= 2 {
                print("PlaybackManager: MPD status poll failed \(consecutivePollFailures)x — rebuilding the connection")
                // Covers are almost certainly why. They run on their own connection but not on
                // their own server, and a host pulling a multi-megabyte image in twenty-odd
                // round trips has nothing left to answer a poll with. Music stuttering matters
                // more than a cover arriving a second later.
                MPDArtworkFetcher.shared.yieldToPlayback()
                statusPollTask?.cancel()
                statusPollTask = nil
                Task { await mpdClient.disconnect() }
                self.mpdClient = nil
                openRemoteSession()
            }
            return
        }

        // MPD's playlist version increments on every queue change, from any client — the
        // authoritative signal for "the queue we're showing might not match reality anymore."
        // Re-fetching playlistinfo every poll would work too, but this is what every other MPD
        // client does to avoid pulling the full queue over the network 1.25x/second for no
        // reason. `queue`/`currentIndex` are still updated optimistically at the point a
        // command is issued, for immediate UI feedback — this is what corrects that guess to
        // whatever the server actually did with it, on the very next poll.
        if status.playlistVersion != lastKnownPlaylistVersion {
            lastKnownPlaylistVersion = status.playlistVersion
            if let fileURIs = try? await mpdClient.fetchQueue() {
                var resolvedQueue: [Song] = []
                resolvedQueue.reserveCapacity(fileURIs.count)
                for uri in fileURIs {
                    if let song = songResolver(uri) {
                        resolvedQueue.append(song)
                    } else {
                        print("PlaybackManager: MPD queue references \(uri), which isn't in this app's synced library")
                    }
                }
                setQueue(resolvedQueue)
            }
        }

        // Assign only on an actual change. Observation notifies on every *write*, not every
        // change, and this runs 1.25x a second — the mini player and source bar live in each
        // tab's safe-area inset and read this state, so blind rewrites re-laid out the inset
        // on every tick and made the lists judder in remote mode (local mode has no such poll,
        // which is why only remote stuttered).
        let nowPlaying = status.state == "play"
        if isHostSyncingDatabase != status.isUpdatingDatabase {
            isHostSyncingDatabase = status.isUpdatingDatabase
        }
        if isPlaying != nowPlaying {
            isPlaying = nowPlaying
        }
        syncRemoteKeepAlive()
        // Re-anchor to the server's truth on every poll: the interpolated clock is only ever a
        // guess about the gap between polls, and this stops it drifting.
        remoteTimeAnchor = (elapsed: status.elapsed, at: Date())
        hasRequestedEndOfTrackPoll = false
        if currentTime != status.elapsed {
            currentTime = status.elapsed
        }
        syncRemoteClock()
        let resolvedDuration = status.duration > 0 ? status.duration : (currentSong?.duration ?? duration)
        if duration != resolvedDuration {
            duration = resolvedDuration
        }
        remoteServerState = status.state
        if let position = status.songPosition, queue.indices.contains(position) {
            if currentIndex != position { setCurrentIndex(position) }
        } else if currentIndex == nil, !queue.isEmpty {
            // MPD omits `song:` entirely while stopped, which is exactly the state we leave it
            // in when switching away from the network source. Coming back, that left the player
            // view with no current song and every transport control inert — the only way out
            // was to tap a row in the queue. Anchor on the first track instead, so the controls
            // act on something and Play starts the queue.
            setCurrentIndex(0)
        }
        updateNowPlayingInfo()
    }

    // MARK: - Queue control

    func play(songs: [Song], startAt index: Int = 0) {
        setQueue(songs)
        setCurrentIndex(songs.indices.contains(index) ? index : nil)
        if isSpotifyMode {
            let ids = songs.map(\.relativePath)
            // The same head start choosing a track gets: without it, playing an album left the
            // Queue screen showing the previous one until Spotify reported the new context.
            showSpotifyQueue(from: songs, startAt: index)
            isPlaying = true
            remoteTimeAnchor = (elapsed: 0, at: Date())
            syncRemoteClock()
            Task { [weak self] in
                guard let self else { return }
                self.isSpotifyPlayInFlight = true
                // Cleared however this Task ends. A play that throws returns straight out of the
                // catch below, and clearing only on the success path left the flag stuck on —
                // which switches the queue mirror off for the rest of the session, on every
                // device, not just the one that failed.
                defer { self.isSpotifyPlayInFlight = false }

                // Offline: straight to the Spotify app, rather than waiting out Connect's
                // timeouts on the way to the same place.
                if self.isSpotifyOfflineMode {
                    await self.driveLocalSpotify(trackIDs: ids, startAt: index)
                    return
                }
                self.logAudioSessionState("before play")
                do {
                    try await self.spotify.play(trackIDs: ids, startAt: index)
                    self.playbackErrorMessage = nil
                } catch where Self.meansConnectHasNowhereToPlay(error) {
                    // Connect found no device it can drive. Reporting that gave up while a
                    // perfectly good player sat on this very phone.
                    await self.driveLocalSpotify(trackIDs: ids, startAt: index)
                    return
                } catch {
                    self.reportSpotifyFailure(error)
                    return
                }
                // Re-read rather than trusting the optimistic queue set above: Spotify decides
                // what the context becomes, and the two must not be allowed to drift.
                await self.confirmSpotifyState()
                await self.recoverOnLocalSpotifyIfNotPlaying(trackIDs: ids, startAt: index)
            }
            return
        }
        if let firstSong = songs.first, isRemoteSong(firstSong), isRemoteMode {
            let uris = songs.map(\.relativePath)
            performRemoteCommand { client in
                try await client.replaceQueue(uris: uris, startAt: index)
            }
        } else {
            loadCurrentItem(autoplay: true)
        }
    }

    /// Appends a song to the end of the queue and immediately jumps to play it,
    /// mirroring the Android app's tap-to-add-and-play behavior on the Songs list.
    /// What tapping a song in a library list does. If that song is already sitting in the queue,
    /// move to it and play rather than queueing a second copy of it — otherwise repeatedly
    /// tapping around the library silently grew the queue with duplicates.
    func playNow(_ song: Song) {
        if isSpotifyMode {
            playSpotifyFromAlbum(startingAt: song)
            return
        }

        // Matched on the file path as well as identity: in remote mode the queue is mirrored
        // back from the server and re-resolved through the library, so an entry can be a
        // different object for the same track. Missing a match would queue a duplicate.
        if let existing = queue.firstIndex(where: {
            $0.persistentModelID == song.persistentModelID || $0.relativePath == song.relativePath
        }) {
            jumpTo(index: existing)
        } else {
            append(song)
        }
    }

    func append(_ song: Song) {
        setQueue(queue + [song])
        setCurrentIndex(queue.count - 1)
        if route(for: song) == .spotify {
            // Spotify's queue is replaced by the app's, deliberately: the app's queue is the
            // queue, and it is re-sent from the new track onward.
            let ids = queue.map(\.relativePath)
            let startIndex = queue.count - 1
            isPlaying = true
            remoteTimeAnchor = (elapsed: 0, at: Date())
            syncRemoteClock()
            Task { [weak self] in
                guard let self else { return }
                self.isSpotifyPlayInFlight = true
                // Cleared however this Task ends. A play that throws returns straight out of the
                // catch below, and clearing only on the success path left the flag stuck on —
                // which switches the queue mirror off for the rest of the session, on every
                // device, not just the one that failed.
                defer { self.isSpotifyPlayInFlight = false }

                // Offline: straight to the Spotify app, rather than waiting out Connect's
                // timeouts on the way to the same place.
                if self.isSpotifyOfflineMode {
                    await self.driveLocalSpotify(trackIDs: ids, startAt: startIndex)
                    return
                }
                self.logAudioSessionState("before play")
                do {
                    try await self.spotify.play(trackIDs: ids, startAt: startIndex)
                    self.playbackErrorMessage = nil
                } catch where Self.meansConnectHasNowhereToPlay(error) {
                    await self.driveLocalSpotify(trackIDs: ids, startAt: startIndex)
                    return
                } catch {
                    self.reportSpotifyFailure(error)
                    return
                }
                await self.confirmSpotifyState()
                await self.recoverOnLocalSpotifyIfNotPlaying(trackIDs: ids, startAt: startIndex)
            }
            return
        }
        if isRemoteSong(song), isRemoteMode {
            let newIndex = queue.count - 1
            let uri = song.relativePath
            performRemoteCommand { client in
                try await client.addToQueue(uri: uri)
                try await client.playAtQueuePosition(newIndex)
            }
        } else {
            loadCurrentItem(autoplay: true)
        }
    }

    /// Whether a given song belongs to a network (MPD) source and should be routed through
    /// MPD commands rather than AVPlayer. Deliberately derived from the song's own `source`
    /// relationship rather than trusting the separately-tracked `isRemoteMode` flag to always
    /// be perfectly in sync with whatever the UI currently has active — one fewer place for
    /// local/remote routing to silently disagree with the data.
    private func isRemoteSong(_ song: Song) -> Bool {
        song.source?.kind == .network
    }

    func remove(at index: Int) {
        guard queue.indices.contains(index) else { return }
        // Captured before any mutation below — once the queue is emptied or shifted,
        // `currentSong`/`queue.first` no longer reflect what was actually playing.
        let wasRemote = isRemoteSong(queue[index])
        let isRemovingCurrent = index == currentIndex

        var updated = queue
        updated.remove(at: index)
        setQueue(updated)

        if wasRemote {
            performRemoteCommand { try await $0.deleteFromQueue(position: index) }
        }

        guard let currentIndex else { return }
        if index < currentIndex {
            setCurrentIndex(currentIndex - 1)
        } else if isRemovingCurrent {
            if queue.isEmpty {
                setCurrentIndex(nil)
                if wasRemote {
                    isPlaying = false
                    currentTime = 0
                    duration = 0
                    clearNowPlayingInfo()
                } else {
                    stopAndClear()
                }
            } else {
                let newIndex = min(currentIndex, queue.count - 1)
                setCurrentIndex(newIndex)
                if wasRemote {
                    performRemoteCommand { try await $0.playAtQueuePosition(newIndex) }
                } else {
                    loadCurrentItem(autoplay: isPlaying)
                }
            }
        }
    }

    /// Stops playback and empties the queue, on the server too when in remote mode.
    func clearQueue() {
        let wasRemote = isRemoteQueue
        if wasRemote {
            performRemoteCommand { try await $0.clearQueue() }
        }
        if isSpotifyQueue {
            // Connect has no queue of its own to clear — stopping the music is the whole of it.
            print("PlaybackManager: pausing Spotify — queue cleared")
            performSpotifyCommand { try await $0.pause() }
        }
        setQueue([])
        setCurrentIndex(nil)
        stopAndClear()
    }

    func jumpTo(index: Int) {
        guard queue.indices.contains(index) else { return }
        setCurrentIndex(index)
        if isSpotifyQueue {
            let ids = queue.map(\.relativePath)
            isPlaying = true
            remoteTimeAnchor = (elapsed: 0, at: Date())
            syncRemoteClock()
            performSpotifyCommand { try await $0.play(trackIDs: ids, startAt: index) }
            return
        }
        if isRemoteQueue {
            // The server may have been stopped (it is after a source switch); `play <pos>`
            // starts it either way, but the locally-tracked state has to follow.
            remoteServerState = "play"
            performRemoteCommand { try await $0.playAtQueuePosition(index) }
        } else {
            loadCurrentItem(autoplay: true)
        }
    }

    // MARK: - Transport control

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard let index = currentIndex else { return }
        if isSpotifyQueue {
            isPlaying = true
            remoteTimeAnchor = (elapsed: currentTime, at: Date())
            syncRemoteClock()
            performSpotifyCommand { try await $0.resume() }
            updateNowPlayingPlaybackState()
            return
        }
        if isRemoteQueue {
            isPlaying = true
            syncRemoteKeepAlive()
            // Resume from where the server last was, and start ticking now rather than waiting
            // for the next poll to notice.
            remoteTimeAnchor = (elapsed: currentTime, at: Date())
            syncRemoteClock()
            if remoteServerState == "stop" {
                // `pause 0` is a no-op on a stopped server; it only lifts an actual pause.
                remoteServerState = "play"
                performRemoteCommand(reconcile: false) { try await $0.playAtQueuePosition(index) }
            } else {
                performRemoteCommand(reconcile: false) { try await $0.setPause(false) }
            }
        } else {
            // Claimed here rather than at launch: this is the moment the app actually makes
            // sound, and the only moment it is entitled to interrupt anything else playing.
            AudioSessionManager.shared.activate()
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func pause() {
        if isSpotifyQueue {
            print("PlaybackManager: pause() reached in Spotify mode")
            isPlaying = false
            syncRemoteClock()
            performSpotifyCommand { try await $0.pause() }
            updateNowPlayingPlaybackState()
            return
        }
        if isRemoteQueue {
            isPlaying = false
            syncRemoteClock() // stops the local clock straight away
            // Record the pause optimistically: polls are 800ms apart, and until one lands a
            // stale "stop" here would make the next Play restart the track instead of resuming.
            remoteServerState = "pause"
            syncRemoteKeepAlive()
            performRemoteCommand(reconcile: false) { try await $0.setPause(true) }
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlayingPlaybackState()
    }

    func skipToNext() {
        if isSpotifyQueue {
            // No index arithmetic. Spotify decides what comes next — a queued track, the next in
            // the context, something else entirely under shuffle or repeat — so guessing
            // `currentIndex + 1` showed the wrong track until the next poll corrected it. Send
            // the command and read back what actually happened.
            skipSpotify { try await $0.skipToNext() }
            return
        }
        guard let currentIndex else { return }
        if isRemoteQueue {
            // `next` is also a no-op while the server is stopped, so start the neighbouring
            // track explicitly rather than sending a command the server will ignore.
            if remoteServerState == "stop" {
                startRemoteTrack(at: currentIndex + 1)
            } else {
                performRemoteCommand { try await $0.next() }
            }
            return
        }
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            setCurrentIndex(nextIndex)
            loadCurrentItem(autoplay: true)
        } else {
            pause()
        }
    }

    func skipToPrevious() {
        if isSpotifyQueue {
            skipSpotifyBack()
            return
        }
        guard let currentIndex else { return }
        if isRemoteQueue {
            if remoteServerState == "stop" {
                startRemoteTrack(at: currentIndex - 1)
            } else {
                performRemoteCommand { try await $0.previous() }
            }
            return
        }
        let previousIndex = currentIndex - 1
        if queue.indices.contains(previousIndex) {
            setCurrentIndex(previousIndex)
            loadCurrentItem(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    /// Starts a specific queue position on a stopped server. Out-of-range positions are ignored,
    /// matching the local player's behaviour of doing nothing at the ends of the queue.
    private func startRemoteTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        setCurrentIndex(index)
        isPlaying = true
        remoteServerState = "play"
        syncRemoteKeepAlive()
        performRemoteCommand(reconcile: false) { try await $0.playAtQueuePosition(index) }
        updateNowPlayingPlaybackState()
    }

    func seek(to time: TimeInterval) {
        if isSpotifyQueue {
            currentTime = time
            remoteTimeAnchor = (elapsed: time, at: Date())
            hasRequestedEndOfTrackPoll = false
            performSpotifyCommand { try await $0.seek(to: time) }
            updateNowPlayingElapsedTime()
            return
        }
        if isRemoteQueue {
            currentTime = time
            remoteTimeAnchor = (elapsed: time, at: Date())
            hasRequestedEndOfTrackPoll = false
            performRemoteCommand(reconcile: false) { try await $0.seek(seconds: time) }
        } else {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            currentTime = time
        }
        updateNowPlayingElapsedTime()
    }

    // MARK: - Local item loading

    private func loadCurrentItem(autoplay: Bool) {
        releaseCurrentScope()

        guard let song = currentSong else {
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        // Defense in depth: routing is decided by isRemoteSong/isRemoteQueue before this is
        // ever called, but a network song has no bookmarked folder to resolve, and AVPlayer
        // trying to open a nonexistent local path is exactly what produces a bare "fopen
        // failed for data file" error with no useful context — fail loudly and specifically
        // instead, if this is ever reached for one anyway.
        guard !isRemoteSong(song) else {
            print("PlaybackManager: loadCurrentItem called for a network-sourced song (\(song.title)) — refusing to hand it to AVPlayer")
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        guard let source = song.source else {
            print("PlaybackManager: \(song.title) has no source")
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        // Spotify returns metadata, never audio: streaming a track needs Spotify's own playback
        // SDK driving the Spotify app. Browsing an imported Spotify library works; playing from
        // it here cannot, so say so rather than handing AVPlayer something it can't open.
        if source.kind == .spotify {
            print("PlaybackManager: \(song.title) is a Spotify track — playback needs the Spotify app, not AVPlayer")
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        // Music-library tracks aren't files in a folder we hold a grant to — they're addressed
        // by the library's persistent ID and resolved to an asset URL on demand, with no
        // security scope to start or release.
        if source.kind == .mediaLibrary {
            guard let assetURL = mediaLibrary.assetURL(forPersistentID: song.relativePath) else {
                print("PlaybackManager: \(song.title) is no longer in the Music library")
                player.replaceCurrentItem(with: nil)
                duration = 0
                isPlaying = false
                return
            }
            startPlaying(url: assetURL, song: song, autoplay: autoplay)
            return
        }

        guard let root = try? FolderBookmarkStore.resolveURL(for: source) else {
            print("PlaybackManager: could not resolve a bookmarked folder for \(song.title)")
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        // The security scope must be started on the exact URL that came back from bookmark
        // resolution (the folder root) — that's the object the OS actually tracks the grant
        // against — then held for as long as we're reading any file under it.
        guard root.startAccessingSecurityScopedResource() else {
            print("PlaybackManager: startAccessingSecurityScopedResource failed for \(root.path)")
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }
        currentlyScopedURL = root

        let fileURL = root.appendingPathComponent(song.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("PlaybackManager: file missing at \(fileURL.path) — folder contents may have changed since the last sync")
            releaseCurrentScope()
            player.replaceCurrentItem(with: nil)
            duration = 0
            isPlaying = false
            return
        }

        startPlaying(url: fileURL, song: song, autoplay: autoplay)
    }

    /// Hands a resolved URL to AVPlayer. Shared by the folder and Music-library paths, which
    /// differ only in how they arrive at the URL.
    private func startPlaying(url: URL, song: Song, autoplay: Bool) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        duration = song.duration

        statusObservation = item.observe(\.status) { [weak self] observedItem, _ in
            Task { @MainActor in
                switch observedItem.status {
                case .readyToPlay:
                    let seconds = CMTimeGetSeconds(observedItem.duration)
                    if seconds.isFinite && seconds > 0 {
                        self?.duration = seconds
                    }
                case .failed:
                    print("PlaybackManager: AVPlayerItem failed for \(url.lastPathComponent) — \(observedItem.error?.localizedDescription ?? "unknown error")")
                default:
                    break
                }
            }
        }

        updateNowPlayingInfo()

        if autoplay {
            resume()
        } else {
            isPlaying = false
            updateNowPlayingPlaybackState()
        }
    }

    private func stopAndClear() {
        remoteKeepAlive.stop()
        releaseCurrentScope()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        clearNowPlayingInfo()
        // Nothing is being produced any more, so the session goes back. This runs when the
        // active source changes, which is exactly the switch into Spotify mode — holding an
        // exclusive session across that switch would leave the app silently interrupting the
        // Spotify app it is about to start sending commands to.
        AudioSessionManager.shared.deactivate()
    }

    private func releaseCurrentScope() {
        currentlyScopedURL?.stopAccessingSecurityScopedResource()
        currentlyScopedURL = nil
    }
}
