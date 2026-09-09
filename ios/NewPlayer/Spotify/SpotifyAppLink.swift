import UIKit

/// Opening the Spotify app from here.
///
/// A device only appears in Spotify's Connect list once it has an active session, so the cure
/// for "my phone isn't listed" is to wake Spotify on it once. This turns that from a hunt into
/// one tap.
@MainActor
protocol SpotifyAppLinking {
    /// Whether the Spotify app is installed on this device.
    var isInstalled: Bool { get }
    func open()
}

@MainActor
struct SpotifyAppLink: SpotifyAppLinking {
    /// Opens Spotify at the user's own library rather than a track, since the point is only to
    /// give it a reason to register with Connect.
    private static let url = URL(string: "spotify:")!

    var isInstalled: Bool {
        UIApplication.shared.canOpenURL(Self.url)
    }

    func open() {
        UIApplication.shared.open(Self.url)
    }
}
