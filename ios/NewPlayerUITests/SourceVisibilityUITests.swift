import XCTest

/// Drives the real app: the switches in Sources, what they hide, and the message the other tabs
/// fall back to. The wiring here — an @AppStorage switch, a deactivation, an active-source gate
/// on four tabs — is spread across places no unit test sees together.
final class SourceVisibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The accessibility element for a Toggle in a List spans the whole row, so tapping its
    /// centre lands on the label and does nothing. The switch control itself is the child.
    private func flip(_ name: String, in app: XCUIApplication) {
        let row = app.switches[name]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "missing switch for \(name)")
        let before = row.value as? String
        row.switches.firstMatch.tap()
        XCTAssertNotEqual(row.value as? String, before, "the switch for \(name) did not change")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Reset the switches, which persist in UserDefaults between runs.
        app.launchArguments += ["-uiTestSeedLibrary", "-uiTestResetSourceSwitches"]
        app.launch()
        return app
    }

    func testTurningOffTheSelectedSourceHidesItsRows() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        tabBar.buttons["Sources"].tap()

        XCTAssertTrue(app.switches["Local Library"].waitForExistence(timeout: 5), "each source should have a switch")
        XCTAssertTrue(app.buttons["Choose a Different Folder"].waitForExistence(timeout: 5))

        flip("Local Library", in: app)

        XCTAssertFalse(
            app.buttons["Choose a Different Folder"].waitForExistence(timeout: 2),
            "the rows below a switched-off source should be hidden"
        )
        XCTAssertTrue(app.switches["Local Library"].exists, "the switch itself stays, so it can be turned back on")
    }

    func testEverySourceHasASwitch() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        tabBar.buttons["Sources"].tap()

        for name in ["Local Library", "Music Library", "Network Host (MPD)"] {
            XCTAssertTrue(app.switches[name].waitForExistence(timeout: 5), "missing switch for \(name)")
        }
    }

    /// Switching off the source being browsed leaves nothing selected, and every other tab has
    /// to say so rather than showing its own "nothing here" state.
    func testDeselectingTheSourceShowsPleaseSelectSourceOnEveryOtherTab() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))

        tabBar.buttons["Songs"].tap()
        XCTAssertTrue(app.staticTexts["Track 01"].waitForExistence(timeout: 10), "seeded library should show")

        tabBar.buttons["Sources"].tap()
        flip("Local Library", in: app)

        for tab in ["Songs", "Artists", "Albums", "Queue"] {
            tabBar.buttons[tab].tap()
            XCTAssertTrue(
                app.staticTexts["Please Select Source"].waitForExistence(timeout: 5),
                "\(tab) should ask for a source to be selected"
            )
        }
    }
}
