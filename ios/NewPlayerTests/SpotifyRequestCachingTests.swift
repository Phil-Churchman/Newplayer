import XCTest
@testable import NewPlayer

/// Every Spotify endpoint this app calls reports mutable state — what is in your library, what is
/// playing, which devices exist. Serving any of it from a cache produces a sync that faithfully
/// preserves a library you have already changed, which is exactly what happened: a re-sync
/// reported the same 3134 tracks it already held and correctly changed nothing.
final class SpotifyRequestCachingTests: XCTestCase {
    func testLibraryRequestsAreNeverServedFromACache() {
        let configuration = SpotifyWebAPIClient.makeConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache, "a URL cache here re-serves a library that has moved on")
    }

    /// The timeouts that stop a stalled request looking like a hung app.
    func testRequestsGiveUpRatherThanHanging() {
        let configuration = SpotifyWebAPIClient.makeConfiguration()

        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 180)
    }
}
