import Foundation
import SpotifyiOS
import UIKit

enum SpotifyAppRemoteError: Error, Equatable {
    /// No Spotify app on this phone, so there is nothing to drive.
    case spotifyNotInstalled
    /// Spotify is installed but refused the connection — usually a token without
    /// `app-remote-control`, or the app not running and declining to launch.
    case couldNotConnect(String?)
    /// Connected, but the command itself was refused.
    case commandFailed(String)
}

/// Drives the Spotify app on *this* phone directly, bypassing Connect.
///
/// This exists because the Web API cannot reliably start playback on the Spotify app running on
/// the same phone. Three distinct failures were seen, all of them only on this device:
///
/// - a play naming the phone while a speaker held playback → 403 "Restriction violated";
/// - a play naming the phone while the phone itself was playing → 204, and then Spotify stopped
///   with no track and an empty queue;
/// - a play naming the phone while Spotify was suspended → 204, and nothing ever started.
///
/// The same commands work against a Mac or a speaker. App Remote talks to the local Spotify
/// process over its own channel rather than going out to Spotify's backend and back, and it can
/// launch the app when it isn't running — neither of which the Web API can do. So the phone is
/// driven through here, and every other device stays on the Web API, which handles them well.
///
/// Narrowly scoped on purpose: this *starts* playback and nothing else. Queueing is the Web
/// API's job even on this phone, because App Remote's own enqueue silently keeps only one track.
@MainActor
protocol SpotifyAppRemoteControlling: AnyObject {
    /// Whether there is a Spotify app on this phone at all.
    var isSpotifyInstalled: Bool { get }
    /// Whether a live connection to it is currently held.
    var isConnected: Bool { get }
    /// Starts playback of `trackIDs[index]` on the Spotify app on this phone, launching it if it
    /// isn't running.
    ///
    /// Starting playback is *all* this does. It cannot build a queue: App Remote's enqueue
    /// reports success for every track and Spotify keeps only one, so the tracks that follow are
    /// lined up over the Web API instead, once this has got something playing.
    func play(trackIDs: [String], startAt index: Int, clientID: String, accessToken: String) async throws
    /// Handles the callback Spotify sends back after a launch. Returns whether the URL was ours.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool
    /// Drops the connection, so the app isn't holding one against a source it has left.
    func disconnect()
}

@MainActor
final class SpotifyAppRemote: NSObject, SpotifyAppRemoteControlling {
    /// Shared because the launch callback arrives as a URL opened on the app as a whole, and it
    /// has to reach the same instance that started the handshake.
    static let shared = SpotifyAppRemote()

    /// How long to wait for a connection to an already-running Spotify app before concluding it
    /// is not running and launching it instead. Connecting to a live app is a local handshake
    /// and takes well under a second; this is generous rather than tuned.
    private static let connectTimeoutNanoseconds: UInt64 = 2_500_000_000


    /// How long to wait for Spotify to hand control back after being launched. Longer than an
    /// ordinary connect on purpose: iOS is switching between two apps in the middle of it.
    private static let launchHandshakeTimeoutNanoseconds: UInt64 = 15_000_000_000

    private var appRemote: SPTAppRemote?
    private var configuredClientID: String?
    /// Resumed by the delegate callbacks. Held as an optional so a second attempt arriving mid
    /// handshake cannot strand or double-resume the first.
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    var isConnected: Bool { appRemote?.isConnected ?? false }

    var isSpotifyInstalled: Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    func play(trackIDs: [String], startAt index: Int, clientID: String, accessToken: String) async throws {
        guard isSpotifyInstalled else { throw SpotifyAppRemoteError.spotifyNotInstalled }
        guard !trackIDs.isEmpty else { return }

        let start = min(max(index, 0), trackIDs.count - 1)
        let ordered = Array(trackIDs[start...])
        let first = ordered[0]

        let remote = remote(for: clientID)
        remote.connectionParameters.accessToken = accessToken

        if !remote.isConnected {
            do {
                try await connect(remote)
                print("SpotifyAppRemote: connected to the running Spotify app")
            } catch {
                // Not running — this is the normal case, not the exception. The Spotify app is
                // usually suspended, so its local endpoint refuses the connection and the app
                // has to be launched with the track, which is the only way to start playback on
                // a suspended app.
                print("SpotifyAppRemote: Spotify isn't running — launching it playing \(first)")
                guard await authorizeAndPlay(remote, uri: "spotify:track:\(first)") else {
                    throw SpotifyAppRemoteError.couldNotConnect("Spotify refused to launch")
                }

                // Spotify hands control back through this app's URL scheme, and `handleCallback`
                // connects App Remote when it does. Worth waiting for even though the track is
                // already playing: a live connection is what lets the next command skip the
                // launch, and the launch is what puts Spotify's authorization screen on screen.
                do {
                    try await awaitConnection()
                } catch {
                    print("SpotifyAppRemote: launched and playing \(first), but the handshake didn't complete")
                }
                return
            }
        }

        print("SpotifyAppRemote: playing \(first)")
        try await playerCall { $0.play("spotify:track:\(first)", callback: $1) }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let remote = appRemote,
              let parameters = remote.authorizationParameters(from: url)
        else { return false }

        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            // Spotify issues App Remote its own token on the way back. It is scoped to App
            // Remote and is not interchangeable with the Web API token, so it is set here and
            // deliberately not written back to the token store.
            remote.connectionParameters.accessToken = token
            remote.connect()
            return true
        }
        if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            print("SpotifyAppRemote: authorization came back with an error — \(message)")
            finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect(message))
            return true
        }
        return false
    }

    func disconnect() {
        finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect("disconnected"))
        appRemote?.disconnect()
    }

    // MARK: - Plumbing

    private func remote(for clientID: String) -> SPTAppRemote {
        if let appRemote, configuredClientID == clientID { return appRemote }

        let configuration = SPTConfiguration(
            clientID: clientID,
            redirectURL: URL(string: SpotifyAuth.redirectURI)!
        )
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        appRemote = remote
        configuredClientID = clientID
        return remote
    }

    /// Bridges `connect()` and its three delegate callbacks into one awaitable call, with a
    /// timeout — a connect to an app that isn't running reports nothing at all on some iOS
    /// versions, and without the timeout this would hang rather than fall through to launching.
    private func connect(_ remote: SPTAppRemote) async throws {
        finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect("superseded"))

        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect("timed out"))
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            remote.connect()
        }
    }

    /// Waits for a connection this object did not itself initiate — the one `handleCallback`
    /// starts when Spotify returns from a launch. Given longer than an ordinary connect: the
    /// user is being bounced between two apps in the middle of it.
    private func awaitConnection() async throws {
        if isConnected { return }
        finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect("superseded"))

        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.launchHandshakeTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishConnection(throwing: SpotifyAppRemoteError.couldNotConnect("handshake timed out"))
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
        }
    }

    private func authorizeAndPlay(_ remote: SPTAppRemote, uri: String) async -> Bool {
        await withCheckedContinuation { continuation in
            remote.authorizeAndPlayURI(uri) { success in
                Task { @MainActor in continuation.resume(returning: success) }
            }
        }
    }

    /// Bridges one player-API call, which reports through a completion block, into async.
    private func playerCall(
        _ body: (SPTAppRemotePlayerAPI, @escaping SPTAppRemoteCallback) -> Void
    ) async throws {
        guard let playerAPI = appRemote?.playerAPI else {
            throw SpotifyAppRemoteError.couldNotConnect("no player to talk to")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body(playerAPI) { _, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(throwing: SpotifyAppRemoteError.commandFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Resumes the pending continuation exactly once, whichever way the handshake ended.
    private func finishConnection(throwing error: Error? = nil) {
        guard let continuation = connectionContinuation else { return }
        connectionContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

extension SpotifyAppRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.finishConnection() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.finishConnection(
                throwing: SpotifyAppRemoteError.couldNotConnect(error?.localizedDescription)
            )
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.finishConnection(
                throwing: SpotifyAppRemoteError.couldNotConnect(error?.localizedDescription)
            )
        }
    }
}
