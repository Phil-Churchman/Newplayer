import SwiftUI

/// What each source is and what it can't do. Kept out of the list itself: as footers this ran to
/// several paragraphs and pushed the controls apart, when it is only wanted the once.
enum SourceInfoTopic: String, Identifiable {
    case local, mediaLibrary, network, spotify, mpdServerSync, spotifyOfflineMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local files"
        case .mediaLibrary: return "Apple Music"
        case .network: return "MPD"
        case .mpdServerSync: return "Sync MPD Host to Music Server"
        case .spotifyOfflineMode: return "Spotify Offline Mode"
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
            "Sync MPD Host to Music Server" instead tells the server to rescan its own music \
            folder first, then refreshes this app's copy.
            """
        case .mpdServerSync:
            return """
            Tells the MPD host to rescan the music folder it is configured to serve, then copies \
            the result into this app.

            Two separate libraries are involved, which is why there are two controls. The MPD \
            host keeps its own catalogue of the files it can see, and this app keeps a copy of \
            that catalogue so it can be browsed quickly and offline. The refresh icon updates \
            only this app's copy; it cannot tell the host about files the host has not noticed.

            So use this after adding or removing music on the server itself — otherwise new \
            tracks stay invisible to both, however often this app refreshes. A rescan runs on \
            the host and can take a while on a large collection; progress is reported as the \
            host reports it.
            """
        case .spotifyOfflineMode:
            return """
            Normally this app drives Spotify Connect, which is a web service. Commands go out to \
            Spotify's servers and back to whichever device is playing — this phone, a desktop \
            app, a speaker in another room. That is what lets the app run the queue, skip, \
            pause, and follow along with whatever Spotify reports.

            With no connection, none of that is reachable. Offline mode stops trying: instead of \
            sending commands into the void and waiting for each to time out, it opens the \
            Spotify app at the track you picked, and Spotify plays it if it holds a download.

            So offline you get one track at a time. There is no queue — building one goes through \
            the same web service — and skip and pause have to come from Spotify's own controls \
            rather than from here. Picking a track opens Spotify each time, because there is no \
            connection left to reuse.

            Browsing is unaffected either way: the library lives on this device, so artists, \
            albums and songs are all there with or without a connection.

            One thing the app cannot do is tell you which tracks Spotify has downloaded. Spotify \
            provides no way to ask — not over the web, and not from the app on this phone — so a \
            track that isn't downloaded simply won't start.

            It is a switch rather than something automatic on purpose. "Online" is not the same \
            question as "will Spotify play this", and a flaky connection turning the app's \
            behaviour over without asking is worse than leaving it to you.
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
