import Foundation
@testable import NewPlayer

@MainActor
final class SpyNowPlayingSession: NowPlayingSessionHolding {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }
}
