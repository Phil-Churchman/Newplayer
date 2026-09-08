import XCTest
@testable import NewPlayer

/// Why the second sync hung: the playback poll runs every couple of seconds and asked for a
/// token like anyone else. When no token could be had silently it fell through to an
/// interactive sign-in — putting a web sheet on screen from a background poll, repeatedly, and
/// a presentation that never completes leaves the shared continuation suspended for good,
/// taking every later token request with it.
@MainActor
final class SpotifySessionTests: XCTestCase {
    private func expiredTokens(refreshToken: String? = "refresh") -> SpotifyTokens {
        SpotifyTokens(
            accessToken: "stale",
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(-10),
            scopes: SpotifyAuth.requiredScopes
        )
    }

    func testANonInteractiveCallerNeverOpensTheSignInPage() async {
        let auth = FakeSpotifyAuth()
        auth.signInError = SpotifyError.authorizationFailed("should never be reached")
        // No refresh token, so there is no silent route to a token either.
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens(refreshToken: nil))
        let session = SpotifySession(auth: auth, tokens: store)

        do {
            _ = try await session.accessToken(clientID: "abc", interactive: false)
            XCTFail("expected to be refused rather than prompting")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .notSignedIn)
        }
        XCTAssertEqual(auth.signInCount, 0, "a background caller must not present a sign-in page")
    }

    /// A silent refresh is still fine without interaction — that's the common case and needs no
    /// user involvement.
    func testANonInteractiveCallerMayStillRefreshSilently() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens())
        let session = SpotifySession(auth: auth, tokens: store)

        _ = try await session.accessToken(clientID: "abc", interactive: false)

        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(auth.signInCount, 0)
    }

    func testAnInteractiveCallerMaySignIn() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens(refreshToken: nil))
        let session = SpotifySession(auth: auth, tokens: store)

        _ = try await session.accessToken(clientID: "abc", interactive: true)

        XCTAssertEqual(auth.signInCount, 1)
    }

    /// Concurrent callers must produce one sign-in between them. Two refreshes race: Spotify
    /// rotates the refresh token, so the second presents one the first has already invalidated.
    func testConcurrentCallersShareASingleSignIn() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens(refreshToken: nil))
        let session = SpotifySession(auth: auth, tokens: store)

        async let first = session.accessToken(clientID: "abc")
        async let second = session.accessToken(clientID: "abc")
        _ = try await (first, second)

        XCTAssertEqual(auth.signInCount, 1, "the second caller should join the first, not start another")
    }

    /// A failed attempt must not leave the coalescing slot occupied, or every later request
    /// waits on a task that will never succeed.
    func testAFailedAttemptDoesNotWedgeLaterRequests() async {
        let auth = FakeSpotifyAuth()
        auth.signInError = SpotifyError.authorizationCancelled
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens(refreshToken: nil))
        let session = SpotifySession(auth: auth, tokens: store)

        _ = try? await session.accessToken(clientID: "abc")

        auth.signInError = nil
        let token = try? await session.accessToken(clientID: "abc")
        XCTAssertNotNil(token, "a later attempt should be able to succeed")
        XCTAssertEqual(auth.signInCount, 2)
    }

    /// One session serialises every token request in the app — playback, the device list, the
    /// sync. A refresh that never returns therefore takes all of them down, which is what made
    /// switching device look like the app freezing. The refresh is bounded so it cannot.
    func testAStalledRefreshDoesNotWedgeEveryLaterRequest() async throws {
        let auth = FakeSpotifyAuth()
        // Far longer than the deadline the session allows a refresh.
        auth.refreshHangsForNanoseconds = 60_000_000_000
        let store = InMemorySpotifyTokenStore(tokens: expiredTokens())
        // A short deadline stands in for the real one, so the suite doesn't wait it out.
        let session = SpotifySession(auth: auth, tokens: store, refreshDeadline: 0.2)

        // Non-interactive, so it cannot fall back to a sign-in page either.
        let started = Date()
        _ = try? await session.accessToken(clientID: "abc", interactive: false)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5, "a stalled refresh must give up rather than hang")

        // And having given up, the session is usable again.
        auth.refreshHangsForNanoseconds = nil
        let token = try await session.accessToken(clientID: "abc", interactive: false)
        XCTAssertEqual(token, auth.tokensToReturn.accessToken)
    }
}
