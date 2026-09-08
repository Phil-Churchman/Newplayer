import XCTest
import Observation
@testable import NewPlayer

/// Verifies the Observation graph itself: that a SwiftUI view reading each of these properties
/// would actually be told when it changes. Converting `queue`/`currentIndex` to computed
/// properties over private storage is exactly the kind of change that can silently sever an
/// observation edge — the code still writes the value, the UI just stops hearing about it.
@MainActor
final class PlaybackObservationTests: XCTestCase {
    private func makeSong(_ title: String) -> Song {
        Song(title: title, artist: "A", albumTitle: "Al", albumArtist: "A", track: 1, duration: 100, relativePath: "\(title).mp3")
    }

    /// Runs `read`, then `mutate`, and reports whether observers were notified.
    private func notifies(read: @escaping () -> Void, mutate: () -> Void) -> Bool {
        var notified = false
        withObservationTracking(read) { notified = true }
        mutate()
        return notified
    }

    func testCurrentTimeChangeNotifiesObservers() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A")], startAt: 0)
        XCTAssertTrue(
            notifies(read: { _ = manager.currentTime }, mutate: { manager.seek(to: 42) }),
            "the player view's elapsed label and scrubber read currentTime"
        )
    }

    /// `duration` and `isPlaying` can't be moved through the local player here — a seeded song
    /// has no bookmarked folder, so AVPlayer never loads it and both stay at their initial
    /// values. Drive them the way the remote path does instead.
    func testDurationChangeNotifiesObservers() async {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 240, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        let song = Song(title: "A", artist: "A", albumTitle: "Al", albumArtist: "A", track: 1, duration: 240, relativePath: "a.flac", source: source)

        var notified = false
        withObservationTracking { _ = manager.duration } onChange: { notified = true }

        manager.setActiveSource(source, resolveSong: { _ in song })
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(notified, "the player view reads duration for the scrubber's range")
    }

    func testIsPlayingChangeNotifiesObservers() async {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 240, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])
        let manager = PlaybackManager(makeMPDClient: { mock })
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        let song = Song(title: "A", artist: "A", albumTitle: "Al", albumArtist: "A", track: 1, duration: 240, relativePath: "a.flac", source: source)

        var notified = false
        withObservationTracking { _ = manager.isPlaying } onChange: { notified = true }

        manager.setActiveSource(source, resolveSong: { _ in song })
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(notified)
    }

    func testQueueChangeNotifiesObservers() {
        let manager = PlaybackManager()
        XCTAssertTrue(
            notifies(read: { _ = manager.queue }, mutate: { manager.append(self.makeSong("A")) }),
            "the Queue screen reads `queue` through a computed property now"
        )
    }

    func testCurrentIndexChangeNotifiesObservers() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B")], startAt: 0)
        XCTAssertTrue(notifies(read: { _ = manager.currentIndex }, mutate: { manager.jumpTo(index: 1) }))
    }

    func testCurrentSongChangeNotifiesObservers() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B")], startAt: 0)
        XCTAssertTrue(
            notifies(read: { _ = manager.currentSong }, mutate: { manager.jumpTo(index: 1) }),
            "the player view reads currentSong to show the title and artwork"
        )
    }

    func testCurrentSongIDChangeNotifiesObservers() {
        let manager = PlaybackManager()
        manager.play(songs: [makeSong("A"), makeSong("B")], startAt: 0)
        XCTAssertTrue(notifies(read: { _ = manager.currentSongID }, mutate: { manager.jumpTo(index: 1) }))
    }
}
