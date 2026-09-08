import XCTest

/// The app has two navigation shells — a tab bar in compact width, a sidebar split view in
/// regular — over the same screens. These assert whichever one this device gets, so the same
/// test is meaningful on an iPhone and an iPad.
final class LayoutUITests: XCTestCase {
    private let sections = ["Songs", "Artists", "Albums", "Queue", "Sources"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLibrary", "-uiTestResetSourceSwitches"]
        app.launch()
        return app
    }

    /// True on iPhone: the tab bar is the compact-width shell.
    private func isCompactLayout(_ app: XCUIApplication) -> Bool {
        app.tabBars.firstMatch.waitForExistence(timeout: 30)
    }

    func testEverySectionIsReachableInWhicheverShellThisDeviceUses() {
        let app = launch()

        if isCompactLayout(app) {
            let tabBar = app.tabBars.firstMatch
            for section in sections {
                tabBar.buttons[section].tap()
                XCTAssertTrue(
                    app.navigationBars[section].waitForExistence(timeout: 5),
                    "\(section) should show its own screen"
                )
            }
        } else {
            for section in sections {
                let item = app.cells.staticTexts[section].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 10), "sidebar should list \(section)")
                item.tap()
                XCTAssertTrue(
                    app.navigationBars[section].waitForExistence(timeout: 5),
                    "\(section) should show in the detail column"
                )
            }
        }
    }

    /// On a wide screen the sidebar and the current screen are visible together — that is the
    /// point of the layout, so the sidebar must not be a tab bar or a hidden drawer.
    func testRegularWidthShowsSidebarAndContentTogether() throws {
        let app = launch()
        try XCTSkipIf(isCompactLayout(app), "compact width uses the tab bar shell")

        XCTAssertTrue(app.cells.staticTexts["Songs"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Songs"].exists, "the screen shows beside the sidebar")
        XCTAssertTrue(app.tabBars.allElementsBoundByIndex.isEmpty, "no tab bar in the wide layout")
    }

    /// The mini player and the source indicator are part of the shell on both layouts.
    func testPersistentBarsAppearInBothShells() {
        let app = launch()
        _ = isCompactLayout(app)

        if app.tabBars.firstMatch.exists {
            app.tabBars.firstMatch.buttons["Songs"].tap()
        } else {
            app.cells.staticTexts["Songs"].firstMatch.tap()
        }

        let row = app.cells.containing(.staticText, identifier: "Track 03").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(app.otherElements["activeSourceBar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local Folder"].exists, "the source indicator names the source")
    }
}
