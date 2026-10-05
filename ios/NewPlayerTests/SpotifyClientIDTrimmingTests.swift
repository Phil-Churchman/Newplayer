import XCTest
@testable import NewPlayer

/// A client id copied from Spotify's dashboard in a browser arrives with a trailing newline, and
/// `CharacterSet.whitespaces` is spaces and tabs only — it does not remove one. Worse, `signIn`
/// used to trim a copy to test for emptiness and then send the original, so the newline went to
/// Spotify either way and the authorize page answered "client_id: invalid". That names the id as
/// wrong when the id is right, which is close to undiagnosable from the user's side.
@MainActor
final class SpotifyClientIDTrimmingTests: XCTestCase {
    func testAnIDOfNothingButWhitespaceAndNewlinesIsRejectedAsMissing() async {
        let auth = SpotifyAuth(session: BodyCapturingURLProtocol.makeSession())

        do {
            _ = try await auth.signIn(clientID: " \n\t ")
            XCTFail("expected missingClientID")
        } catch SpotifyError.missingClientID {
            // Expected: and reached before the browser sheet, so no window is needed.
        } catch {
            XCTFail("expected missingClientID, got \(error)")
        }
    }

    /// Refresh is where an id stored by an earlier build shows up, so it trims too — that is what
    /// lets an already-tainted id work again without a migration.
    func testRefreshSendsTheIDWithoutItsTrailingNewline() async throws {
        let auth = SpotifyAuth(session: BodyCapturingURLProtocol.makeSession())

        _ = try? await auth.refresh(clientID: "abc123\n", refreshToken: "r")

        let body = try XCTUnwrap(BodyCapturingURLProtocol.capturedBody)
        XCTAssertTrue(body.contains("client_id=abc123&") || body.hasSuffix("client_id=abc123"),
                      "the newline must not reach Spotify — sent: \(body)")
        XCTAssertFalse(body.contains("abc123%0A"))
    }
    // MARK: - Shape

    /// A real id passes untouched. 32 hex characters is the whole rule.
    func testAWellFormedIDHasNoComplaint() {
        XCTAssertNil(SpotifyAuth.clientIDComplaint(about: "0123456789abcdef0123456789abcdef"))
    }

    /// The pastes that actually cause "client_id: invalid", each named rather than merely
    /// refused, so the message tells the user which mistake they made.
    func testTheShapeCheckNamesWhatIsWrong() throws {
        let truncated = try XCTUnwrap(SpotifyAuth.clientIDComplaint(about: "0123456789abcdef"))
        XCTAssertTrue(truncated.contains("16 characters"), truncated)
        XCTAssertTrue(truncated.contains("not 32"), truncated)

        // A whole dashboard URL pasted in place of the id.
        let url = try XCTUnwrap(SpotifyAuth.clientIDComplaint(
            about: "https://developer.spotify.com/dashboard/0123456789abcdef0123456789abcdef"
        ))
        XCTAssertTrue(url.contains("'/'"), url)
        XCTAssertTrue(url.contains("':'"), url)

        // Right length, but something non-hex crept in.
        let stray = try XCTUnwrap(SpotifyAuth.clientIDComplaint(about: "0123456789abcdef0123456789abcde!"))
        XCTAssertTrue(stray.contains("'!'"), stray)
        XCTAssertFalse(stray.contains("not 32"), "the length is right, so it must not be blamed")
    }

    /// A space reads as nothing at all inside quotes, so it is named in words.
    func testASpaceInsideTheIDIsDescribedInWords() throws {
        let complaint = try XCTUnwrap(SpotifyAuth.clientIDComplaint(about: "0123456789abcdef 123456789abcdef"))
        XCTAssertTrue(complaint.contains("a space"), complaint)
    }

    /// Caught before the browser opens, and reported with the detail intact — the whole point is
    /// that the user reads this instead of Spotify's opaque page.
    func testAMisshapenIDFailsBeforeTheBrowserOpens() async {
        let auth = SpotifyAuth(session: BodyCapturingURLProtocol.makeSession())

        do {
            _ = try await auth.signIn(clientID: "not-a-client-id")
            XCTFail("expected the shape check to refuse it")
        } catch let error as SpotifyError {
            let message = try? XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message?.contains("doesn't look like a Spotify client ID") == true, "\(message ?? "")")
            XCTAssertTrue(message?.contains("not 32") == true, "\(message ?? "")")
        } catch {
            XCTFail("expected SpotifyError, got \(error)")
        }
    }

}

/// Records the form body of whatever request it is handed, then answers with a token payload so
/// the call completes rather than erroring before the body can be read.
final class BodyCapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedBody: String?

    static func makeSession() -> URLSession {
        capturedBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodyCapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession turns an httpBody into a stream by the time a protocol sees it, so the body
        // has to be read from there rather than from `httpBody`, which is nil.
        if let body = request.httpBody {
            Self.capturedBody = String(data: body, encoding: .utf8)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.capturedBody = String(data: data, encoding: .utf8)
        }

        let payload = Data(#"{"access_token":"t","expires_in":3600,"scope":""}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
