import XCTest
@testable import NewPlayer

/// The rule deciding what the Music-library import will take. It lives as a pure function so it
/// can be tested at all: everything around it needs a real MPMediaItem, which can't be built in
/// a test, and that is how an earlier bug in this file shipped unnoticed.
@MainActor
final class MediaLibraryPlayabilityTests: XCTestCase {
    private let asset = URL(string: "ipod-library://item/item.m4a?id=1")

    func testATrackWithALocalAssetAndNoDRMIsPlayable() {
        XCTAssertTrue(SystemMediaLibrary.isPlayableLocally(assetURL: asset, hasProtectedAsset: false))
    }

    /// Apple Music's own tracks are DRM-protected; AVPlayer cannot open them however they arrived.
    func testADRMProtectedTrackIsExcluded() {
        XCTAssertFalse(SystemMediaLibrary.isPlayableLocally(assetURL: asset, hasProtectedAsset: true))
    }

    /// No asset URL means nothing is stored on the device to play.
    func testATrackThatIsNotDownloadedIsExcluded() {
        XCTAssertFalse(SystemMediaLibrary.isPlayableLocally(assetURL: nil, hasProtectedAsset: false))
    }

    /// Both wrong is still just excluded.
    func testAProtectedTrackWithNoAssetIsExcluded() {
        XCTAssertFalse(SystemMediaLibrary.isPlayableLocally(assetURL: nil, hasProtectedAsset: true))
    }
}
