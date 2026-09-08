import SwiftUI

/// Shown in place of the library screens while the MPD host is rebuilding its database.
/// The catalogue is in flux during an update — songs may be half-removed or not yet re-added —
/// so browsing or queueing from it would act on data that's about to change underneath.
struct HostSyncingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Music Sync in Progress", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("Please wait for MPD host music sync to complete.")
        }
    }
}

/// Wraps a screen so it defers to `HostSyncingView` while the host is syncing. Applied to every
/// screen except Sources, which is where the sync is monitored and reported in detail.
struct HostSyncGate<Content: View>: View {
    @Environment(PlaybackManager.self) private var playback
    @ViewBuilder let content: () -> Content

    var body: some View {
        if playback.isHostSyncingDatabase {
            HostSyncingView()
        } else {
            content()
        }
    }
}
