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
    /// Which source is loaded, so a repeated call for the same one can be recognised.
    @ObservationIgnored
    private var activeSourceID: PersistentIdentifier?
    /// Spotify has no queue-version counter the way MPD does, so its queue is re-read on a
    /// slower cadence than the transport state rather than on every tick.
    @ObservationIgnored
    private var spotifyPollsSinceQueueRead = 0
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
        spotifyPollsPerQueueRead: Int = 1
    ) {
        self.spotifyPollsPerQueueRead = max(1, spotifyPollsPerQueueRead)
        self.makeMPDClient = makeMPDClient
        self.remoteKeepAlive = remoteKeepAlive ?? SilentAudioKeepAlive()
        self.mediaLibrary = mediaLibrary ?? SystemMediaLibrary()
        self.makeSpotify = {
            spotify ?? SpotifyPlaybackController(
                session: .shared,
                client: SpotifyWebAPIClient()
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

        AudioSessionManager.shared.onInterruptionBegan = { [weak self] in
            self?.pause()
        }
        AudioSessionManager.shared.onRouteChangedDeviceUnavailable = { [weak self] in
            self?.pause()
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
        playbackErrorMessage = nil
        spotifyQueue = []

        if let source, source.kind == .spotify {
            isSpotifyMode = true
            spotify.configure(clientID: source.spotifyClientID)
            spotify.selectDevice(id: source.spotifyDeviceID)
            startSpotifyPolling()
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
            try? await Task.sleep(nanoseconds: Self.spotifyConfirmSpacingNanoseconds)
            guard isSpotifyMode, !Task.isCancelled else { return }

            if let state = try? await spotify.playerState() {
                await applySpotifyState(state)
                if state.activeDeviceID == id {
                    playbackErrorMessage = nil
                    return
                }
            }
        }
        playbackErrorMessage = "Spotify didn't move playback to that device. It may have gone offline — try Refresh Devices."
    }

    @ObservationIgnored
    private static let spotifyTransferConfirmAttempts = 6

    /// Reports a refused command and undoes the optimistic state that went with it — otherwise
    /// the UI keeps claiming to play something that never started.
    private func reportSpotifyFailure(_ error: Error) {
        playbackErrorMessage = (error as? SpotifyError)?.errorDescription ?? error.localizedDescription
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
        sendSpotifyContext(albumTail(from: song).map(\.relativePath))
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
            do {
                try await self.spotify.play(trackIDs: trackIDs, startAt: 0)
                self.playbackErrorMessage = nil
            } catch {
                self.reportSpotifyFailure(error)
                return
            }
            await self.confirmSpotifyState()
        }
    }

    /// Plays from a given point in Spotify's own queue. Used by the Queue screen, which shows
    /// Spotify's queue rather than the library-backed one, so the entry tapped may be a track
    /// with no row here at all.
    func playSpotifyQueueEntry(at position: Int) {
        guard isSpotifyMode, spotifyQueue.indices.contains(position) else { return }
        // The same rule as tapping a track: what is chosen goes to the top and the rest follows.
        sendSpotifyContext(spotifyQueue[position...].map(\.trackID))
    }

    /// Sends a skip and then reads Spotify's state back promptly, rather than predicting the
    /// result. Without the read-back the app would sit on a stale track for a whole poll
    /// interval; without dropping the prediction it would show a wrong one.
    private func skipSpotify(_ body: @escaping (SpotifyPlaybackControlling) async throws -> Void) {
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
        for attempt in 0..<attempts {
            try? await Task.sleep(nanoseconds: Self.spotifyConfirmSpacingNanoseconds)
            guard isSpotifyMode, !Task.isCancelled else { return }
            await pollSpotifyState()
            // The queue moves with the track, so bring it along on the last read.
            if attempt == attempts - 1 {
                await mirrorSpotifyQueue()
            }
        }
    }

    @ObservationIgnored
    private static let spotifyConfirmSpacingNanoseconds: UInt64 = 500_000_000

    /// Runs a Spotify Connect command, reporting a refusal rather than leaving a button that
    /// silently does nothing. "No active device" is the common one and is not a fault: Spotify
    /// only accepts commands when one of its clients is running.
    private func performSpotifyCommand(_ body: @escaping (SpotifyPlaybackControlling) async throws -> Void) {
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
        guard isSpotifyMode else { return }
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
        if isPlaying != state.isPlaying { isPlaying = state.isPlaying }
        remoteTimeAnchor = (elapsed: state.progressSeconds, at: Date())
        hasRequestedEndOfTrackPoll = false
        if currentTime != state.progressSeconds { currentTime = state.progressSeconds }

        let resolvedDuration = state.durationSeconds > 0 ? state.durationSeconds : (currentSong?.duration ?? duration)
        if duration != resolvedDuration { duration = resolvedDuration }

        // Follow the track Spotify says is playing, so skipping from the Spotify app moves the
        // highlight here too.
        if let trackID = state.trackID,
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
        guard isSpotifyMode, let snapshot = try? await spotify.playbackQueue() else { return }

        // Kept whole, whether or not the tracks are in the library — this is what the Queue
        // screen shows, and a queue missing the rows Spotify actually has lined up is worse
        // than useless for following along.
        //
        // An empty read is only believed when Spotify also reports nothing playing. Right after
        // a context change it briefly returns nothing while it settles, and taking that at face
        // value emptied the queue and made it look as though playback had stopped.
        let isTransientlyEmpty = snapshot.entries.isEmpty && (snapshot.currentTrackID != nil || isPlaying)
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

        // Assigned unconditionally, including when it comes back empty. Bailing out on an empty
        // result left a stale queue on screen after Spotify's had been emptied or replaced.
        let mirroredIDs = mirrored.map(\.relativePath)
        if queue.map(\.relativePath) != mirroredIDs {
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
                Task { [weak self] in await self?.pollRemoteStatus() }
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
            isPlaying = true
            remoteTimeAnchor = (elapsed: 0, at: Date())
            syncRemoteClock()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.spotify.play(trackIDs: ids, startAt: index)
                    self.playbackErrorMessage = nil
                } catch {
                    self.reportSpotifyFailure(error)
                    return
                }
                // Re-read rather than trusting the optimistic queue set above: Spotify decides
                // what the context becomes, and the two must not be allowed to drift.
                await self.confirmSpotifyState()
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
            // Spotify has no editable queue to append to over Connect, so the app's queue is
            // the queue: it is re-sent from the new track onward.
            let ids = queue.map(\.relativePath)
            let startIndex = queue.count - 1
            isPlaying = true
            remoteTimeAnchor = (elapsed: 0, at: Date())
            syncRemoteClock()
            performSpotifyCommand { try await $0.play(trackIDs: ids, startAt: startIndex) }
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
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func pause() {
        if isSpotifyQueue {
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
            failToLoad(song, reason: "\(song.title) belongs to a server, not this device.")
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
                // The import only takes tracks with a local, unprotected asset, so reaching here
                // means one has gone since — removed from the Music app, or its download
                // evicted. Said out loud rather than logged: a track that does nothing when
                // tapped, with no explanation, is indistinguishable from the app being broken.
                failToLoad(song, reason: "\(song.title) isn't on this device any more. Re-download it in the Music app, then sync this source again.")
                return
            }
            startPlaying(url: assetURL, song: song, autoplay: autoplay)
            return
        }

        guard let root = try? FolderBookmarkStore.resolveURL(for: source) else {
            failToLoad(song, reason: "Can't reach the music folder any more. Choose it again in Sources.")
            return
        }

        // The security scope must be started on the exact URL that came back from bookmark
        // resolution (the folder root) — that's the object the OS actually tracks the grant
        // against — then held for as long as we're reading any file under it.
        guard root.startAccessingSecurityScopedResource() else {
            failToLoad(song, reason: "Permission to read the music folder was lost. Choose it again in Sources.")
            return
        }
        currentlyScopedURL = root

        let fileURL = root.appendingPathComponent(song.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            releaseCurrentScope()
            failToLoad(song, reason: "\(song.title) is no longer in the music folder. Rescan the source in Sources.")
            return
        }

        startPlaying(url: fileURL, song: song, autoplay: autoplay)
    }

    /// Gives up on a track and says why, rather than leaving a tap that appears to do nothing.
    private func failToLoad(_ song: Song, reason: String) {
        print("PlaybackManager: can't play \(song.title) — \(reason)")
        playbackErrorMessage = reason
        player.replaceCurrentItem(with: nil)
        duration = 0
        isPlaying = false
        updateNowPlayingPlaybackState()
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
                    // The asset existed but wouldn't open — an unsupported encoding, or a file
                    // that turned out to be unreadable. Reported for the same reason.
                    let detail = observedItem.error?.localizedDescription ?? "it couldn't be opened"
                    print("PlaybackManager: AVPlayerItem failed for \(url.lastPathComponent) — \(detail)")
                    self?.playbackErrorMessage = "Couldn't play \(song.title): \(detail)"
                    self?.isPlaying = false
                default:
                    break
                }
            }
        }

        updateNowPlayingInfo()
        playbackErrorMessage = nil

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
    }

    private func releaseCurrentScope() {
        currentlyScopedURL?.stopAccessingSecurityScopedResource()
        currentlyScopedURL = nil
    }
}
