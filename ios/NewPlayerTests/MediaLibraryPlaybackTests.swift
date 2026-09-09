import AVFoundation
import XCTest
@testable import NewPlayer

/// Music-library tracks reach AVPlayer by a different route from folder tracks: no bookmark, no
/// security scope, and a persistent ID resolved to an asset URL at the moment of playback.
@MainActor
final class MediaLibraryPlaybackTests: XCTestCase {
    private func makeSong(id: String, source: Source) -> Song {
        Song(
            title: "T", artist: "A", albumTitle: "Al", albumArtist: "A",
            track: 1, duration: 100, relativePath: id, source: source
        )
    }

    func testAMediaLibrarySongIsResolvedThroughTheLibraryNotAFolderBookmark() {
        let source = Source(name: "Music Library", isActive: true, kind: .mediaLibrary)
        let library = FakeMediaLibrary()
        let url = URL(string: "ipod-library://item/item.m4a?id=42")!
        library.assetURLs["42"] = url

        let manager = PlaybackManager(mediaLibrary: library)
        manager.play(songs: [makeSong(id: "42", source: source)], startAt: 0)

        let asset = manager.player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(asset?.url, url, "the song should be loaded from its Music-library asset URL")
    }

    /// A track deleted from the Music library since the import must fail quietly rather than
    /// handing AVPlayer a bogus path (which produces only a bare "fopen failed" in the log).
    func testATrackNoLongerInTheLibraryIsNotHandedToThePlayer() throws {
        let source = Source(name: "Music Library", isActive: true, kind: .mediaLibrary)
        let library = FakeMediaLibrary() // knows about no tracks

        let manager = PlaybackManager(mediaLibrary: library)
        manager.play(songs: [makeSong(id: "gone", source: source)], startAt: 0)

        XCTAssertNil(manager.player.currentItem)
        XCTAssertFalse(manager.isPlaying)
        // Said out loud. A tap that does nothing, with no explanation, is indistinguishable from
        // the app being broken — and it is the reason "are these tracks playable?" could not be
        // answered from using the app.
        let message = try XCTUnwrap(manager.playbackErrorMessage)
        XCTAssertTrue(message.contains("isn't on this device"), "got: \(message)")
    }

    /// Transport control still routes locally, not through MPD.
    func testMediaLibrarySongsUseTheLocalPlayerNotMPD() async {
        let source = Source(name: "Music Library", isActive: true, kind: .mediaLibrary)
        let library = FakeMediaLibrary()
        library.assetURLs["1"] = URL(string: "ipod-library://item/item.m4a?id=1")!

        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock }, mediaLibrary: library)
        manager.play(songs: [makeSong(id: "1", source: source)], startAt: 0)
        manager.pause()

        for _ in 0..<5 { await Task.yield() }

        let calls = await mock.calls
        XCTAssertTrue(calls.isEmpty, "a device-library song must never be sent to an MPD server")
    }

    /// A track that does load clears any complaint left by the last one.
    func testPlayingSuccessfullyClearsAPreviousFailure() {
        let source = Source(name: "Music Library", isActive: true, kind: .mediaLibrary)
        let library = FakeMediaLibrary()
        library.assetURLs["good"] = URL(string: "ipod-library://item/item.m4a?id=good")!

        let manager = PlaybackManager(mediaLibrary: library)
        manager.play(songs: [makeSong(id: "gone", source: source)], startAt: 0)
        XCTAssertNotNil(manager.playbackErrorMessage)

        manager.play(songs: [makeSong(id: "good", source: source)], startAt: 0)
        XCTAssertNil(manager.playbackErrorMessage)
    }
}
