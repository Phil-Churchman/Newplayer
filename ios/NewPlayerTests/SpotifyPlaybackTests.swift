import XCTest
@testable import NewPlayer

/// Spotify is a third playback route beside the local player and MPD. These check the commands
/// actually leave by that route, that the other two are unaffected, and that a refusal is
/// reported rather than leaving a button that quietly does nothing.
@MainActor
final class SpotifyPlaybackTests: XCTestCase {
    private func spotifySource() -> Source {
        let source = Source(name: "Spotify", isActive: true, kind: .spotify)
        source.spotifyClientID = "client-123"
        return source
    }

    private func song(_ id: String, source: Source) -> Song {
        Song(title: id, artist: "A", albumTitle: "Al", albumArtist: "A",
             track: 1, duration: 200, relativePath: id, source: source)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testSelectingASpotifySourceConfiguresTheController() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        XCTAssertEqual(remote.configuredClientID, "client-123")
    }

    func testPlayingAnAlbumSendsTheTracksAndTheStartingPosition() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 1)
        await settle()

        XCTAssertEqual(remote.playRequests.first?.ids, ["t1", "t2"])
        XCTAssertEqual(remote.playRequests.first?.index, 1)
        XCTAssertTrue(manager.isPlaying)
    }

    func testTransportCommandsGoToSpotify() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 0)
        await settle()

        manager.pause()
        await settle()
        XCTAssertFalse(manager.isPlaying)

        manager.resume()
        await settle()
        XCTAssertTrue(manager.isPlaying)

        manager.skipToNext()
        await settle()
        manager.seek(to: 30)
        await settle()

        XCTAssertEqual(remote.commands, ["play", "pause", "resume", "next", "seek"])
    }

    /// The reason this exists: Spotify only accepts commands while one of its clients is
    /// running, and a silent no-op looks exactly like a broken button.
    func testNoActiveDeviceIsReportedRatherThanIgnored() async throws {
        let remote = FakeSpotifyPlayback()
        remote.errorToThrow = SpotifyError.noActiveDevice
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        // Asserted on substance rather than exact wording, which has already changed once.
        let message = try XCTUnwrap(manager.playbackErrorMessage)
        XCTAssertTrue(message.contains("Spotify"), "the message should say what refused: \(message)")
        XCTAssertTrue(message.contains("try again"), "and what to do about it: \(message)")
        XCTAssertFalse(manager.isPlaying, "nothing is playing, so the UI must not claim otherwise")
    }

    /// Following the active client: skipping in the Spotify app moves the highlight here.
    func testThePollFollowsTheTrackSpotifyReportsPlaying() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 12, durationSeconds: 200, trackID: "t2"
        )
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 0)

        let deadline = Date().addingTimeInterval(5)
        while manager.currentIndex != 1 && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(manager.currentIndex, 1, "the app should follow what Spotify is playing")
        XCTAssertEqual(manager.duration, 200)
    }

    /// Leaving the source stops the music, as switching away from MPD does.
    func testLeavingTheSpotifySourcePausesIt() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        manager.setActiveSource(nil)
        await settle()

        XCTAssertTrue(remote.commands.contains("pause"))
        XCTAssertTrue(manager.queue.isEmpty)
    }

    /// Routing is per song, so an MPD queue must not be diverted to Spotify.
    func testAnMPDQueueStillGoesToMPD() async {
        let remote = FakeSpotifyPlayback()
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock }, spotify: remote)
        let network = Source(name: "Network", host: "127.0.0.1", port: 6600, isActive: true, kind: .network)
        manager.setActiveSource(network)
        await settle()

        manager.play(songs: [song("a.flac", source: network)], startAt: 0)
        await settle()

        XCTAssertTrue(remote.commands.isEmpty, "an MPD song must not be sent to Spotify")
        let calls = await mock.calls
        XCTAssertTrue(calls.contains { if case .replaceQueue = $0 { return true } else { return false } })
    }

    /// A long queue is sent as a window: Spotify caps the URIs one request may carry.
    func testALongQueueIsSentAsAWindowStartingAtTheChosenTrack() {
        let ids = (0..<250).map { "t\($0)" }
        let window = SpotifyPlaybackController.window(of: ids, around: 200)

        XCTAssertEqual(window.ids.first, "t200")
        XCTAssertLessThanOrEqual(window.ids.count, 100)
        XCTAssertEqual(window.offset, 0)
    }

    func testAShortQueueIsSentWholeWithTheChosenOffset() {
        let ids = ["a", "b", "c"]
        let window = SpotifyPlaybackController.window(of: ids, around: 2)

        XCTAssertEqual(window.ids, ids)
        XCTAssertEqual(window.offset, 2)
    }

    // MARK: - Changing device

    /// A Connect transfer moves the session — track, position and all — to the new device, so
    /// there is nothing to stop and nothing to rebuild. The queue stays.
    func testChangingDeviceKeepsTheQueueAndTheTrack() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 1)
        await settle()

        manager.selectSpotifyDevice(id: "speaker")
        await settle()

        XCTAssertEqual(manager.queue.count, 2, "the queue is the app's, not the device's")
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertFalse(remote.commands.contains("pause"), "nothing needs stopping: \(remote.events)")
    }

    /// Music that was playing carries on at the new device.
    func testPlayingMusicContinuesOnTheNewDevice() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()
        XCTAssertTrue(manager.isPlaying)

        manager.selectSpotifyDevice(id: "speaker")
        await settle()

        XCTAssertTrue(remote.commands.contains("takeOver:speaker:true"), "got \(remote.events)")
    }

    /// A paused session transfers paused, rather than starting itself up elsewhere.
    func testAPausedSessionTransfersWithoutStartingPlayback() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()
        manager.pause()
        await settle()

        manager.selectSpotifyDevice(id: "speaker")
        await settle()

        XCTAssertTrue(remote.commands.contains("takeOver:speaker:false"), "got \(remote.events)")
    }

    /// Returning to automatic has no particular device to claim.
    func testReturningToAutomaticTakesOverNothing() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        manager.selectSpotifyDevice(id: nil)
        await settle()

        XCTAssertNil(remote.selectedDeviceID)
        XCTAssertFalse(remote.commands.contains { $0.hasPrefix("takeOver") })
    }

    /// A device that refuses to be claimed should say so rather than silently doing nothing.
    func testAFailedTakeOverIsReported() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        remote.errorToThrow = SpotifyError.onlyRestrictedDevices
        manager.selectSpotifyDevice(id: "locked")
        await settle()

        XCTAssertNotNil(manager.playbackErrorMessage)
    }

    /// Leaving the source stops the device even when this app doesn't think it is playing —
    /// playback may have been started from Spotify itself.
    func testLeavingTheSourceStopsTheDeviceEvenIfTheAppThinksItIsPaused() async {
        let remote = FakeSpotifyPlayback()
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()
        remote.resetCommands()

        manager.setActiveSource(nil)
        await settle()

        XCTAssertTrue(remote.commands.contains("pause"), "got \(remote.commands)")
        XCTAssertTrue(manager.queue.isEmpty)
    }

    // MARK: - Mirroring Spotify's own queue

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A track queued from the Spotify app should turn up in this app's queue.
    func testATrackQueuedInSpotifyAppearsInTheQueue() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: true, progressSeconds: 0, durationSeconds: 200, trackID: "t1")
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0), SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 1), SpotifyQueueEntry(trackID: "t3", title: "t3", artist: "A", artworkURL: nil, position: 2)])

        let source = spotifySource()
        let songs = ["t1", "t2", "t3"].map { song($0, source: source) }
        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })

        await waitUntil { manager.queue.count == 3 }

        XCTAssertEqual(manager.queue.map(\.relativePath), ["t1", "t2", "t3"])
        XCTAssertEqual(manager.currentIndex, 0, "Spotify's queue begins with what is playing")
    }

    /// The mirror follows Spotify as its queue changes.
    func testTheQueueFollowsChangesMadeInSpotify() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: true, progressSeconds: 0, durationSeconds: 200, trackID: "t1")
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0), SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 1)])

        let source = spotifySource()
        let songs = ["t1", "t2", "t3"].map { song($0, source: source) }
        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })
        await waitUntil { manager.queue.count == 2 }

        // Someone adds a track in the Spotify app.
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0), SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 1), SpotifyQueueEntry(trackID: "t3", title: "t3", artist: "A", artworkURL: nil, position: 2)])
        await waitUntil(timeout: 10) { manager.queue.count == 3 }

        XCTAssertEqual(manager.queue.map(\.relativePath), ["t1", "t2", "t3"])
    }

    /// Tracks Spotify has queued that were never imported can't be shown as rows — the queue is
    /// made of the same library songs the rest of the app browses — so they're skipped, not faked.
    func testTracksMissingFromTheLibraryAreSkippedRatherThanFaked() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: true, progressSeconds: 0, durationSeconds: 200, trackID: "t1")
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0), SpotifyQueueEntry(trackID: "unknown", title: "unknown", artist: "A", artworkURL: nil, position: 1), SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 2)])

        let source = spotifySource()
        let songs = ["t1", "t2"].map { song($0, source: source) }
        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })

        await waitUntil { manager.queue.count == 2 }
        XCTAssertEqual(manager.queue.map(\.relativePath), ["t1", "t2"])
    }

    /// The queue is now read on every poll. It was read less often to save requests, but the
    /// app's copy drifting from Spotify's is the thing users actually notice, and the transport
    /// poll is already slow (5s playing, 15s idle) — so keeping the two in step wins.
    func testTheQueueIsReadOnEveryPoll() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: true, progressSeconds: 0, durationSeconds: 200, trackID: "t1")
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0)])

        let source = spotifySource()
        let songs = [song("t1", source: source)]
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })

        await waitUntil(timeout: 15) { remote.events.contains("queue") }
        let queueReads = remote.events.filter { $0 == "queue" }.count
        let stateReads = remote.events.filter { $0 == "state" }.count
        XCTAssertGreaterThan(queueReads, 0)
        XCTAssertEqual(queueReads, stateReads, "the queue should be read alongside the state, not behind it")
    }

    // MARK: - Staying within Spotify's request limits

    /// The poll was left running when the app went to the background — every couple of seconds,
    /// indefinitely — which wastes battery and walks the account into a 429.
    func testBackgroundingStopsThePoll() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: false, progressSeconds: 0, durationSeconds: 0, trackID: nil)
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        manager.suspendRemotePolling()
        remote.resetCommands()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(remote.events.contains("state"), "no polling once backgrounded: \(remote.events)")
    }

    /// And it starts again on returning.
    func testForegroundingResumesThePoll() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(isPlaying: false, progressSeconds: 0, durationSeconds: 0, trackID: nil)
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()
        manager.suspendRemotePolling()
        remote.resetCommands()

        manager.resumeRemoteSession()

        let deadline = Date().addingTimeInterval(5)
        while !remote.events.contains("state") && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(remote.events.contains("state"))
    }

    /// A rate-limited response must say what it is and when to come back, not "HTTP 429".
    func testTheRateLimitMessageSaysWhenToTryAgain() {
        let message = SpotifyError.rateLimited(retryAfterSeconds: 45).errorDescription ?? ""
        XCTAssertTrue(message.contains("45 seconds"), "got: \(message)")
        XCTAssertTrue(message.lowercased().contains("limiting"))

        let vague = SpotifyError.rateLimited(retryAfterSeconds: nil).errorDescription ?? ""
        XCTAssertTrue(vague.lowercased().contains("wait"), "got: \(vague)")
    }

    // MARK: - Skipping, when Spotify decides what comes next

    /// The reported problem. Spotify chooses the next track — a queued one, the next in context,
    /// something else under shuffle — so predicting `currentIndex + 1` showed the wrong track
    /// until a poll corrected it. The app now follows what Spotify actually did.
    func testSkipFollowsWhatSpotifyActuallyPlayed() async {
        let remote = FakeSpotifyPlayback()
        let source = spotifySource()
        let songs = ["t1", "t2", "t3"].map { song($0, source: source) }

        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 10, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [SpotifyQueueEntry(trackID: "t1", title: "t1", artist: "A", artworkURL: nil, position: 0), SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 1), SpotifyQueueEntry(trackID: "t3", title: "t3", artist: "A", artworkURL: nil, position: 2)])
        // Spotify jumps to the third track, not the neighbouring one.
        remote.trackAfterNextSkip = "t3"

        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })
        await waitUntil { manager.currentSong?.relativePath == "t1" }

        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t3", entries: [SpotifyQueueEntry(trackID: "t3", title: "t3", artist: "A", artworkURL: nil, position: 0)])
        manager.skipToNext()

        await waitUntil { manager.currentSong?.relativePath == "t3" }
        XCTAssertEqual(manager.currentSong?.relativePath, "t3", "the app must follow Spotify, not guess")
    }

    /// Spotify's "previous" restarts the current track when it is a few seconds in, rather than
    /// stepping back — so stepping the index back was usually wrong.
    func testPreviousDoesNotAssumeItStepsBack() async {
        let remote = FakeSpotifyPlayback()
        let source = spotifySource()
        let songs = ["t1", "t2"].map { song($0, source: source) }

        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 30, durationSeconds: 200,
            trackID: "t2", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t2", entries: [SpotifyQueueEntry(trackID: "t2", title: "t2", artist: "A", artworkURL: nil, position: 0)])
        remote.trackAfterPreviousSkip = "t2" // restarts, doesn't step back

        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })
        await waitUntil { manager.currentSong?.relativePath == "t2" }

        manager.skipToPrevious()
        await waitUntil(timeout: 6) { remote.commands.contains("previous") }
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertEqual(manager.currentSong?.relativePath, "t2", "it should still be on the track Spotify reports")
    }

    /// A skip must work even before the queue mirror has resolved an index — the old code
    /// returned early with no current index and did nothing at all.
    func testSkipWorksBeforeTheQueueHasBeenMirrored() async {
        let remote = FakeSpotifyPlayback()
        let source = spotifySource()
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()
        remote.resetCommands()

        manager.skipToNext()
        await waitUntil(timeout: 6) { remote.commands.contains("next") }

        XCTAssertTrue(remote.commands.contains("next"))
    }

    // MARK: - Confirming a device transfer

    /// Spotify answers a transfer before the device has picked it up, and a device can decline
    /// quietly — so the switch is verified rather than assumed.
    func testATransferThatDoesNotTakeIsReported() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "phone"
        )
        remote.transferSilentlyFails = true

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        manager.selectSpotifyDevice(id: "speaker")
        await waitUntil(timeout: 10) { manager.playbackErrorMessage != nil }

        XCTAssertTrue(manager.playbackErrorMessage?.contains("didn't move") == true,
                      "got: \(manager.playbackErrorMessage ?? "nil")")
    }

    /// A transfer that does take leaves no error behind.
    func testASuccessfulTransferReportsNothing() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "phone"
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        manager.selectSpotifyDevice(id: "speaker")
        await waitUntil(timeout: 10) { remote.commands.contains("takeOver:speaker:false") }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertNil(manager.playbackErrorMessage)
    }

    // MARK: - Showing Spotify's real queue

    private func entry(_ id: String, position: Int, title: String? = nil) -> SpotifyQueueEntry {
        SpotifyQueueEntry(
            trackID: id, title: title ?? id, artist: "A",
            artworkURL: "https://i.scdn.co/image/\(id)", position: position
        )
    }

    /// The old mirror dropped anything not in the library, so the app showed a subset of the
    /// real queue — and nothing lined up with what Spotify was actually going to play.
    func testTheQueueIncludesTracksThatWereNeverImported() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [entry("t1", position: 0), entry("never-imported", position: 1, title: "Found in Search")]
        )

        let source = spotifySource()
        let songs = [song("t1", source: source)] // only the first is in the library
        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { id in songs.first { $0.relativePath == id } })

        await waitUntil { manager.spotifyQueue.count == 2 }

        XCTAssertEqual(manager.spotifyQueue.map(\.title), ["t1", "Found in Search"])
        XCTAssertEqual(manager.spotifyCurrentEntry?.trackID, "t1")
    }

    /// Playing from a point in Spotify's queue works even for a track with no library row.
    func testPlayingFromAQueueEntryWithNoLibraryRow() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [entry("t1", position: 0), entry("unknown", position: 1)]
        )

        let source = spotifySource()
        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(source, resolveSong: { _ in nil })
        await waitUntil { manager.spotifyQueue.count == 2 }

        manager.playSpotifyQueueEntry(at: 1)
        await waitUntil(timeout: 6) { remote.playRequests.contains { $0.ids.first == "unknown" } }

        XCTAssertEqual(remote.playRequests.last?.ids, ["unknown"])
    }

    /// Routing must not fall back to the local player just because no queue entry resolved.
    func testTransportStillRoutesToSpotifyWhenNothingResolved() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "unknown", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "unknown", entries: [entry("unknown", position: 0)]
        )

        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { manager.spotifyQueue.count == 1 }
        remote.resetCommands()

        manager.pause()
        await waitUntil(timeout: 6) { remote.commands.contains("pause") }

        XCTAssertTrue(remote.commands.contains("pause"), "an empty library queue must not route locally")
    }

    /// Leaving the source clears it, so a stale queue can't linger into another mode.
    func testLeavingSpotifyClearsItsQueue() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1", entries: [entry("t1", position: 0)]
        )

        let manager = PlaybackManager(spotify: remote, spotifyPollsPerQueueRead: 1)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { !manager.spotifyQueue.isEmpty }

        manager.setActiveSource(nil)
        await settle()

        XCTAssertTrue(manager.spotifyQueue.isEmpty)
    }

    // MARK: - Keeping the two queues the same

    /// Spotify mode plays the way Spotify does: choosing a track replaces what is queued with
    /// that track and the rest of its album. Inserting into Spotify's queue — which this used to
    /// do — left the tapped track waiting behind whatever was already lined up, which is not
    /// what tapping a track looks like it should do.
    func testTappingATrackPlaysItAndTheRestOfItsAlbum() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "a1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "a1", entries: [entry("a1", position: 0)])

        let source = spotifySource()
        let album = Album(name: "Record", source: source)
        let tracks = (1...4).map { number -> Song in
            let track = Song(
                title: "a\(number)", artist: "A", albumTitle: "Record", albumArtist: "A",
                track: number, duration: 200, relativePath: "a\(number)",
                album: album, source: source
            )
            album.songs.append(track)
            return track
        }

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(source, resolveSong: { id in tracks.first { $0.relativePath == id } })
        await settle()

        manager.playNow(tracks[1]) // the second track
        await waitUntil(timeout: 6) { !remote.playRequests.isEmpty }

        XCTAssertEqual(
            remote.playRequests.last?.ids, ["a2", "a3", "a4"],
            "the chosen track goes to the top and the rest of the album follows"
        )
        XCTAssertEqual(remote.playRequests.last?.index, 0)
    }

    /// A track belonging to no album this app knows about simply plays on its own.
    func testTappingATrackWithNoAlbumPlaysJustThatTrack() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "phone"
        )

        let source = spotifySource()
        let loose = song("loose", source: source)
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(source)
        await settle()

        manager.playNow(loose)
        await waitUntil(timeout: 6) { !remote.playRequests.isEmpty }

        XCTAssertEqual(remote.playRequests.last?.ids, ["loose"])
    }

    /// Choosing a track from the queue does the same thing: it goes to the top, the rest follows.
    func testChoosingFromTheQueuePlaysFromThatPointOn() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [entry("t1", position: 0), entry("t2", position: 1), entry("t3", position: 2)]
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { manager.spotifyQueue.count == 3 }

        manager.playSpotifyQueueEntry(at: 1)
        await waitUntil(timeout: 6) { !remote.playRequests.isEmpty }

        XCTAssertEqual(remote.playRequests.last?.ids, ["t2", "t3"])
    }

    /// Playing an album replaces Spotify's context, then re-reads so both agree immediately.
    func testPlayingAnAlbumReplacesAndThenResyncs() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "a1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "a1", entries: [entry("a1", position: 0), entry("a2", position: 1)]
        )

        let source = spotifySource()
        let album = ["a1", "a2"].map { song($0, source: source) }
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(source, resolveSong: { id in album.first { $0.relativePath == id } })
        await settle()

        manager.play(songs: album, startAt: 0)
        await waitUntil(timeout: 6) { !remote.playRequests.isEmpty }

        XCTAssertEqual(remote.playRequests.last?.ids, ["a1", "a2"])
        await waitUntil(timeout: 6) { manager.spotifyQueue.count == 2 }
        XCTAssertEqual(manager.spotifyQueue.map(\.trackID), ["a1", "a2"], "the two should agree after the action")
    }

    // MARK: - Not believing a momentary empty read

    /// The reported bug: tapping a queue item emptied the queue and looked as though playback
    /// had stopped. Right after a context change Spotify briefly returns an empty queue while it
    /// settles, and taking that at face value wiped the mirror.
    func testAMomentaryEmptyReadDoesNotWipeTheQueue() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [entry("t1", position: 0), entry("t2", position: 1)]
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { manager.spotifyQueue.count == 2 }

        // Still playing, but the queue read comes back empty for a moment.
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: "t1", entries: [])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(manager.spotifyQueue.count, 2, "a settling read must not empty the queue")
    }

    /// It is believed once Spotify agrees there is nothing playing.
    func testAGenuinelyEmptyQueueIsBelieved() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1", entries: [entry("t1", position: 0)]
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { !manager.spotifyQueue.isEmpty }

        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: nil, entries: [])

        await waitUntil(timeout: 15) { manager.spotifyQueue.isEmpty }
        XCTAssertTrue(manager.spotifyQueue.isEmpty)
    }

    /// The Queue screen follows the source, not the emptiness of a list — otherwise a momentary
    /// gap dropped it to the library-backed queue, which holds nothing in this mode.
    func testTheQueueScreenStaysOnSpotifyWhileTheSourceIsSpotify() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: nil
        )
        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource())
        await settle()

        XCTAssertTrue(manager.isSpotifySource)
    }

    // MARK: - Back at the start of a queue

    /// The reported bug: pressing back on the first queued track produced "Spotify refused this
    /// sign-in permission". Spotify answers 403 when an action isn't allowed in the current
    /// state, which was being read as a token problem. There is nothing before the first track,
    /// so back should restart it.
    func testBackOnTheFirstTrackRestartsItRatherThanErroring() async {
        let remote = FakeSpotifyPlayback()
        remote.previousIsRefused = true
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 30, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1", entries: [entry("t1", position: 0)]
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { !manager.spotifyQueue.isEmpty }
        remote.resetCommands()

        manager.skipToPrevious()
        await waitUntil(timeout: 6) { remote.commands.contains("seek") }

        XCTAssertTrue(remote.commands.contains("previous"), "it should still ask Spotify first")
        XCTAssertTrue(remote.commands.contains("seek"), "then restart the track when refused")
        XCTAssertNil(manager.playbackErrorMessage, "a refused back-skip is not an error to report")
    }

    /// A refusal that isn't about permissions must not tell the user to sign in again.
    func testARefusedActionIsNotReportedAsASignInProblem() {
        let message = SpotifyError.actionNotAllowed("Cannot skip to previous track").errorDescription ?? ""
        XCTAssertEqual(message, "Cannot skip to previous track")
        XCTAssertFalse(message.lowercased().contains("sign in"))
    }

    /// Back still works normally when Spotify allows it.
    func testBackStillSkipsWhenAllowed() async {
        let remote = FakeSpotifyPlayback()
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 1, durationSeconds: 200,
            trackID: "t2", activeDeviceID: "phone"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t2", entries: [entry("t2", position: 0)]
        )

        let manager = PlaybackManager(spotify: remote)
        manager.setActiveSource(spotifySource(), resolveSong: { _ in nil })
        await waitUntil { !manager.spotifyQueue.isEmpty }
        remote.resetCommands()

        manager.skipToPrevious()
        await waitUntil(timeout: 6) { remote.commands.contains("previous") }

        XCTAssertFalse(remote.commands.contains("seek"), "no need to restart when the skip worked")
    }

    // MARK: - What gets sent as a Spotify URI

    /// Spotify refuses a malformed URI with a message about links, which names no track and
    /// reads as though this app produced it. Catching it here says which album is at fault.
    func testARealSpotifyIDIsAccepted() {
        XCTAssertTrue(SpotifyPlaybackController.isPlausibleTrackURI("spotify:track:4iV5W9uYEdYUVa79Axb7Rh"))
    }

    func testAFilePathIsNotASpotifyID() {
        XCTAssertFalse(SpotifyPlaybackController.isPlausibleTrackURI("spotify:track:music/track-1.flac"))
    }

    func testAMusicLibraryPersistentIDIsNotASpotifyID() {
        XCTAssertFalse(SpotifyPlaybackController.isPlausibleTrackURI("spotify:track:998877665544332211"))
    }

    func testAnEmptyIDIsRejected() {
        XCTAssertFalse(SpotifyPlaybackController.isPlausibleTrackURI("spotify:track:"))
    }

    /// Spotify's own wording is relayed, but attributed — unattributed it reads as this app's.
    func testSpotifysWordingIsAttributedToSpotify() {
        let message = SpotifyError.actionNotAllowed("Impossible to open link").errorDescription
        XCTAssertEqual(message, "Spotify: Impossible to open link")
    }
}
