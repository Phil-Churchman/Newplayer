import XCTest

/// Covers the reported bug: the last row of a list sitting behind the persistent bottom bars.
/// Needs a populated library, so it launches with the test-only seeding argument.
final class ListScrollingUITests: XCTestCase {
    private let lastTrack = "Track 40"

    /// How far below a bar's top edge the row beneath it may measure and still count as flush.
    ///
    /// "Flush" means the two edges land on the same point, and the arithmetic that gets there is
    /// floating point: one run produced a row maxY of 845.0000000000003 against a bar minY of
    /// 845.0 and failed a plain `>= 0`. A real row tucked behind a bar is out by points, so this
    /// still catches the bug the file exists for.
    private let flushTolerance: CGFloat = 0.5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLibrary"]
        app.launch()
        return app
    }

    /// The *row*, not the label inside it. Measuring the label is what made the first version of
    /// this test pass against a broken build: the label's centre cleared the mini player while
    /// the row — taller, being sized by the 40pt artwork — was still tucked behind it.
    private func lastRow(in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: lastTrack).firstMatch
    }

    private func scrollToBottom(of app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<15 {
            if app.staticTexts[lastTrack].exists { break }
            list.swipeUp()
        }
        list.swipeUp()
        list.swipeUp()
    }

    func testLastRowClearsTheMiniPlayer() {
        let app = launchSeededApp()

        let firstTrack = app.staticTexts["Track 01"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 30), "the seeded library should be listed")

        // Tapping a song queues it, which is what brings the mini player up.
        firstTrack.tap()
        let miniPlayer = app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "the mini player should appear once a song is queued")

        scrollToBottom(of: app)

        let row = lastRow(in: app)
        XCTAssertTrue(row.exists, "\(lastTrack)'s row should exist after scrolling to the bottom")

        let gap = miniPlayer.frame.minY - row.frame.maxY
        XCTAssertGreaterThanOrEqual(
            gap, -flushTolerance,
            "\(lastTrack)'s row (maxY \(row.frame.maxY)) is behind the mini player (minY \(miniPlayer.frame.minY))"
        )
        // Flush: the separator under the last row should land exactly on the bar's top edge.
        XCTAssertLessThan(gap, 2, "the last row should rest flush against the mini player, but stops \(gap)pt above it")
    }

    /// With nothing queued there's no mini player, so the list should come to rest on the
    /// local/remote indicator instead.
    func testLastRowClearsTheSourceBarWhenNothingIsQueued() {
        let app = launchSeededApp()

        XCTAssertTrue(app.staticTexts["Track 01"].waitForExistence(timeout: 30))

        let sourceBar = app.descendants(matching: .any).matching(identifier: "activeSourceBar").firstMatch
        XCTAssertTrue(sourceBar.waitForExistence(timeout: 5))

        scrollToBottom(of: app)

        let row = lastRow(in: app)
        XCTAssertTrue(row.exists, "\(lastTrack)'s row should exist after scrolling to the bottom")

        let gap = sourceBar.frame.minY - row.frame.maxY
        XCTAssertGreaterThanOrEqual(
            gap, -flushTolerance,
            "\(lastTrack)'s row (maxY \(row.frame.maxY)) is behind the source bar (minY \(sourceBar.frame.minY))"
        )
        XCTAssertLessThan(gap, 2, "the last row should rest flush against the source bar, but stops \(gap)pt above it")
    }
}
