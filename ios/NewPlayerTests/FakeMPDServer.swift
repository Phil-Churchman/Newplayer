import Foundation
import Network

/// Minimal in-process TCP server speaking just enough of MPD's protocol to exercise
/// MPDClient's actual wire parsing.
///
/// MockMPDClient replaces the whole client, so it can't catch framing bugs in the real socket
/// code — notably the binary framing used by `readpicture`/`albumart`, where the payload is
/// followed by a newline separator *and then* the terminating "OK". This serves scripted byte
/// sequences so those exchanges can be asserted end to end.
final class FakeMPDServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeMPDServer")
    private let lock = NSLock()

    private var connection: NWConnection?
    private var pendingResponses: [Data] = []
    private var receivedBuffer = Data()
    private var receivedCommands: [String] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedCommands
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Queues the raw bytes to send in reply to each successive command line received.
    func script(_ responses: [Data]) {
        lock.lock()
        pendingResponses = responses
        lock.unlock()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeGuard = TestResumeGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeGuard.once { continuation.resume() }
                case .failed(let error):
                    resumeGuard.once { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        send(Data("OK MPD 0.23.5\n".utf8))
        receiveLoop()
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(incoming: data)
            }
            if !isComplete {
                self.receiveLoop()
            }
        }
    }

    private func handle(incoming data: Data) {
        lock.lock()
        receivedBuffer.append(data)
        var responsesToSend: [Data] = []
        while let newlineIndex = receivedBuffer.firstIndex(of: 0x0A) {
            let lineData = receivedBuffer[..<newlineIndex]
            let line = String(data: lineData, encoding: .utf8) ?? ""
            receivedBuffer.removeSubrange(...newlineIndex)
            receivedCommands.append(line)
            if line.hasPrefix("binarylimit") {
                // Connection setup, not part of a test's scripted exchange — answer it here so
                // scripts stay aligned with the commands the test actually cares about.
                responsesToSend.append(Data("OK\n".utf8))
            } else if !pendingResponses.isEmpty {
                responsesToSend.append(pendingResponses.removeFirst())
            }
        }
        lock.unlock()

        for response in responsesToSend {
            send(response)
        }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

private final class TestResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func once(_ work: () -> Void) {
        lock.lock()
        let already = hasResumed
        hasResumed = true
        lock.unlock()
        guard !already else { return }
        work()
    }
}
