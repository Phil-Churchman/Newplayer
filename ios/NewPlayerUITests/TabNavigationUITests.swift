import XCTest

/// Drives the real app in the simulator. Unit tests can't catch SwiftUI wiring bugs like this
/// one: giving several TabView children the same `.id()` made every tab selection collapse
/// onto the first, so tapping Artists or Albums jumped straight to Songs. Nothing about that
/// is visible below the view layer, and it built and passed the whole unit suite.
final class TabNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEachTabShowsItsOwnScreen() {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "the tab bar should appear on launch")

        // Deliberately starts away from Songs: the bug always landed on Songs, so checking it
        // first would have passed regardless.
        for tab in ["Artists", "Albums", "Queue", "Sources", "Songs"] {
            let button = tabBar.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "the \(tab) tab should exist")
            button.tap()

            XCTAssertTrue(
                app.navigationBars[tab].waitForExistence(timeout: 5),
                "tapping \(tab) should show the \(tab) screen, not a different tab"
            )
        }
    }

    /// The source indicator is pinned above the tab bar on every tab, so a regression in the
    /// per-tab safe-area insets shows up here.
    func testActiveSourceIndicatorIsVisibleOnEveryTab() {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))

        for tab in ["Songs", "Artists", "Albums", "Queue", "Sources"] {
            tabBar.buttons[tab].tap()
            let indicator = app.staticTexts["No active source"]
            XCTAssertTrue(
                indicator.waitForExistence(timeout: 5),
                "the active-source indicator should be visible on the \(tab) tab"
            )
        }
    }
}
