import XCTest

/// Tapping a song in a library list plays it, but must not queue a second copy of one that's
/// already in the queue — before, browsing back to a track you'd played appended it again.
///
/// (An earlier version of this file asserted the opposite, from when tapping always appended.
/// Duplicates are still possible in the queue itself — MPD's queue is mirrored from the server,
/// where another client can add the same track twice — which is why QueueView keys its rows by
/// position rather than by song identity.)
final class QueueDuplicatesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTappingAnAlreadyQueuedSongDoesNotAddASecondCopy() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLibrary"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "the tab bar should appear on launch")

        tabBar.buttons["Songs"].tap()
        // Scoped to list rows: once a song is queued the mini player shows the same title, and
        // tapping that opens the full-screen player instead.
        let firstTrack = app.cells.containing(.staticText, identifier: "Track 01").firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 10), "the seeded library should be listed")

        // Queue two different songs, then tap the first one again.
        firstTrack.tap()
        app.cells.containing(.staticText, identifier: "Track 02").firstMatch.tap()
        firstTrack.tap()

        tabBar.buttons["Queue"].tap()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))

        XCTAssertEqual(
            app.cells.containing(.staticText, identifier: "Track 01").count, 1,
            "re-tapping a queued song should move to it, not queue it again"
        )
        XCTAssertEqual(app.cells.count, 2, "the queue should still hold exactly the two songs")
    }
}
