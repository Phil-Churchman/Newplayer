import Foundation

/// One track from a Spotify account's saved library.
struct SpotifyTrack: Equatable {
    var id: String
    var title: String
    var artistNames: [String]
    var albumName: String
    var albumArtistNames: [String]
    var trackNumber: Int
    var durationSeconds: TimeInterval
    /// Spotify's own album identity, so two releases sharing a name stay apart.
    var albumID: String
    /// Cover image, largest first as Spotify returns them.
    var albumArtworkURL: URL?
}

struct SpotifyAccount: Equatable {
    var displayName: String
    /// Spotify's `product` field: "premium", "free", or "open".
    var product: String

    var isPremium: Bool { product.lowercased() == "premium" }
}

/// A Spotify Connect device — a phone, desktop app, speaker — that can be told to play.
///
/// "Available" and "active" are different things: the Spotify app sitting open on a phone is
/// available but stays inactive until something plays on it. Commands sent with no device named
/// are refused in that state, which is why the app looks up devices and targets one by id.
struct SpotifyDevice: Equatable, Identifiable {
    var id: String
    var name: String
    var isActive: Bool
    /// True for devices Spotify won't let the Web API control at all.
    var isRestricted: Bool
    /// "Smartphone", "Computer", "Speaker", …
    var type: String
}

extension SpotifyDevice {
    /// How the device reads in the picker. Spotify's own names are often unhelpful out of
    /// context ("iPhone", "Web Player"), so the one that is this handset is called out, as is
    /// whichever is currently playing.
    func displayName(thisDeviceName: String) -> String {
        var label = name
        if !thisDeviceName.isEmpty, name.caseInsensitiveCompare(thisDeviceName) == .orderedSame {
            label += " (this device)"
        }
        if isActive { label += " — playing" }
        if isRestricted { label += " — not controllable" }
        return label
    }

    var isPhone: Bool { type.caseInsensitiveCompare("Smartphone") == .orderedSame }
}

enum SpotifyError: LocalizedError, Equatable {
    case missingClientID
    case notPremium(product: String)
    case authorizationCancelled
    case authorizationFailed(String)
    case requestFailed(String)
    case notSignedIn
    case noActiveDevice
    case permissionsMissing
    /// Spotify refused the action in its current state — not a permissions problem.
    case actionNotAllowed(String?)
    case onlyRestrictedDevices
    case rateLimited(retryAfterSeconds: Int?)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter the client ID from your Spotify developer dashboard first."
        case .notPremium(let product):
            return "This needs a Spotify Premium account — this one is \"\(product)\"."
        case .authorizationCancelled:
            return "Spotify sign-in was cancelled."
        case .authorizationFailed(let detail):
            return "Spotify sign-in failed: \(detail)"
        case .requestFailed(let detail):
            return "Couldn't read your Spotify library: \(detail)"
        case .notSignedIn:
            // Reached with an account still connected, not only with none: a stored token that
            // predates a scope the app now needs can never be refreshed into a working one, and
            // playback fails with this while Sources goes on showing the account as signed in.
            // "Sign in first" reads as a bug in that state, so this names the actual remedy.
            return "Spotify needs authorizing again — open Sources and tap Authorize Spotify Again."
        case .actionNotAllowed(let reason):
            // Attributed, because this is Spotify's own wording relayed word for word. Shown
            // bare it reads as though this app produced it, and its phrasing ("Impossible to
            // open link") describes Spotify's world rather than anything the user did here.
            guard let reason else { return "Spotify wouldn't allow that just now." }
            return "Spotify: \(reason)"
        case .permissionsMissing:
            return "Spotify refused this sign-in's permissions. Sign out and sign in again to grant playback access."
        case .noActiveDevice:
            return "Spotify has no device available to play on. Open the Spotify app on this phone, then try again."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "Spotify is limiting requests from this app. Try again in about \(retryAfterSeconds) second\(retryAfterSeconds == 1 ? "" : "s")."
            }
            return "Spotify is limiting requests from this app. Wait a minute and try again."
        case .onlyRestrictedDevices:
            return "The Spotify devices available won't accept remote control. Play a track once in the Spotify app on this phone, then try again."
        }
    }
}
