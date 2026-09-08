import XCTest

/// The mini player and source indicator are app chrome: they belong to the navigation shell, not
/// to whichever screen happens to be on top. Pushing into an artist or an album must not take
/// them away — which it did on iPad, where the bars had been attached to the screen inside the
/// navigation stack rather than to the stack.
final class PersistentBarsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLibrary", "-uiTestResetSourceSwitches"]
        app.launch()
        return app
    }

    /// Works on either shell: the tab bar in compact width, the sidebar in regular.
    private func open(_ section: String, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 30) {
            tabBar.buttons[section].tap()
        } else {
            app.cells.staticTexts[section].firstMatch.tap()
        }
    }

    private func startPlaying(_ app: XCUIApplication) {
        open("Songs", in: app)
        let row = app.cells.containing(.staticText, identifier: "Track 03").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the seeded library should be listed")
        row.tap()
        XCTAssertTrue(
            app.otherElements["miniPlayer"].waitForExistence(timeout: 10),
            "queueing a track should show the mini player"
        )
    }

    func testTheMiniPlayerSurvivesPushingIntoAnAlbum() {
        let app = launch()
        startPlaying(app)

        open("Albums", in: app)
        let album = app.cells.containing(.staticText, identifier: "Test Album").firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.tap()

        XCTAssertTrue(app.navigationBars["Test Album"].waitForExistence(timeout: 5), "the album should open")
        XCTAssertTrue(
            app.otherElements["miniPlayer"].exists,
            "the mini player belongs to the shell and must survive a push"
        )
        XCTAssertTrue(app.otherElements["activeSourceBar"].exists)
    }

    func testTheMiniPlayerSurvivesPushingIntoAnArtist() {
        let app = launch()
        startPlaying(app)

        open("Artists", in: app)
        let artist = app.cells.containing(.staticText, identifier: "Test Artist").firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 10))
        artist.tap()

        XCTAssertTrue(app.navigationBars["Test Artist"].waitForExistence(timeout: 5), "the artist should open")
        XCTAssertTrue(app.otherElements["miniPlayer"].exists)
        XCTAssertTrue(app.otherElements["activeSourceBar"].exists)
    }
}
