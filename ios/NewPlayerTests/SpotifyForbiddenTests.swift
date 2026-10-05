import XCTest
@testable import NewPlayer

/// Spotify answers 403 for two unrelated things, and relaying both the same way sent the user
/// nowhere: a request made without a scope showed only Spotify's own "Insufficient client
/// scope", which names no remedy and no screen to find one on.
///
/// A missing scope is fixed by signing in again and nothing else; a playback restriction is
/// fixed by waiting or by picking another device. So they are told apart here and reported as
/// different errors.
@MainActor
final class SpotifyForbiddenTests: XCTestCase {
    private func error(fromForbiddenMessage message: String) async -> Error? {
        let body = Data(#"{"error":{"status":403,"message":"\#(message)"}}"#.utf8)
        let client = SpotifyWebAPIClient(
            session: StubURLProtocol.makeSession(returning: body, statusCode: 403)
        )
        do {
            _ = try await client.fetchSavedTracks(accessToken: "token") { _ in }
            return nil
        } catch {
            return error
        }
    }

    func testAMissingScopeAsksTheUserToAuthorizeAgain() async throws {
        let error = await error(fromForbiddenMessage: "Insufficient client scope")

        guard case SpotifyError.permissionsMissing = try XCTUnwrap(error) else {
            return XCTFail("expected permissionsMissing, got \(String(describing: error))")
        }
    }

    /// The other half: a restriction is about the state of playback now, so it keeps Spotify's
    /// own wording and must not throw the stored token away.
    func testAPlaybackRestrictionIsStillRelayedAsItIs() async throws {
        let error = await error(fromForbiddenMessage: "Restriction violated")

        guard case SpotifyError.actionNotAllowed(let reason) = try XCTUnwrap(error) else {
            return XCTFail("expected actionNotAllowed, got \(String(describing: error))")
        }
        // The path is appended on purpose: "Forbidden" alone does not say which of a sync's
        // five requests was refused.
        XCTAssertEqual(reason, "Restriction violated (GET /v1/me/tracks)")
    }
}
