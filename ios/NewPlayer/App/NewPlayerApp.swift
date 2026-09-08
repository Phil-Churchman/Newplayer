import SwiftUI
import SwiftData

@main
struct NewPlayerApp: App {
    let modelContainer = AppContainer.makeModelContainer()
    @State private var playback = PlaybackManager()

    init() {
        AudioSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(playback)
        }
        .modelContainer(modelContainer)
    }
}
