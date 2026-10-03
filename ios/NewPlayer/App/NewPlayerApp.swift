import SwiftUI
import SwiftData

@main
struct NewPlayerApp: App {
    let modelContainer = AppContainer.makeModelContainer()
    @State private var playback = PlaybackManager()

    // No audio session is claimed here. `.playback` is exclusive, so claiming it at launch
    // interrupts whatever else is playing on the phone — including the Spotify app this one is
    // built to drive — before the app knows whether it will be making any sound at all. It is
    // claimed where sound is actually produced instead: local AVPlayer playback, and the silent
    // keep-alive that holds the now-playing widget in MPD mode.

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(playback)
                // Spotify sends the App Remote handshake back through the app's URL scheme
                // after it has been launched. The browser sign-in does *not* arrive here —
                // ASWebAuthenticationSession catches its own callback — so anything reaching
                // this is App Remote's, and it is handed straight over.
                .onOpenURL { url in
                    SpotifyAppRemote.shared.handleCallback(url)
                }
        }
        .modelContainer(modelContainer)
    }
}
