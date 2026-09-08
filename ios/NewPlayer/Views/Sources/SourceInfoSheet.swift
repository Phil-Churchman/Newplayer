import SwiftUI

/// What each source is and what it can't do. Kept out of the list itself: as footers this ran to
/// several paragraphs and pushed the controls apart, when it is only wanted the once.
enum SourceInfoTopic: String, Identifiable {
    case local, mediaLibrary, network, spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local Library"
        case .mediaLibrary: return "Music Library"
        case .network: return "Network Host (MPD)"
        case .spotify: return "Spotify"
        }
    }

    var body: String {
        switch self {
        case .local:
            return """
            Plays audio files from a folder you choose on this device or in iCloud Drive.

            The folder is scanned for tracks and their tags, and access is remembered, so it \
            keeps working after the app is closed. Use the refresh icon after adding or removing \
            files to bring the library up to date.
            """
        case .mediaLibrary:
            return """
            Uses the songs already in the Music app on this device, instead of a folder you pick.

            Apple Music tracks that aren't downloaded to the device can't be played outside the \
            Music app, so those are skipped — the count is reported after each import.
            """
        case .network:
            return """
            Controls an MPD server on your network. The music plays on the server, not on this \
            device; this app browses its catalogue and sends it commands.

            The refresh icon re-fetches this app's copy of whatever the server currently has. \
            "Sync with Music Server" instead tells the server to rescan its own music folder \
            first, then refreshes this app's copy.
            """
        case .spotify:
            return """
            Signs in on Spotify's own page — this app never sees your password — and copies your \
            saved tracks and albums into the library so you can browse them here. Requires \
            Spotify Premium.

            Spotify does not hand its audio to other apps, so playback is sent to the Spotify \
            app on this device instead. Keep Spotify installed and signed in to the same account.

            The "Play On" list comes from Spotify's own account-wide device list. It can be \
            shorter than the one in the Spotify app, which additionally discovers Bluetooth, \
            AirPlay and network speakers itself — those appear here only once you have played \
            to them from Spotify at least once. There is no way for this app to see them before \
            that.

            To set this up, create an app at developer.spotify.com to get a client ID, and add \
            this redirect URI to it:

            \(SpotifyAuth.redirectURI)
            """
        }
    }
}

/// The circled "i" that opens the explanation for a source.
struct InfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentColor)
        }
        // Borderless, or the whole list row becomes one tap target and the switch stops working.
        .buttonStyle(.borderless)
        .accessibilityLabel("About this source")
    }
}

struct SourceInfoSheet: View {
    let topic: SourceInfoTopic
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(topic.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
