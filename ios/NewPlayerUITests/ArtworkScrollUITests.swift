import XCTest

/// Covers are fetched only for rows that come to rest. A row flicked past has its task cancelled
/// before the settle delay elapses, so it never reaches the fetcher — which keeps decoding and
/// saving out of the middle of a scroll, where it showed as judder.
///
/// This exercises the real thing: a scroll in the running app, then a check that the list is
/// still usable and showing what it should.
final class ArtworkScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScrollingRemainsResponsiveThroughTheLibrary() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLibrary", "-uiTestResetSourceSwitches"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 30) {
            tabBar.buttons["Songs"].tap()
        } else {
            app.cells.staticTexts["Songs"].firstMatch.tap()
        }

        let firstRow = app.cells.containing(.staticText, identifier: "Track 01").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "the seeded library should be listed")

        // Several quick flicks, as a user browsing would.
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<4 {
            list.swipeUp(velocity: .fast)
        }
        for _ in 0..<4 {
            list.swipeDown(velocity: .fast)
        }

        // Back at the top and still interactive: a wedged main actor would fail this.
        XCTAssertTrue(
            app.cells.containing(.staticText, identifier: "Track 01").firstMatch.waitForExistence(timeout: 10),
            "the list should still respond after fast scrolling"
        )
        let row = app.cells.containing(.staticText, identifier: "Track 02").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(
            app.otherElements["miniPlayer"].waitForExistence(timeout: 10),
            "tapping a row after scrolling should still work"
        )
    }
}
