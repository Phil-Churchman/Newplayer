import XCTest
@testable import NewPlayer

/// Falling back to the Spotify app on this phone when Connect will not start playback.
///
/// The Web API drives a Mac or a speaker without trouble and fails on the Spotify app running on
/// this same phone in several ways — refusing with 403 "Restriction violated", or accepting with
/// 204 and then stopping with no track and an empty queue. Some arrive as errors and some as
/// apparent success, so the only reliable test is whether Spotify is actually playing afterwards.
@MainActor
final class SpotifyLocalPlaybackTests: XCTestCase {
    private func spotifySource() -> Source {
        let source = Source(name: "Spotify", isActive: true, kind: .spotify)
        source.spotifyClientID = "client-123"
        return source
    }

    private func song(_ id: String, source: Source) -> Song {
        Song(title: id, artist: "A", albumTitle: "Al", albumArtist: "A",
             track: 1, duration: 200, relativePath: id, source: source)
    }

    /// Confirms run on a collapsed spacing so these don't sit for seconds each.
    private func makeManager(_ remote: FakeSpotifyPlayback) -> PlaybackManager {
        PlaybackManager(spotify: remote, spotifyConfirmSpacingNanoseconds: 1_000_000)
    }

    /// Yielding alone is not enough here. The recovery runs *after* `confirmSpotifyState`, which
    /// sleeps between its re-reads, and no number of yields makes a sleep elapse — so this waits
    /// on the clock as well. The spacing above is collapsed to a millisecond to keep it short.
    private func settle() async {
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await Task.yield()
        }
    }

    /// What Spotify reports when it took the command and did nothing: active device, no track.
    private func ignoredState() -> SpotifyPlayerState {
        SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "2b58ee7d"
        )
    }

    private func playingState() -> SpotifyPlayerState {
        SpotifyPlayerState(
            isPlaying: true, progressSeconds: 3, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "2b58ee7d"
        )
    }

    func testAPlayThatActuallyStartedNeedsNoFallback() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertTrue(remote.localPlayRequests.isEmpty,
                      "playback started, so there was nothing to repair")
    }

    func testAPlayConnectAcceptedAndIgnoredGoesToTheSpotifyApp() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertEqual(remote.localPlayRequests.first?.ids, ["t1"],
                       "the tracks Connect wouldn't play are handed to the Spotify app itself")
    }

    /// The fallback replaces the Connect play rather than joining it: exactly one Connect
    /// attempt, then the Spotify app is driven directly. Sending another play over Connect on
    /// top would fight what the app has been told to do.
    func testConnectIsNotRetriedOnceTheLocalAppTakesOver() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertEqual(remote.playRequests.count, 1, "one Connect attempt, not two")
        XCTAssertEqual(remote.localPlayRequests.count, 1, "and one handover to the Spotify app")
    }

    /// The whole queue goes across, not just the chosen track — the app's queue is the queue,
    /// and handing over only what was tapped would strand everything after it.
    func testTheWholeQueueAndPositionAreHandedToTheLocalApp() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(
            songs: [song("t1", source: source), song("t2", source: source), song("t3", source: source)],
            startAt: 1
        )
        await settle()

        XCTAssertEqual(remote.localPlayRequests.first?.ids, ["t1", "t2", "t3"])
        XCTAssertEqual(remote.localPlayRequests.first?.index, 1, "starting where the user tapped")
    }

    /// A device that isn't this phone can ignore a command too, and there is then nothing to
    /// launch — so the user gets told rather than left with a button that did nothing.
    func testAnUnreachableDeviceWithNoLocalSpotifyIsReported() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        remote.localPlayError = SpotifyAppRemoteError.spotifyNotInstalled
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertNotNil(manager.playbackErrorMessage)
        XCTAssertTrue(
            manager.playbackErrorMessage?.contains("didn't start playing") == true,
            "got: \(manager.playbackErrorMessage ?? "nil")"
        )
    }

    /// The regression this covers emptied the Queue screen and took the mini player with it.
    ///
    /// Spotify's queue is ignored while a play of ours is still landing — the Connect command
    /// clears it before anything refills it, and reading that empty state wiped the app's queue.
    /// But the flag saying so was only lowered on the success path, so a single refused play
    /// left it raised for the rest of the session: the queue mirror never ran again, on any
    /// device, and the app sat on a stale one-track queue with no current song.
    func testAFailedPlayDoesNotLeaveTheQueueMirrorSwitchedOff() async {
        let remote = FakeSpotifyPlayback()
        remote.errorToThrow = SpotifyError.actionNotAllowed("Restriction violated")
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        // The play failed. Spotify now reports a perfectly good queue, and the next play must
        // pick it up rather than the app staying blind to it.
        remote.errorToThrow = nil
        remote.state = playingState()
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [
                SpotifyQueueEntry(trackID: "t1", title: "One", artist: "A", artworkURL: nil, position: 0),
                SpotifyQueueEntry(trackID: "t2", title: "Two", artist: "A", artworkURL: nil, position: 1),
            ]
        )
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertEqual(manager.spotifyQueue.count, 2,
                       "the mirror has to keep working after a refused play")
    }

    /// A queue Spotify actually reports is applied straight away, even though the play that
    /// caused it is still settling. Holding these back too meant the Queue screen sat empty
    /// until the next poll seconds later.
    func testARealQueueIsMirroredWithoutWaitingForTheNextPoll() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [
                SpotifyQueueEntry(trackID: "t1", title: "One", artist: "A", artworkURL: nil, position: 0),
                SpotifyQueueEntry(trackID: "t2", title: "Two", artist: "A", artworkURL: nil, position: 1),
                SpotifyQueueEntry(trackID: "t3", title: "Three", artist: "A", artworkURL: nil, position: 2),
            ]
        )
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertEqual(manager.spotifyQueue.count, 3)
    }

    /// And the empty read that a Connect play leaves behind is *not* believed — that is what
    /// emptied the queue and took the mini player with it.
    func testAnEmptyQueueDuringAPlayDoesNotWipeWhatIsOnScreen() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [SpotifyQueueEntry(trackID: "t1", title: "One", artist: "A", artworkURL: nil, position: 0)]
        )
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()
        XCTAssertEqual(manager.spotifyQueue.count, 1)

        // Spotify goes blank mid-play, exactly as it does after a Connect command it won't act on.
        remote.state = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "2b58ee7d"
        )
        remote.queueSnapshot = SpotifyQueueSnapshot(currentTrackID: nil, entries: [])
        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()

        XCTAssertFalse(manager.queue.isEmpty, "the app's queue must survive the gap")
        XCTAssertNotNil(manager.currentSong, "and so must the mini player's current song")
    }

    /// Starting playback and building a queue need different tools on this phone, and the wrong
    /// one for either fails silently.
    ///
    /// App Remote starts playback where Connect cannot — but it cannot queue: its enqueue
    /// reports success for every track and Spotify keeps exactly one, so the next button had
    /// nothing to go to. Once something is playing, the phone takes ordinary Web API commands
    /// like any other device, so the queue is built that way instead.
    func testTheQueueIsBuiltOverTheWebAPIAfterTheLocalAppStartsPlaying() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(
            songs: [song("t1", source: source), song("t2", source: source), song("t3", source: source)],
            startAt: 0
        )
        await settle()

        XCTAssertEqual(remote.localPlayRequests.count, 1, "the Spotify app starts it")
        XCTAssertEqual(remote.queuedTrackIDs, ["t2", "t3"],
                       "and everything behind it is queued over the Web API")
    }

    /// Only what follows the chosen track is queued — the tracks before it are already behind.
    func testOnlyTracksAfterTheChosenOneAreQueued() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(
            songs: [song("t1", source: source), song("t2", source: source), song("t3", source: source)],
            startAt: 1
        )
        await settle()

        XCTAssertEqual(remote.queuedTrackIDs, ["t3"])
    }

    /// Each skip starts a run of re-reads spread over a second or more. Two runs at once both
    /// write the track and position from whenever their own poll lands, so a staler answer could
    /// arrive after a fresher one and drag the player back — which is what made rapid skipping
    /// jump about. Only the newest run may write.
    func testRapidSkipsLeaveOnlyTheNewestConfirmWriting() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)
        manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 0)
        await settle()

        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t2", activeDeviceID: "2b58ee7d"
        )
        manager.skipToNext()
        manager.skipToNext()
        manager.skipToNext()
        await settle()

        // Whatever Spotify last reported is what stands — not an older read arriving late.
        XCTAssertEqual(manager.currentSong?.relativePath, "t2")
        XCTAssertTrue(manager.isPlaying)
    }

    // MARK: - Showing the choice before Spotify confirms it

    /// Choosing a track used to leave the queue and mini player on the previous one until
    /// Spotify's own report came back — a round trip and a poll away. The app chose the context,
    /// so it can show it at once.
    func testChoosingATrackFillsTheQueueBeforeSpotifyAnswers() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        let album = Album(name: "Al", artist: nil, source: source)
        let songs = (1...3).map { n -> Song in
            let s = Song(title: "t\(n)", artist: "A", albumTitle: "Al", albumArtist: "A",
                         track: n, duration: 200, relativePath: "t\(n)", source: source)
            s.album = album
            return s
        }
        album.songs = songs

        manager.playNow(songs[0])

        // Read before any awaiting: this has to be true the moment the row is tapped.
        XCTAssertEqual(manager.currentSong?.relativePath, "t1", "the mini player fills at once")
        XCTAssertEqual(manager.spotifyQueue.map(\.trackID), ["t1", "t2", "t3"],
                       "and so does the queue")
    }

    /// The Queue row draws its cover from the entry's `artworkURL`. Seeding that nil made the
    /// artwork vanish the instant a track was tapped and return only when Spotify's own report
    /// arrived — carrying the very URL the library already held.
    func testTheSeededQueueCarriesArtwork() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        let album = Album(name: "Al", artworkURL: "https://example.test/cover.jpg", source: source)
        let songs = (1...2).map { n -> Song in
            let s = Song(title: "t\(n)", artist: "A", albumTitle: "Al", albumArtist: "A",
                         track: n, duration: 200, relativePath: "t\(n)", source: source)
            s.album = album
            return s
        }
        album.songs = songs

        manager.playNow(songs[0])

        XCTAssertEqual(manager.spotifyQueue.first?.artworkURL, "https://example.test/cover.jpg")
    }

    /// Spotify reports a new context as it builds it — the first entry or two, then the rest.
    /// Applying that collapsed a freshly chosen album to a couple of tracks and refilled it
    /// seconds later, which is what the queue "dropping to two songs" was.
    func testAQueueStillBeingBuiltDoesNotShrinkWhatWasChosen() async {
        let remote = FakeSpotifyPlayback()
        remote.state = playingState()
        // Spotify has only registered the first track of the new context so far.
        remote.queueSnapshot = SpotifyQueueSnapshot(
            currentTrackID: "t1",
            entries: [SpotifyQueueEntry(trackID: "t1", title: "One", artist: "A", artworkURL: nil, position: 0)]
        )
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(
            songs: [song("t1", source: source), song("t2", source: source), song("t3", source: source)],
            startAt: 0
        )
        await settle()

        XCTAssertEqual(manager.queue.count, 3, "the chosen album must not collapse mid-play")
    }

    /// Spotify goes on reporting the outgoing track for a beat after a new one is asked for, and
    /// that track is usually still in the new queue — choosing a track replaces the context with
    /// the rest of its own album. Following it dragged the player back to the previous track and
    /// left it showing the wrong details until Spotify caught up.
    func testThePlayerDoesNotFallBackToTheOutgoingTrack() async {
        let remote = FakeSpotifyPlayback()
        // Spotify still says t1 is playing, while the app has just asked for t3.
        remote.state = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 30, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "2b58ee7d"
        )
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(
            songs: [song("t1", source: source), song("t2", source: source), song("t3", source: source)],
            startAt: 2
        )

        // Right away, before any poll has had a chance to drag it back.
        XCTAssertEqual(manager.currentSong?.relativePath, "t3",
                       "the track that was asked for shows at once")

        await settle()
        XCTAssertEqual(manager.currentSong?.relativePath, "t3",
                       "and is still there once Spotify has caught up")
    }

    // MARK: - Switching back to this phone

    private func withLocalDeviceID(_ id: String, _ body: () async -> Void) async {
        UserDefaults.standard.set(id, forKey: "spotify.localDeviceID")
        await body()
        UserDefaults.standard.removeObject(forKey: "spotify.localDeviceID")
    }

    /// Moving playback *to this phone* is tried with a Connect transfer first, like any other
    /// device. Driving the Spotify app directly means launching it, which puts Spotify's
    /// authorization screen in front of the user — far too heavy a thing to do in anticipation.
    func testSwitchingToThisPhoneTransfersFirst() async {
        await withLocalDeviceID("phone-id") {
            let remote = FakeSpotifyPlayback()
            remote.state = playingState()
            let manager = makeManager(remote)
            let source = spotifySource()
            manager.setActiveSource(source)
            manager.play(songs: [song("t1", source: source), song("t2", source: source)], startAt: 0)
            await settle()
            let localPlaysBefore = remote.localPlayRequests.count

            manager.selectSpotifyDevice(id: "phone-id")
            await settle()

            XCTAssertTrue(remote.commands.contains { $0.hasPrefix("takeOver:phone-id") },
                          "a transfer is still the first thing tried")
            XCTAssertEqual(remote.localPlayRequests.count, localPlaysBefore,
                           "the Spotify app must not be launched before the transfer has failed")
        }
    }

    /// Any other device is still moved to with a transfer, which is what Connect is for.
    func testSwitchingToAnotherDeviceStillTransfers() async {
        await withLocalDeviceID("phone-id") {
            let remote = FakeSpotifyPlayback()
            remote.state = playingState()
            let manager = makeManager(remote)
            let source = spotifySource()
            manager.setActiveSource(source)
            manager.play(songs: [song("t1", source: source)], startAt: 0)
            await settle()
            let localPlaysBefore = remote.localPlayRequests.count

            manager.selectSpotifyDevice(id: "speaker-id")
            await settle()

            XCTAssertTrue(remote.commands.contains { $0.hasPrefix("takeOver:speaker-id") })
            XCTAssertEqual(remote.localPlayRequests.count, localPlaysBefore,
                           "the Spotify app on this phone has nothing to do with a speaker")
        }
    }

    /// Adding a track to the phone's own Spotify is the exact case the user hit, and it goes
    /// through a different code path from choosing an album — so it is checked separately.
    func testAppendingATrackAlsoRecoversFromAnIgnoredPlay() async {
        let remote = FakeSpotifyPlayback()
        remote.state = ignoredState()
        let manager = makeManager(remote)
        let source = spotifySource()
        manager.setActiveSource(source)

        manager.play(songs: [song("t1", source: source)], startAt: 0)
        await settle()
        manager.append(song("t2", source: source))
        await settle()

        XCTAssertEqual(remote.localPlayRequests.last?.ids.last, "t2",
                       "the appended track is what the Spotify app should be given")
    }
}
