import XCTest
@testable import NewPlayer

/// Spotify is the source of truth for its queue; this app only mirrors it. These cover the two
/// ways that mirroring went wrong — showing Spotify's padding as real entries, and believing a
/// momentary empty read.
final class SpotifyQueueParsingTests: XCTestCase {
    /// Builds the JSON `GET /me/player/queue` actually returns, including the padding Spotify
    /// adds: the playing track repeated inside `queue`, and the context looping to fill it.
    private func queueJSON(current: String, queue: [String]) -> Data {
        func item(_ id: String) -> String {
            """
            {"id":"\(id)","name":"\(id)","artists":[{"name":"A"}],"album":{"images":[{"url":"https://i/\(id)"}]}}
            """
        }
        let body = """
        {"currently_playing":\(item(current)),"queue":[\(queue.map(item).joined(separator: ","))]}
        """
        return Data(body.utf8)
    }

    private func snapshot(from data: Data) async throws -> SpotifyQueueSnapshot {
        let client = SpotifyWebAPIClient(session: StubURLProtocol.makeSession(returning: data))
        return try await client.fetchPlaybackQueue(accessToken: "token")
    }

    /// The reported bug: a four-track album showed three times over, because Spotify loops the
    /// context to fill the queue.
    func testARepeatedContextCollapsesToTheTracksAskedFor() async throws {
        let data = queueJSON(
            current: "a1",
            queue: ["a2", "a3", "a4", "a1", "a2", "a3", "a4", "a1", "a2"]
        )
        let result = try await snapshot(from: data)

        XCTAssertEqual(result.entries.map(\.trackID), ["a1", "a2", "a3", "a4"])
        XCTAssertEqual(result.currentTrackID, "a1")
    }

    /// Spotify also repeats the playing track inside `queue`, which showed as a duplicate row
    /// at the top.
    func testThePlayingTrackIsNotListedTwice() async throws {
        let result = try await snapshot(from: queueJSON(current: "t1", queue: ["t1", "t2"]))
        XCTAssertEqual(result.entries.map(\.trackID), ["t1", "t2"])
    }

    /// Positions are renumbered after collapsing, since they address rows on screen.
    func testPositionsAreContiguousAfterCollapsing() async throws {
        let result = try await snapshot(from: queueJSON(current: "a1", queue: ["a1", "a2", "a1"]))
        XCTAssertEqual(result.entries.map(\.position), [0, 1])
    }
}

/// Serves one canned response, so the real parsing code can be exercised without a network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200

    static func makeSession(returning data: Data, statusCode: Int = 200) -> URLSession {
        responseData = data
        self.statusCode = statusCode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
