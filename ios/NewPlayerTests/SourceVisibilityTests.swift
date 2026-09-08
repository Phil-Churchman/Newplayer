import XCTest
import SwiftData
@testable import NewPlayer

/// Switching a source off in Sources hides it *and* gives it up. The stopping is done by the
/// existing active-source machinery, so these assert the two halves separately: that hiding
/// deactivates, and that deactivating stops playback and clears the app's queue.
@MainActor
final class SourceVisibilityTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeSong(_ title: String, source: Source) -> Song {
        Song(title: title, artist: "A", albumTitle: "Al", albumArtist: "A",
             track: 1, duration: 100, relativePath: "\(title).mp3", source: source)
    }

    /// Choosing a source is exclusive: turning one on turns the rest off, so there is never a
    /// second "active" source lurking behind the one on screen.
    func testSelectingASourceDeselectsTheOthers() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let local = Source(name: "Local", isActive: true, kind: .local)
        let spotify = Source(name: "Spotify", isActive: false, kind: .spotify)
        context.insert(local)
        context.insert(spotify)
        try context.save()

        SourceSelection.select(.spotify, among: [local, spotify], modelContext: context)

        XCTAssertTrue(spotify.isActive)
        XCTAssertFalse(local.isActive, "choosing one source is choosing away from the rest")
        XCTAssertEqual(SourceSelection.selectedKind, .spotify)
    }

    /// Turning the chosen source off leaves nothing selected.
    func testDeselectingLeavesNoActiveSource() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let local = Source(name: "Local", isActive: true, kind: .local)
        context.insert(local)
        try context.save()

        SourceSelection.select(nil, among: [local], modelContext: context)

        XCTAssertFalse(local.isActive)
        XCTAssertNil(SourceSelection.selectedKind)
    }

    /// A kind can be chosen before it has a row at all — that is what tells the library screens
    /// to ask for content rather than for a source.
    func testAKindCanBeSelectedBeforeItsSourceExists() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        SourceSelection.select(.spotify, among: [], modelContext: context)

        XCTAssertEqual(SourceSelection.selectedKind, .spotify)
        XCTAssertNil(SourceSelection.activeSource(among: []))
    }

    // MARK: - What the other screens should say

    func testNothingSelectedAsksForASource() {
        XCTAssertEqual(
            LibraryAvailability.current(sources: [], selectedKind: nil),
            .noSourceSelected
        )
    }

    func testASelectedKindWithNoRowAsksForContent() {
        XCTAssertEqual(
            LibraryAvailability.current(sources: [], selectedKind: .spotify),
            .selectedSourceEmpty
        )
    }

    func testASelectedSourceWithNoSongsAsksForContent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let local = Source(name: "Local", isActive: true, kind: .local)
        context.insert(local)
        try context.save()

        XCTAssertEqual(
            LibraryAvailability.current(sources: [local], selectedKind: .local),
            .selectedSourceEmpty,
            "a folder that has never been scanned has nothing to show yet"
        )
    }

    func testALoadedSourceIsReady() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let local = Source(name: "Local", isActive: true, kind: .local)
        context.insert(local)
        context.insert(makeSong("A", source: local))
        try context.save()

        XCTAssertEqual(
            LibraryAvailability.current(sources: [local], selectedKind: .local),
            .ready
        )
    }

    /// Giving up a local source stops the player and empties the queue.
    func testGivingUpALocalSourceStopsPlaybackAndClearsTheQueue() {
        let manager = PlaybackManager()
        let local = Source(name: "Local", isActive: true, kind: .local)
        manager.setActiveSource(local)
        manager.play(songs: [makeSong("A", source: local), makeSong("B", source: local)], startAt: 0)
        XCTAssertEqual(manager.queue.count, 2)

        manager.setActiveSource(nil)

        XCTAssertTrue(manager.queue.isEmpty)
        XCTAssertNil(manager.currentIndex)
        XCTAssertFalse(manager.isPlaying)
    }

    /// The MPD case: the server is told to stop and the app's mirror of the queue is dropped,
    /// but the queue on the server is never cleared — it isn't ours to clear.
    func testGivingUpTheNetworkSourceStopsTheServerWithoutClearingItsQueue() async {
        let mock = MockMPDClient()
        let manager = PlaybackManager(makeMPDClient: { mock })
        let network = Source(name: "Network", host: "127.0.0.1", port: 6600, isActive: true, kind: .network)
        manager.setActiveSource(network)
        for _ in 0..<5 { await Task.yield() }

        manager.play(songs: [makeSong("A", source: network)], startAt: 0)
        for _ in 0..<5 { await Task.yield() }

        manager.setActiveSource(nil)
        for _ in 0..<10 { await Task.yield() }

        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.stop), "the server should be told to stop playing")
        XCTAssertFalse(calls.contains(.clearQueue), "the server's own queue must be left alone")
        XCTAssertTrue(manager.queue.isEmpty, "the app's mirror of the queue is dropped")
        XCTAssertFalse(manager.isPlaying)
    }

    // MARK: - Not tearing playback down for nothing

    /// Selecting the source the player already has must change nothing. It is driven by an
    /// `onChange` over a computed `@Query` value, so it can fire again without the source really
    /// having changed — and since switching source stops playback and empties the queue, that
    /// showed up as the queue and mini player disappearing on their own.
    func testReselectingTheSameSourceLeavesPlaybackAlone() {
        let manager = PlaybackManager()
        let local = Source(name: "Local", isActive: true, kind: .local)
        manager.setActiveSource(local)
        manager.play(songs: [makeSong("A", source: local), makeSong("B", source: local)], startAt: 1)

        XCTAssertEqual(manager.queue.count, 2)
        let indexBefore = manager.currentIndex

        manager.setActiveSource(local)

        XCTAssertEqual(manager.queue.count, 2, "the queue must survive a repeated selection")
        XCTAssertEqual(manager.currentIndex, indexBefore)
    }

    /// A genuine change still tears down, as it must.
    func testSelectingADifferentSourceStillClearsTheQueue() {
        let manager = PlaybackManager()
        let local = Source(name: "Local", isActive: true, kind: .local)
        let other = Source(name: "Music Library", kind: .mediaLibrary)
        manager.setActiveSource(local)
        manager.play(songs: [makeSong("A", source: local)], startAt: 0)
        XCTAssertFalse(manager.queue.isEmpty)

        manager.setActiveSource(other)

        XCTAssertTrue(manager.queue.isEmpty)
    }

    /// A repeated call still refreshes the resolver: a resync replaces the rows it closes over.
    func testReselectingTheSameSourceStillRefreshesTheSongResolver() async {
        let mock = MockMPDClient()
        await mock.setStatus(MPDStatus(state: "play", elapsed: 0, duration: 100, songPosition: 0, isUpdatingDatabase: false, playlistVersion: 1))
        await mock.setQueue(["a.flac"])

        let manager = PlaybackManager(makeMPDClient: { mock })
        let network = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        let stale = makeSong("Stale", source: network)
        let fresh = Song(title: "Fresh", artist: "A", albumTitle: "Al", albumArtist: "A",
                         track: 1, duration: 100, relativePath: "a.flac", source: network)

        manager.setActiveSource(network, resolveSong: { _ in stale })
        manager.setActiveSource(network, resolveSong: { _ in fresh })

        let deadline = Date().addingTimeInterval(5)
        while manager.queue.first?.title != "Fresh" && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.queue.first?.title, "Fresh", "the newer resolver should be in use")
    }
}
