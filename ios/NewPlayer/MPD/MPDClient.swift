import Foundation
import Network

/// A single TCP connection to an MPD server speaking its line-based text protocol, plus the
/// binary picture-fetch extension (`readpicture`/`albumart`). MPD accepts many concurrent
/// connections from the same client, so callers create a fresh instance per logical use
/// (one for a library sync, a separate long-lived one for playback control).
actor MPDClient: MPDClientProtocol {
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    // MPD speaks one command at a time per connection. Swift actors are reentrant at await
    // points, though, so without this, a status poll's `fetchStatus()` and a user-initiated
    // command (e.g. `setPause`, or the several round trips inside `replaceQueue`) could
    // interleave their sends/reads on the same socket — corrupting both exchanges. That
    // showed up as commands appearing to "hang" until an unrelated read resolved them (slow
    // pause/play) and, worse, a `clear`/`add`/`play` sequence getting torn apart by an
    // interleaved `status` poll so the server never actually received a coherent command
    // (the old song continuing to play after selecting a new one). This lock forces every
    // full command-response cycle to complete before the next one starts.
    private var isCommandInFlight = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    private static let maxArtworkBytes = 40 * 1024 * 1024 // safety cap against a runaway transfer
    private static let binaryChunkLimit = 128 * 1024
    /// Nothing may block forever. A socket dropped without a FIN reaching us (NAT/Wi-Fi sleep,
    /// or MPD closing an idle client) leaves a read pending that never completes — and because
    /// it holds the command lock, every later command queues behind it and the client wedges.
    /// That was the "works for a minute then goes dead" failure.
    private static let commandTimeout: TimeInterval = 8
    private static let artworkTimeout: TimeInterval = 30
    /// listallinfo on a large library legitimately takes a while.
    private static let bulkTimeout: TimeInterval = 180

    func connect(host: String, port: UInt16) async throws {
        disconnectSync()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MPDError.connectionFailed("Invalid port \(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeGuard = ResumeGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeGuard.resumeOnce { continuation.resume() }
                case .failed(let error):
                    resumeGuard.resumeOnce { continuation.resume(throwing: MPDError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    resumeGuard.resumeOnce { continuation.resume(throwing: MPDError.connectionFailed("Connection cancelled")) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Consume MPD's greeting line, e.g. "OK MPD 0.23.5".
        _ = try await readLine()

        // MPD's default binary_limit is 8 KiB, which turns a single multi-MB cover into
        // hundreds of request/response round trips — enough to bog down a modest server and
        // everything queued behind it. `binarylimit` was added in MPD 0.22.4; older servers
        // just ACK it, which is harmless (the ACK is consumed as that command's response).
        _ = try? await sendCommandAndReadLines("binarylimit \(Self.binaryChunkLimit)")
    }

    func disconnect() async {
        disconnectSync()
    }

    private func disconnectSync() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    // MARK: - Queries

    func fetchStatus() async throws -> MPDStatus {
        let lines = try await sendCommandAndReadLines("status")
        return MPDResponseParser.parseStatus(fromLines: lines)
    }

    func fetchAllSongs() async throws -> [MPDSongInfo] {
        let lines = try await sendCommandAndReadLines("listallinfo", timeout: Self.bulkTimeout)
        return MPDResponseParser.parseSongs(fromLines: lines)
    }

    func fetchQueue() async throws -> [String] {
        let lines = try await sendCommandAndReadLines("playlistinfo", timeout: Self.bulkTimeout)
        return MPDResponseParser.parseSongs(fromLines: lines).map(\.file)
    }

    func fetchAlbumArt(forFile file: String) async -> Data? {
        do {
            let data = try await fetchArtwork(command: "readpicture", file: file)
            if !data.isEmpty { return data }
        } catch {
            print("MPDClient: readpicture for \(file) failed — \(error)")
        }
        do {
            let data = try await fetchArtwork(command: "albumart", file: file)
            // Both methods can legitimately succeed with zero bytes when a file simply has no
            // embedded picture and its folder has no cover file — that's "no artwork", not an
            // error, so it must come back as nil rather than empty Data here.
            return data.isEmpty ? nil : data
        } catch {
            print("MPDClient: albumart for \(file) failed — \(error)")
            return nil
        }
    }

    func updateDatabase() async throws {
        _ = try await sendCommandAndReadLines("update", timeout: Self.bulkTimeout)
    }

    // MARK: - Playback control

    func setPause(_ paused: Bool) async throws {
        _ = try await sendCommandAndReadLines("pause \(paused ? 1 : 0)")
    }

    func stop() async throws {
        _ = try await sendCommandAndReadLines("stop")
    }

    func next() async throws {
        _ = try await sendCommandAndReadLines("next")
    }

    func previous() async throws {
        _ = try await sendCommandAndReadLines("previous")
    }

    func seek(seconds: Double) async throws {
        _ = try await sendCommandAndReadLines("seekcur \(seconds)")
    }

    func replaceQueue(uris: [String], startAt: Int) async throws {
        // Sent as a single MPD command list — one send/response round trip instead of
        // 2-plus-N — rather than N+2 separate sequential commands: much faster for anything
        // beyond a couple of tracks (a whole album, say), and it also shrinks the window
        // during which the command lock below is held.
        var commands = ["command_list_begin", "clear"]
        commands.append(contentsOf: uris.map { "add \"\(escape($0))\"" })
        if uris.indices.contains(startAt) {
            commands.append("play \(startAt)")
        }
        commands.append("command_list_end")
        _ = try await sendCommandAndReadLines(commands.joined(separator: "\n"))
    }

    func clearQueue() async throws {
        _ = try await sendCommandAndReadLines("command_list_begin\nstop\nclear\ncommand_list_end")
    }

    func addToQueue(uri: String) async throws {
        _ = try await sendCommandAndReadLines("add \"\(escape(uri))\"")
    }

    func playAtQueuePosition(_ position: Int) async throws {
        _ = try await sendCommandAndReadLines("play \(position)")
    }

    func deleteFromQueue(position: Int) async throws {
        _ = try await sendCommandAndReadLines("delete \(position)")
    }

    /// Races an operation against a deadline. On timeout the connection is torn down by the
    /// caller, which is what unblocks any read still pending inside it.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MPDError.timedOut
            }
            do {
                guard let result = try await group.next() else { throw MPDError.timedOut }
                group.cancelAll()
                return result
            } catch {
                // Tear the socket down *here*, not in the caller. The pending read is parked on
                // a continuation that cancellation cannot interrupt, and a task group will not
                // return until every child has finished — so waiting to clean up outside the
                // group deadlocks. Cancelling the connection makes that read fail, which lets
                // the group drain and the timeout actually surface.
                disconnectSync()
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Command serialization

    private func acquireCommandLock() async {
        if !isCommandInFlight {
            isCommandInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            commandWaiters.append(continuation)
        }
    }

    private func releaseCommandLock() {
        if commandWaiters.isEmpty {
            isCommandInFlight = false
        } else {
            commandWaiters.removeFirst().resume()
        }
    }

    // MARK: - Binary artwork protocol

    private func fetchArtwork(command: String, file: String) async throws -> Data {
        do {
            return try await withTimeout(Self.artworkTimeout) { [self] in
                try await performArtworkFetch(command: command, file: file)
            }
        } catch MPDError.serverError(let message) {
            throw MPDError.serverError(message)
        } catch {
            disconnectSync()
            throw error
        }
    }

    private func performArtworkFetch(command: String, file: String) async throws -> Data {
        await acquireCommandLock()
        defer { releaseCommandLock() }

        var offset = 0
        var result = Data()
        // MPD only sends "size:" on the response to the FIRST request in a paginated fetch
        // (subsequent requests at later offsets just repeat "binary: N" with no "size:" line)
        // — this must persist across loop iterations, not be re-declared fresh each time, or
        // the early-exit check below silently goes dead after the first chunk.
        var totalSize: Int?
        var requestCount = 0

        while true {
            requestCount += 1
            try await send("\(command) \"\(escape(file))\" \(offset)")

            var binarySize: Int?
            while true {
                let line = try await readLine()
                if line == "OK" {
                    print("MPDClient: \(command) for \(file) returned OK with no binary data (request #\(requestCount))")
                    return result
                }
                if line.hasPrefix("ACK ") {
                    throw MPDError.serverError(line)
                }
                if line.hasPrefix("size: ") {
                    totalSize = Int(line.dropFirst("size: ".count))
                } else if line.hasPrefix("binary: ") {
                    binarySize = Int(line.dropFirst("binary: ".count))
                    break
                }
                // Any other line (type:, or a stray blank) is ignored and we keep reading.
            }

            guard let chunkSize = binarySize else { throw MPDError.malformedResponse }
            if chunkSize > 0 {
                result.append(try await readExact(chunkSize))
            }

            // MPD frames a binary response as "binary: N\n" + N bytes + "\n" + "OK\n" — there
            // is a newline separator after the payload before the terminating OK. Reading a
            // single line here and demanding it equal "OK" consumed only that separator and
            // then failed, which both lost the image *and* left the real "OK" unread on a
            // long-lived connection, desyncing every command that followed on it.
            var terminator = try await readLine()
            while terminator.isEmpty {
                terminator = try await readLine()
            }
            if terminator.hasPrefix("ACK ") {
                throw MPDError.serverError(terminator)
            }
            guard terminator == "OK" else { throw MPDError.malformedResponse }

            if chunkSize == 0 { break }
            offset += chunkSize
            if let totalSize, offset >= totalSize { break }
            if result.count > Self.maxArtworkBytes { break }
        }

        if let totalSize, result.count != totalSize {
            print("MPDClient: \(command) for \(file) — received \(result.count) bytes across \(requestCount) request(s) but server reported size: \(totalSize)")
        } else {
            print("MPDClient: \(command) for \(file) — received \(result.count) bytes across \(requestCount) request(s)")
        }
        return result
    }

    // MARK: - Wire protocol primitives

    /// Sends a command and reads lines until "OK" (success) or "ACK ..." (error).
    private func sendCommandAndReadLines(
        _ command: String,
        timeout: TimeInterval = MPDClient.commandTimeout
    ) async throws -> [String] {
        do {
            return try await withTimeout(timeout) { [self] in
                try await performCommand(command)
            }
        } catch MPDError.serverError(let message) {
            // A protocol-level ACK is a normal reply; the stream is still in step.
            throw MPDError.serverError(message)
        } catch {
            // Anything else leaves the stream position unknown, so drop the connection rather
            // than read someone else's bytes next time. This also unblocks a pending read.
            disconnectSync()
            throw error
        }
    }

    private func performCommand(_ command: String) async throws -> [String] {
        await acquireCommandLock()
        defer { releaseCommandLock() }

        try await send(command)
        var lines: [String] = []
        while true {
            let line = try await readLine()
            if line == "OK" {
                return lines
            }
            if line.hasPrefix("ACK ") {
                throw MPDError.serverError(line)
            }
            lines.append(line)
        }
    }

    private func send(_ command: String) async throws {
        guard let connection else { throw MPDError.notConnected }
        let data = (command + "\n").data(using: .utf8) ?? Data()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MPDError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else { throw MPDError.notConnected }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MPDError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: MPDError.connectionFailed("Connection closed"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
                let lineData = receiveBuffer[..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                receiveBuffer.removeSubrange(...newlineIndex)
                return line
            }
            let chunk = try await receiveChunk()
            receiveBuffer.append(chunk)
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while receiveBuffer.count < count {
            receiveBuffer.append(try await receiveChunk())
        }
        let result = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(result)
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// NWConnection's `stateUpdateHandler` can fire multiple times over a connection's lifetime
/// (e.g. `.ready` then later `.failed`) from a background dispatch queue. This guards a
/// `CheckedContinuation` against being resumed more than once, with its own lock rather than a
/// plain captured `var`, since the closure invoking it isn't actor-isolated.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resumeOnce(_ work: () -> Void) {
        lock.lock()
        let alreadyResumed = hasResumed
        hasResumed = true
        lock.unlock()
        guard !alreadyResumed else { return }
        work()
    }
}
