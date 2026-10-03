import AVFoundation
import Foundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    var onInterruptionBegan: (() -> Void)?
    var onRouteChangedDeviceUnavailable: (() -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// Claims the audio session for this app's own playback.
    ///
    /// Call this only when the app is about to make sound itself. `.playback` is an exclusive
    /// category, so activating it *interrupts whatever else is playing on this device* — and in
    /// Spotify mode that "whatever else" is the Spotify app on this same phone, which is the one
    /// thing the app is trying to keep playing. Claiming the session up front, before there is
    /// anything to play, is what made controlling Spotify on this device fight itself while
    /// controlling Spotify on a Mac was unaffected.
    func activate() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Non-fatal: playback will still attempt to proceed.
        }
    }

    /// Hands the session back, so an app that was interrupted by us — Spotify on this phone,
    /// typically — is told it may resume. Without `notifyOthersOnDeactivation` it is never
    /// prompted to, and stays silent until the user restarts it by hand.
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal: nothing the user can act on, and playback state is unaffected.
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .began {
            onInterruptionBegan?()
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable {
            onRouteChangedDeviceUnavailable?()
        }
    }
}
