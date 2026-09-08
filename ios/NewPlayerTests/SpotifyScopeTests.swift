import XCTest
@testable import NewPlayer

/// The 401 that shipped: an access token carries the permissions it was issued with for life.
/// Adding the playback scopes to the app did not widen the token already in the Keychain, and a
/// refresh preserves the original set — so every Connect call came back "Permissions missing"
/// until the user worked out for themselves to sign in again.
@MainActor
final class SpotifyScopeTests: XCTestCase {
    private func tokens(
        scopes: Set<String>,
        expiresIn: TimeInterval = 3600
    ) -> SpotifyTokens {
        SpotifyTokens(
            accessToken: "stored",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scopes
        )
    }

    private let libraryOnlyScopes: Set<String> = ["user-library-read", "user-read-private"]

    func testATokenMissingThePlaybackScopesForcesAFreshSignIn() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: tokens(scopes: libraryOnlyScopes))
        let session = SpotifySession(auth: auth, tokens: store)

        let token = try await session.accessToken(clientID: "abc")

        XCTAssertEqual(auth.signInCount, 1, "a narrower token can only be widened by signing in again")
        XCTAssertEqual(auth.refreshCount, 0, "refreshing preserves the old scopes, so it can't help")
        XCTAssertEqual(token, auth.tokensToReturn.accessToken)
    }

    func testATokenWithEveryScopeIsReusedWithoutSigningIn() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: tokens(scopes: SpotifyAuth.requiredScopes))
        let session = SpotifySession(auth: auth, tokens: store)

        let token = try await session.accessToken(clientID: "abc")

        XCTAssertEqual(token, "stored")
        XCTAssertEqual(auth.signInCount, 0)
    }

    /// Tokens saved before scopes were recorded have none stored; those must be re-authorized
    /// rather than trusted, or the same 401 comes back on upgrade.
    func testATokenWithNoRecordedScopesIsTreatedAsInsufficient() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: tokens(scopes: []))
        let session = SpotifySession(auth: auth, tokens: store)

        _ = try await session.accessToken(clientID: "abc")

        XCTAssertEqual(auth.signInCount, 1)
    }

    /// An expired but sufficiently-scoped token still refreshes quietly — the widening rule
    /// must not send everyone back to the browser on every expiry.
    func testAnExpiredButFullyScopedTokenStillRefreshes() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: tokens(scopes: SpotifyAuth.requiredScopes, expiresIn: -10))
        let session = SpotifySession(auth: auth, tokens: store)

        _ = try await session.accessToken(clientID: "abc")

        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(auth.signInCount, 0)
    }

    /// A refused *playback* command must leave the stored tokens alone.
    ///
    /// This is the bug behind "it only works after signing out of Spotify and approving again":
    /// the playback poll runs every couple of seconds and cannot open a sign-in page, so when it
    /// discarded the tokens on a refusal the app was left with none — and the next sync needed a
    /// full re-authorization on Spotify's site. Recovery belongs to the sign-in flow, where the
    /// user is actually present.
    func testARefusedPlaybackCommandDoesNotThrowAwayTheStoredTokens() async throws {
        let auth = FakeSpotifyAuth()
        let store = InMemorySpotifyTokenStore(tokens: tokens(scopes: SpotifyAuth.requiredScopes))
        let session = SpotifySession(auth: auth, tokens: store)
        let client = FakeSpotifyClient()
        client.failCommandsUntilTokenChanges = "stored"

        let controller = SpotifyPlaybackController(session: session, client: client)
        controller.configure(clientID: "abc")

        do {
            try await controller.resume()
            XCTFail("expected the refusal to surface")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .permissionsMissing)
        }

        XCTAssertNotNil(store.load(), "a background refusal must not sign the user out")
        XCTAssertEqual(auth.signInCount, 0, "and must not try to open a sign-in page")
    }

    /// The error a user sees for a 401 must point at the fix.
    func testThePermissionsErrorSaysToSignInAgain() {
        let message = SpotifyError.permissionsMissing.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("sign in again"), "got: \(message)")
    }
}
