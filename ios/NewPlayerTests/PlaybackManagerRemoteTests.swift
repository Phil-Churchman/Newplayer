import XCTest
@testable import NewPlayer

@MainActor
final class PlaybackManagerRemoteTests: XCTestCase {
    private func makeSong(_ title: String, path: String, source: Source) -> Song {
        Song(title: title, artist: "Artist", albumTitle: "Album", albumArtist: "Artist", track: 1, duration: 100, relativePath: path, source: source)
    }

    private func makeNetworkSource() -> Source {
        Source(name: "Network", host: "127.0.0.1", port: 6600, isActive: true, kind: .network)
    }

    /// Waits a few run-loop turns for fire-and-forget Tasks spawned by PlaybackManager to
    /// reach the mock actor, since those calls are dispatched asynchronously rather than
    /// awaited directly by the methods under test.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    func testSetActiveSourceConnectsToMPDForNetworkSource() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()

        manager.setActiveSource(source)
        await settle()

        let calls = await mock.calls
        XCTAssertEqual(calls, [.connect(host: "127.0.0.1", port: 6600)])
    }

    func testSetActiveSourceDoesNotConnectForLocalSource() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let localSource = Source(name: "Local", kind: .local)

        manager.setActiveSource(localSource)
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPlaySendsReplaceQueueCommand() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()

        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ]
        manager.play(songs: songs, startAt: 1)
        await settle()

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(manager.currentIndex, 1)

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.replaceQueue(uris: ["a.flac", "b.flac"], startAt: 1)))
    }

    func testAppendSendsAddAndPlayAtPosition() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()

        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        manager.append(makeSong("B", path: "b.flac", source: source))
        await settle()

        XCTAssertEqual(manager.currentIndex, 1)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.addToQueue(uri: "b.flac")))
        XCTAssertTrue(calls.contains(.playAtQueuePosition(1)))
    }

    func testTogglePlayPauseSendsSetPause() async {
        let mock = MockMPDClient()
        // A *playing* server: pause/resume is `pause 1`/`pause 0` only against one of those.
        // (The default fixture reports "stop", which is a different case entirely — see
        // testPlayOnAStoppedServerStartsTheTrackRatherThanUnpausing.)
        await mock.setStatus(MPDStatus(state: "play", elapsed: 1, duration: 100, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        manager.pause()
        await settle()
        XCTAssertFalse(manager.isPlaying)

        manager.resume()
        await settle()
        XCTAssertTrue(manager.isPlaying)

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setPause(true)))
        XCTAssertTrue(calls.contains(.setPause(false)))
    }

    func testJumpToSendsPlayAtQueuePosition() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
            makeSong("C", path: "c.flac", source: source),
        ], startAt: 0)
        await settle()

        manager.jumpTo(index: 2)
        await settle()

        XCTAssertEqual(manager.currentIndex, 2)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.playAtQueuePosition(2)))
    }

    func testRemoveSendsDeleteFromQueue() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ], startAt: 0)
        await settle()

        manager.remove(at: 1)
        await settle()

        XCTAssertEqual(manager.queue.map(\.title), ["A"])
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.deleteFromQueue(position: 1)))
    }

    /// Regression test for a "fopen failed for data file" crash reported when playing a
    /// remote song: routing must be decided from the song's own `source.kind`, not from a
    /// separately-tracked mode flag that could in principle fall out of sync with what's
    /// actually active. This calls `play` on a network-sourced song directly — deliberately
    /// without going through `setActiveSource` first, since a desync between "what the flag
    /// says" and "what the song actually is" is exactly the class of bug this guards against.
    func testPlayRoutesToMPDBasedOnSongSourceEvenWithoutSetActiveSource() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let networkSource = makeNetworkSource()

        // Give the manager a connected MPD client the same way setActiveSource would, but
        // skip actually calling it — simulating the flag/data staying out of sync.
        manager.setActiveSource(networkSource)
        await settle()

        let song = makeSong("Remote Song", path: "remote.flac", source: networkSource)
        manager.play(songs: [song])
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.replaceQueue(uris: ["remote.flac"], startAt: 0)))
        // The critical assertion: AVPlayer must never have been handed this song.
        XCTAssertNil(manager.player.currentItem)
    }

    func testLoadCurrentItemRefusesNetworkSongsEvenIfReached() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let localSource = Source(name: "Local", kind: .local)
        manager.setActiveSource(localSource)
        await settle()

        // A network-sourced Song ending up in an otherwise-local queue shouldn't be possible
        // through normal UI flows (queues are always single-source), but this proves the
        // defensive guard in loadCurrentItem holds even if it happened.
        let networkSource = makeNetworkSource()
        let strandedSong = makeSong("Stranded", path: "stranded.flac", source: networkSource)
        manager.play(songs: [strandedSong])
        await settle()

        XCTAssertNil(manager.player.currentItem)
    }

    /// Answers "does the Queue screen show what MPD actually has queued" — it should, and this
    /// proves it by having fetchQueue return a different set of files than what was optimistically
    /// assumed at the point `play` was called, and confirming the manager's queue converges to
    /// MPD's version once the post-command poll runs.
    func testQueueReconcilesFromMPDsActualPlaylistAfterAPoll() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songA = makeSong("A", path: "a.flac", source: source)
        let songB = makeSong("B", path: "b.flac", source: source)
        let songsByPath = ["a.flac": songA, "b.flac": songB]

        manager.setActiveSource(source, resolveSong: { songsByPath[$0] })
        await settle()

        // Simulate what MPD actually ended up with differing from our optimistic guess (e.g.
        // another client also touched the queue, or our own command only partially landed).
        await mock.setQueue(["b.flac", "a.flac"])
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 0, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 42))

        manager.play(songs: [songA, songB], startAt: 0)
        await settle()

        XCTAssertEqual(manager.queue.map(\.title), ["B", "A"])
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.fetchQueue))
    }

    func testQueueDoesNotRefetchWhenPlaylistVersionUnchanged() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songA = makeSong("A", path: "a.flac", source: source)

        manager.setActiveSource(source, resolveSong: { $0 == "a.flac" ? songA : nil })
        await settle()

        await mock.setQueue(["a.flac"])
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 0, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))

        manager.play(songs: [songA], startAt: 0)
        await settle()

        let fetchCountAfterFirstPoll = await mock.calls.filter { $0 == .fetchQueue }.count
        XCTAssertEqual(fetchCountAfterFirstPoll, 1)

        // A second poll with the same playlist version shouldn't re-fetch the queue.
        manager.togglePlayPause()
        await settle()

        let fetchCountAfterSecondPoll = await mock.calls.filter { $0 == .fetchQueue }.count
        XCTAssertEqual(fetchCountAfterSecondPoll, 1)
    }

    func testUnresolvableQueueEntryIsSkippedRatherThanCrashing() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songA = makeSong("A", path: "a.flac", source: source)

        // "unknown.flac" isn't in this app's synced library (e.g. added by another client).
        manager.setActiveSource(source, resolveSong: { $0 == "a.flac" ? songA : nil })
        await settle()

        await mock.setQueue(["unknown.flac", "a.flac"])
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 0, songPosition: 1, isUpdatingDatabase: false, playlistVersion: 1))

        manager.play(songs: [songA], startAt: 0)
        await settle()

        XCTAssertEqual(manager.queue.map(\.title), ["A"])
    }

    func testClearQueueStopsPlaybackAndClearsTheServerQueue() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ], startAt: 0)
        await settle()

        manager.clearQueue()
        await settle()

        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertNil(manager.currentIndex)
        XCTAssertFalse(manager.isPlaying)

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.clearQueue))
    }

    /// Switching modes must stop the server, not just hang up on it — disconnecting a control
    /// client doesn't stop MPD's playback, so the previous mode would otherwise keep playing.
    func testSwitchingAwayFromNetworkSourceStopsServerPlaybackFirst() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        manager.setActiveSource(Source(name: "Local", kind: .local))
        await settle()

        let calls = await mock.calls
        let stopIndex = calls.firstIndex(of: .stop)
        let disconnectIndex = calls.firstIndex(of: .disconnect)
        XCTAssertNotNil(stopIndex, "server playback should be stopped when leaving remote mode")
        if let stopIndex, let disconnectIndex {
            XCTAssertLessThan(stopIndex, disconnectIndex, "stop must be sent before disconnecting")
        }
        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertFalse(manager.isPlaying)
    }

    /// The library screens are held back while the host rebuilds its database, using this flag
    /// — taken from the status poll that already runs, so it costs no extra requests.
    func testTracksHostDatabaseSyncFromTheStatusPoll() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        await mock.setStatus(MPDStatus(state: "stop", elapsed: 0, duration: 0, songPosition: nil, isUpdatingDatabase: true))

        manager.setActiveSource(source)
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        XCTAssertTrue(manager.isHostSyncingDatabase)

        // Switching away from the network source clears it, so the local library isn't gated.
        manager.setActiveSource(Source(name: "Local", kind: .local))
        await settle()
        XCTAssertFalse(manager.isHostSyncingDatabase)
    }

    /// Backgrounding must not kill the ability to control the server: the lock screen and
    /// Control Center still send transport commands. Only the status poll — which exists purely
    /// to keep the UI in step — should stop.
    func testBackgroundingKeepsTheConnectionForLockScreenControls() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        manager.suspendRemotePolling()
        await settle()

        // A transport command from the lock screen while backgrounded must still reach MPD.
        manager.pause()
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setPause(true)), "backgrounded transport commands should still be sent")
        XCTAssertFalse(calls.contains(.disconnect), "backgrounding shouldn't drop the connection")
    }

    /// The reported bug: after the app was suspended the socket was dead and every command
    /// silently did nothing, with only an app restart (or toggling source) fixing it. Commands
    /// now reconnect and retry on demand.
    func testACommandReconnectsWhenTheConnectionDiedWhileSuspended() async {
        var madeClients: [MockMPDClient] = []
        let manager = PlaybackManager(makeMPDClient: {
            let client = MockMPDClient()
            madeClients.append(client)
            return client
        })
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()

        // Simulate the socket having died while the app was suspended.
        await madeClients[0].setCommandError(MPDError.connectionFailed("socket closed"))

        manager.pause()
        for _ in 0..<40 where madeClients.count < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(madeClients.count, 2, "a failed command should rebuild the connection")
        let retriedCalls = await madeClients[1].calls
        XCTAssertTrue(retriedCalls.contains(.setPause(true)), "the command should be retried on the new connection")
    }

    func testForegroundingResumesPollingAndReconnectsIfNeeded() async {
        var madeClients: [MockMPDClient] = []
        let manager = PlaybackManager(makeMPDClient: {
            let client = MockMPDClient()
            madeClients.append(client)
            return client
        })
        manager.setActiveSource(makeNetworkSource())
        await settle()

        manager.suspendRemotePolling()
        await settle()
        manager.resumeRemoteSession()
        await settle()

        // Session was still alive, so no rebuild — just polling again.
        XCTAssertEqual(madeClients.count, 1)
        let calls = await madeClients[0].calls
        XCTAssertTrue(calls.contains(.connect(host: "127.0.0.1", port: 6600)))
    }

    /// iOS only shows the lock screen / Control Center widget for an app that owns an active
    /// audio session and is producing audio. In remote mode the server makes the sound, so the
    /// app has to hold the session itself or no widget appears — which is why it worked locally
    /// but not remotely.
    func testHoldsTheNowPlayingSessionWhileTheServerIsPlaying() async {
        let mock = MockMPDClient()
        let session = SpyNowPlayingSession()
        let manager = PlaybackManager(makeMPDClient: { mock }, remoteKeepAlive: session)
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()

        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()
        manager.resume()
        await settle()

        XCTAssertTrue(session.isRunning, "the session should be held while the server plays")

        manager.pause()
        await settle()
        XCTAssertFalse(session.isRunning, "pausing should release the session again")
    }

    func testReleasesTheNowPlayingSessionWhenLeavingRemoteMode() async {
        let mock = MockMPDClient()
        let session = SpyNowPlayingSession()
        let manager = PlaybackManager(makeMPDClient: { mock }, remoteKeepAlive: session)
        let source = makeNetworkSource()
        manager.setActiveSource(source)
        await settle()
        manager.play(songs: [makeSong("A", path: "a.flac", source: source)], startAt: 0)
        await settle()
        manager.resume()
        await settle()
        XCTAssertTrue(session.isRunning)

        manager.setActiveSource(Source(name: "Local", kind: .local))
        await settle()

        XCTAssertFalse(session.isRunning, "local playback owns the session on its own")
    }

    func testSwitchingBackToLocalSourceDisconnects() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let networkSource = makeNetworkSource()
        manager.setActiveSource(networkSource)
        await settle()

        manager.setActiveSource(Source(name: "Local", kind: .local))
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.disconnect))
        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertNil(manager.currentIndex)
    }

    // MARK: - Returning to the network source

    private func stoppedStatus(playlistVersion: Int = 1) -> MPDStatus {
        // MPD omits `song:` entirely while stopped — that's the whole point of these tests.
        MPDStatus(state: "stop", elapsed: 0, duration: 0, songPosition: nil, isUpdatingDatabase: false, playlistVersion: playlistVersion)
    }

    /// Switching away from the network source sends `stop`, which leaves MPD with no current
    /// song. Coming back, the poll found no `song:` in the status and left `currentIndex` nil,
    /// so the player view had nothing to act on and every control was dead until a queue row
    /// was tapped. The queue is there — anchor on its first track.
    func testReturningToTheNetworkSourceAnchorsOnTheQueueWhenTheServerIsStopped() async {
        let mock = MockMPDClient()
        await mock.setStatus(stoppedStatus())
        await mock.setQueue(["a.flac", "b.flac"])

        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ]
        let resolve: (String) -> Song? = { uri in songs.first { $0.relativePath == uri } }

        // remote -> local -> remote
        manager.setActiveSource(source, resolveSong: resolve)
        await settle()
        manager.setActiveSource(Source(name: "Local", kind: .local))
        await settle()
        manager.setActiveSource(source, resolveSong: resolve)
        await settle()

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B"], "the server's queue should be restored")
        XCTAssertEqual(
            manager.currentIndex, 0,
            "a stopped server reports no song position; the player still needs a current track"
        )
        XCTAssertNotNil(manager.currentSong)
    }

    /// And the anchored track must actually start. `pause 0` only lifts a real pause — on a
    /// stopped server it does nothing, so Play appeared to do nothing at all.
    func testPlayOnAStoppedServerStartsTheTrackRatherThanUnpausing() async {
        let mock = MockMPDClient()
        await mock.setStatus(stoppedStatus())
        await mock.setQueue(["a.flac", "b.flac"])

        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ]
        manager.setActiveSource(source, resolveSong: { uri in songs.first { $0.relativePath == uri } })
        // Wait for the first poll to mirror the server's queue and report it stopped. A fixed
        // number of yields is a race: pressing play before that has no queue to play within.
        await waitUntil { manager.queue.count == 2 && manager.currentIndex != nil }

        manager.togglePlayPause()
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(
            calls.contains(.playAtQueuePosition(0)),
            "resuming a stopped server must send `play <pos>`, got \(calls)"
        )
        XCTAssertFalse(calls.contains(.setPause(false)), "`pause 0` is a no-op while stopped")
        XCTAssertTrue(manager.isPlaying)
    }

    /// Skip has the same defect: MPD ignores `next`/`previous` while stopped.
    func testSkipOnAStoppedServerStartsTheNeighbouringTrack() async {
        let mock = MockMPDClient()
        await mock.setStatus(stoppedStatus())
        await mock.setQueue(["a.flac", "b.flac"])

        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ]
        manager.setActiveSource(source, resolveSong: { uri in songs.first { $0.relativePath == uri } })
        // Wait for the first poll to mirror the server's queue: skipping before it lands has
        // nothing to skip within, and a fixed number of yields is a race, not a wait.
        await waitUntil { manager.queue.count == 2 && manager.currentIndex != nil }

        manager.skipToNext()
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.playAtQueuePosition(1)), "got \(calls)")
        XCTAssertEqual(manager.currentIndex, 1)
    }

    /// The anchoring must not fight the server: once it reports a real position, that wins.
    func testAServerReportedPositionStillTakesPrecedence() async {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 5, duration: 100, songPosition: 1, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac", "b.flac"])

        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
        ]
        manager.setActiveSource(source, resolveSong: { uri in songs.first { $0.relativePath == uri } })
        // Waited for rather than assumed: a fixed number of yields races the connect-then-poll
        // sequence, which is what made this fail intermittently.
        await waitUntil { manager.currentIndex == 1 }

        XCTAssertEqual(manager.currentIndex, 1)
    }

    /// The remote half of the same rule: tapping a song the server already has queued should
    /// move to it, not send another `add` and grow MPD's queue with a duplicate.
    func testTappingAnAlreadyQueuedSongJumpsRatherThanAddingRemotely() async {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 100, songPosition: 2, isUpdatingDatabase: false, playlistVersion: 1))
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = makeNetworkSource()
        let songs = [
            makeSong("A", path: "a.flac", source: source),
            makeSong("B", path: "b.flac", source: source),
            makeSong("C", path: "c.flac", source: source),
        ]
        manager.setActiveSource(source, resolveSong: { uri in songs.first { $0.relativePath == uri } })
        await settle()
        manager.play(songs: songs, startAt: 2)
        await settle()

        manager.playNow(songs[0])
        await settle()

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.playAtQueuePosition(0)), "got \(calls)")
        XCTAssertFalse(calls.contains(.addToQueue(uri: "a.flac")), "the song is already on the server's queue")
        XCTAssertEqual(manager.queue.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(manager.currentIndex, 0)
    }

    // MARK: - The remote clock

    /// Waits for a condition, rather than assuming a fixed number of yields is enough for the
    /// connect-then-poll sequence to land.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func playingSource() -> Source {
        Source(name: "Network", host: "127.0.0.1", port: 6600, isActive: true, kind: .network)
    }

    /// The elapsed time runs off a local clock anchored to the last poll, so the scrubber moves
    /// smoothly without a request per tick. Asserted together: the time must advance *and* the
    /// host must not be polled for each advance.
    func testElapsedTimeAdvancesBetweenPollsWithoutPollingTheHost() async throws {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 10, duration: 300, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])
        let source = playingSource()
        let song = makeSong("A", path: "a.flac", source: source)

        let manager = PlaybackManager(makeMPDClient: { mock })
        manager.setActiveSource(source, resolveSong: { _ in song })
        // Wait for the first poll to land before measuring — otherwise the baseline is taken
        // before the server state has arrived at all.
        await waitUntil { manager.isPlaying && manager.duration > 0 }

        let pollsAfterConnect = await mock.statusFetchCount
        let timeAfterConnect = manager.currentTime
        XCTAssertEqual(timeAfterConnect, 10, accuracy: 0.5)

        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertGreaterThan(
            manager.currentTime, timeAfterConnect + 0.5,
            "the clock should have advanced on its own"
        )
        let extraPolls = await mock.statusFetchCount - pollsAfterConnect
        XCTAssertLessThanOrEqual(
            extraPolls, 2,
            "1.2s of playback should cost at most a poll or two, not one per clock tick"
        )
    }

    /// The interpolated clock is a guess about the gap between polls; it must never overshoot
    /// the track and show a nonsense elapsed time or a scrubber past full.
    func testTheClockDoesNotRunPastTheEndOfTheTrack() async throws {
        let mock = MockMPDClient()
        // Two seconds from the end of a short track.
        await mock.setStatus(MPDStatus(state: "play", elapsed: 1, duration: 2, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])
        let source = playingSource()
        let song = makeSong("A", path: "a.flac", source: source)

        let manager = PlaybackManager(makeMPDClient: { mock })
        manager.setActiveSource(source, resolveSong: { _ in song })
        await waitUntil { manager.isPlaying && manager.duration > 0 }

        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertLessThanOrEqual(manager.currentTime, manager.duration)
    }

    /// A paused server's clock must stand still, or the scrubber would creep while nothing plays.
    func testTheClockStopsWhenPaused() async throws {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 5, duration: 300, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])
        let source = playingSource()
        let song = makeSong("A", path: "a.flac", source: source)

        let manager = PlaybackManager(makeMPDClient: { mock })
        manager.setActiveSource(source, resolveSong: { _ in song })
        await waitUntil { manager.isPlaying && manager.duration > 0 }

        manager.pause()
        await settle()
        let atPause = manager.currentTime

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(manager.currentTime, atPause, accuracy: 0.05, "a paused clock must not creep")
    }
}
