import XCTest
@testable import NewPlayer

/// Exercises the real MediaPlayer-backed provider. A simulator has no Music library, so these
/// can only assert that it degrades quietly on an empty/unauthorised one — the useful behaviour
/// on a populated library still needs a device. They exist because every other media-library
/// test runs against a fake, which is exactly how a bug in this file shipped unnoticed.
@MainActor
final class SystemMediaLibraryTests: XCTestCase {
    func testUnknownTrackYieldsNoArtworkRatherThanCrashing() {
        let library = SystemMediaLibrary()
        XCTAssertNil(library.artworkData(forPersistentID: "0"))
        XCTAssertNil(library.artworkData(forPersistentID: "not-a-number"))
    }

    func testUnknownTrackYieldsNoAssetURL() {
        let library = SystemMediaLibrary()
        XCTAssertNil(library.assetURL(forPersistentID: "0"))
        XCTAssertNil(library.assetURL(forPersistentID: "not-a-number"))
    }

    func testFetchingAnEmptyLibraryReturnsNoTracks() {
        let library = SystemMediaLibrary()
        XCTAssertTrue(library.fetchTracks().isEmpty)
    }
}
