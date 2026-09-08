import XCTest
@testable import NewPlayer

@MainActor
final class PlaybackManagerTests: XCTestCase {
    private func makeSong(_ title: String, path: String? = nil) -> Song {
        Song(title: title, artist: "Artist", albumTitle: "Album", albumArtist: "Artist", track: 1, duration: 100, relativePath: path ?? "\(title).mp3")
    }

    func testPlayReplacesQueueAndSetsStartIndex() {
        let manager = PlaybackManager()
        let songs = [makeSong("A"), makeSong("B"), makeSong("C")]

        manager.play(songs: songs, startAt: 1)

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertEqual(manager.currentSong?.title, "B")
    }

    func testAppendJumpsToNewlyAddedSong() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B")], startAt: 0)

        manager.append(makeSong("C"))

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(manager.currentIndex, 2)
        XCTAssertEqual(manager.currentSong?.title, "C")
    }

    func testRemoveBeforeCurrentShiftsIndexDown() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B"), makeSong("C")], startAt: 2)

        manager.remove(at: 0)

        XCTAssertEqual(manager.queue.map(\.title), ["B", "C"])
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertEqual(manager.currentSong?.title, "C")
    }

    func testRemoveCurrentClampsIndexToLastRemainingItem() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B"), makeSong("C")], startAt: 2)

        manager.remove(at: 2)

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(manager.currentIndex, 1)
    }

    func testRemovingLastRemainingItemClearsCurrentIndex() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A")], startAt: 0)

        manager.remove(at: 0)

        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertNil(manager.currentIndex)
    }

    func testJumpToUpdatesCurrentIndex() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B"), makeSong("C")], startAt: 0)

        manager.jumpTo(index: 2)

        XCTAssertEqual(manager.currentIndex, 2)
        XCTAssertEqual(manager.currentSong?.title, "C")
    }

    // MARK: - Tapping a song that's already queued

    /// Tapping around the library used to append unconditionally, so revisiting a song you'd
    /// already played queued a second copy of it. Jump to the existing entry instead.
    func testTappingAnAlreadyQueuedSongJumpsToItRatherThanAppending() {
        let manager = PlaybackManager()
        let songs = [
            makeSong("A"),
            makeSong("B"),
            makeSong("C"),
        ]
        manager.play(songs: songs, startAt: 2)
        XCTAssertEqual(manager.currentIndex, 2)

        manager.playNow(songs[0])

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B", "C"], "no duplicate should be added")
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.currentSong?.title, "A")
    }

    /// A song that isn't queued yet still appends and plays, as before.
    func testTappingASongNotInTheQueueStillAppendsIt() {
        let manager = PlaybackManager()
        let queued = makeSong("A")
        let fresh = makeSong("B")
        manager.play(songs: [queued])

        manager.playNow(fresh)

        XCTAssertEqual(manager.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(manager.currentIndex, 1)
    }

    /// Matching is by song identity and file path, never by title — two different tracks that
    /// happen to share a name must not be treated as the same entry.
    func testMatchingIsByIdentityNotTitle() {
        let manager = PlaybackManager()
        // Two genuinely different tracks that happen to share a name — so, different files.
        let queued = makeSong("Intro", path: "artist-one/intro.mp3")
        let different = makeSong("Intro", path: "artist-two/intro.mp3")
        manager.play(songs: [queued])

        manager.playNow(different)

        XCTAssertEqual(manager.queue.count, 2, "a distinct song with the same title should append")
        XCTAssertEqual(manager.currentIndex, 1)
    }

    // MARK: - Keeping the library lists out of queue churn

    /// The library lists highlight the playing track by reading `currentSongID` alone. If queue
    /// churn moved that value, every append would invalidate a list of several thousand rows —
    /// the stutter an earlier fix removed by keeping those lists free of playback state.
    func testQueueChangesThatDoNotMoveTheTrackLeaveCurrentSongIDAlone() {
        let manager = PlaybackManager()
        let a = makeSong("A")
        let b = makeSong("B")
        manager.play(songs: [a], startAt: 0)

        let before = manager.currentSongID
        XCTAssertEqual(before, a.persistentModelID)

        // Someone else's queue edit: the playing track is untouched.
        manager.append(b)          // moves the track, so this one *should* change
        manager.jumpTo(index: 0)   // back to A
        XCTAssertEqual(manager.currentSongID, before)

        manager.remove(at: 1)      // drop B — A is still playing at index 0
        XCTAssertEqual(
            manager.currentSongID, before,
            "removing a different track must not disturb the highlight"
        )
    }

    func testCurrentSongIDFollowsTheTrack() {
        let manager = PlaybackManager()
        let songs = [makeSong("A"), makeSong("B")]
        manager.play(songs: songs, startAt: 0)
        XCTAssertEqual(manager.currentSongID, songs[0].persistentModelID)

        manager.skipToNext()
        XCTAssertEqual(manager.currentSongID, songs[1].persistentModelID)

        manager.clearQueue()
        XCTAssertNil(manager.currentSongID)
    }

    /// isCurrent drives the highlight in the Songs and album lists.
    func testIsCurrentMatchesOnlyThePlayingTrack() {
        let manager = PlaybackManager()
        let songs = [makeSong("A"), makeSong("B")]
        manager.play(songs: songs, startAt: 1)

        XCTAssertTrue(manager.isCurrent(songs[1]))
        XCTAssertFalse(manager.isCurrent(songs[0]))
    }
}
