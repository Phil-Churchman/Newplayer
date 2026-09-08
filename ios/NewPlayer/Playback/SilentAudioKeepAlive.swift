import AVFoundation

/// Injectable so tests can assert on when the session is claimed and released without
/// depending on the simulator actually producing audio.
@MainActor
protocol NowPlayingSessionHolding: AnyObject {
    func start()
    func stop()
    var isRunning: Bool { get }
}

/// Keeps the app registered as the system's "now playing" app while playback is happening on a
/// remote MPD server.
///
/// iOS only surfaces the lock screen / Control Center transport widget for an app that owns an
/// active audio session *and is actually producing audio*. Setting `MPNowPlayingInfoCenter` is
/// not sufficient on its own. In remote mode the audio comes out of the server, so the app
/// produces none and never claims the slot — which is why the widget appeared in local mode
/// only. Playing inaudible silence for the duration is how remote-control apps hold it.
///
/// Deliberately conservative about when it runs:
/// - only while something is actually playing remotely, so it stops as soon as you pause;
/// - never when another app is already playing audio, so controlling your stereo doesn't
///   interrupt a podcast on the phone (the cost being no widget in that case).
@MainActor
final class SilentAudioKeepAlive: NowPlayingSessionHolding {
    private var player: AVAudioPlayer?

    var isRunning: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else { return }
        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            print("SilentAudioKeepAlive: another app is playing audio — not claiming the session")
            return
        }

        do {
            let player = try AVAudioPlayer(data: Self.silentWAVData())
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            print("SilentAudioKeepAlive: couldn't start — \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// A fraction of a second of 16-bit PCM silence, looped. Generated rather than shipped as
    /// an asset so there's no bundle resource to keep in step.
    private static func silentWAVData() -> Data {
        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount = sampleRate / 10 // 0.1s
        let dataBytes = Int(frameCount) * Int(channels) * Int(bitsPerSample / 8)

        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels)
        append(sampleRate)
        append(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)) // byte rate
        append(UInt16(channels * bitsPerSample / 8)) // block align
        append(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(UInt32(dataBytes))
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }
}
