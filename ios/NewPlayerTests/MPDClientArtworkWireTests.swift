import XCTest
@testable import NewPlayer

/// Exercises MPDClient's real socket/parsing code against a scripted fake MPD server, rather
/// than through MockMPDClient (which replaces the client entirely and so can't catch framing
/// bugs). Written after a binary-framing bug shipped twice: MPD writes a newline separator
/// between a binary payload and the terminating "OK", and not consuming it both lost the image
/// and desynced every subsequent command on the same long-lived connection.
final class MPDClientArtworkWireTests: XCTestCase {
    private var server: FakeMPDServer!

    override func setUpWithError() throws {
        server = try FakeMPDServer()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Builds one chunk of an MPD binary response exactly as the server writes it:
    /// headers, then the payload, then a newline separator, then "OK".
    private func binaryResponse(totalSize: Int, chunk: Data, includeSizeHeader: Bool = true) -> Data {
        var data = Data()
        if includeSizeHeader {
            data.append(Data("size: \(totalSize)\n".utf8))
            data.append(Data("type: image/jpeg\n".utf8))
        }
        data.append(Data("binary: \(chunk.count)\n".utf8))
        data.append(chunk)
        data.append(Data("\n".utf8))
        data.append(Data("OK\n".utf8))
        return data
    }

    private func makePayload(byteCount: Int) -> Data {
        // Deterministic non-trivial bytes, including plenty of 0x0A newlines and 0x4F4B "OK"
        // sequences, so any accidental line-based parsing of the payload shows up as a failure.
        var data = Data(capacity: byteCount)
        for index in 0..<byteCount {
            data.append(UInt8(index % 256))
        }
        return data
    }

    func testReassemblesMultiChunkReadPictureResponse() async throws {
        try await server.start()

        let total = 20000
        let payload = makePayload(byteCount: total)
        let chunk1 = payload[0..<8192]
        let chunk2 = payload[8192..<16384]
        let chunk3 = payload[16384..<total]

        server.script([
            binaryResponse(totalSize: total, chunk: Data(chunk1)),
            // MPD only repeats "size:" on the first response in practice; later ones may omit
            // it, which the client must tolerate without terminating early.
            binaryResponse(totalSize: total, chunk: Data(chunk2), includeSizeHeader: false),
            binaryResponse(totalSize: total, chunk: Data(chunk3), includeSizeHeader: false),
        ])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)
        let art = await client.fetchAlbumArt(forFile: "some/song.flac")
        await client.disconnect()

        XCTAssertEqual(art, payload)
        XCTAssertEqual(art?.count, total)

        // Only readpicture should have been used — it succeeded, so no albumart fallback.
        let commands = server.commands
        XCTAssertTrue(commands.contains { $0.hasPrefix("readpicture ") })
        XCTAssertFalse(commands.contains { $0.hasPrefix("albumart ") })
    }

    func testFallsBackToAlbumArtWhenReadPictureHasNoPicture() async throws {
        try await server.start()

        let total = 512
        let payload = makePayload(byteCount: total)

        server.script([
            // readpicture: no embedded picture — a bare OK.
            Data("OK\n".utf8),
            // albumart: a cover file exists in the song's directory.
            binaryResponse(totalSize: total, chunk: payload),
        ])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)
        let art = await client.fetchAlbumArt(forFile: "some/song.flac")
        await client.disconnect()

        XCTAssertEqual(art, payload)

        let commands = server.commands
        XCTAssertTrue(commands.contains { $0.hasPrefix("readpicture ") })
        XCTAssertTrue(commands.contains { $0.hasPrefix("albumart ") })
    }

    /// The failure behind "works for a minute then goes dead": a socket that stops responding
    /// without closing leaves a read pending forever. Because that read holds the command lock,
    /// every later command queued behind it and the client wedged permanently. A command must
    /// time out instead, so callers can reconnect.
    func testACommandTimesOutRatherThanHangingWhenTheServerStopsResponding() async throws {
        try await server.start()
        // Deliberately script nothing: the server accepts the command and never replies.
        server.script([])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)

        let started = Date()
        do {
            _ = try await client.fetchStatus()
            XCTFail("expected the command to time out")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 30, "should give up rather than hang indefinitely")
        }
        await client.disconnect()
    }

    /// And having timed out, the client must not be wedged — a later command has to be able to
    /// run rather than queueing behind the abandoned read.
    func testClientIsUsableAfterATimeout() async throws {
        try await server.start()
        server.script([])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)
        _ = try? await client.fetchStatus() // times out

        // A second command should fail fast (connection was dropped), not block forever.
        let started = Date()
        _ = try? await client.fetchStatus()
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the client should not be wedged")
        await client.disconnect()
    }

    func testReturnsNilWhenNeitherCommandHasArtwork() async throws {
        try await server.start()

        server.script([
            Data("OK\n".utf8), // readpicture: nothing
            Data("OK\n".utf8), // albumart: nothing
        ])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)
        let art = await client.fetchAlbumArt(forFile: "some/song.flac")
        await client.disconnect()

        // "No artwork" must come back as nil, not empty Data — otherwise callers report it as
        // a decode failure instead of simply having no art.
        XCTAssertNil(art)
    }

    /// The regression that caused the reported bug: after an artwork fetch, the connection must
    /// still be usable. Previously the unconsumed "OK" left the stream desynced, so the next
    /// command read a stale line and returned nonsense.
    func testConnectionStaysInSyncForCommandsIssuedAfterAnArtworkFetch() async throws {
        try await server.start()

        let payload = makePayload(byteCount: 300)
        server.script([
            binaryResponse(totalSize: 300, chunk: payload),
            Data("volume: 100\nstate: play\nsong: 2\nplaylist: 7\nelapsed: 12.500\nduration: 240.000\nOK\n".utf8),
        ])

        let client = MPDClient()
        try await client.connect(host: "127.0.0.1", port: server.port)
        let art = await client.fetchAlbumArt(forFile: "some/song.flac")
        XCTAssertEqual(art, payload)

        let status = try await client.fetchStatus()
        await client.disconnect()

        XCTAssertEqual(status.state, "play")
        XCTAssertEqual(status.songPosition, 2)
        XCTAssertEqual(status.playlistVersion, 7)
        XCTAssertEqual(status.elapsed, 12.5, accuracy: 0.001)
    }
}
