import SwiftUI

enum PersistentBarMetrics {
    /// Fixed so scrollable content can reserve exactly this much room beneath itself.
    static let miniPlayerHeight: CGFloat = 60
    /// The local/remote indicator, which is always present.
    static let sourceBarHeight: CGFloat = 28
}

/// Whether the persistent bars float over the content, so scrollable lists have to reserve room
/// beneath themselves for them.
///
/// True in the phone layout, where they are a `safeAreaInset` over each tab. False in the iPad
/// sidebar layout, where they occupy their own row below the split view and therefore take no
/// space from the content at all — reserving there would leave a blank strip under every list.
private struct PersistentBarsOverlayContentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var persistentBarsOverlayContent: Bool {
        get { self[PersistentBarsOverlayContentKey.self] }
        set { self[PersistentBarsOverlayContentKey.self] = newValue }
    }
}

/// Reserves room at the bottom of a scrollable list for the mini player.
///
/// The mini player is applied as a `safeAreaInset` on each tab's NavigationStack, which ought
/// to inset the list's scroll content automatically — but it doesn't reach the List through the
/// intervening containers, so the final row sat underneath it and couldn't be scrolled clear.
/// This adds the margin explicitly, and only while the mini player is actually showing.
private struct MiniPlayerContentInset: ViewModifier {
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.persistentBarsOverlayContent) private var barsOverlayContent

    func body(content: Content) -> some View {
        guard barsOverlayContent else { return AnyView(content) }
        return AnyView(reserved(content))
    }

    private func reserved(_ content: Content) -> some View {
        // The source bar is always there; the mini player only when something is queued.
        // Reserving both lands the last row's bottom edge exactly on the top of whichever
        // bar is uppermost.
        let miniPlayer = playback.currentSong == nil ? 0 : PersistentBarMetrics.miniPlayerHeight
        return content.contentMargins(
            .bottom,
            PersistentBarMetrics.sourceBarHeight + miniPlayer,
            for: .scrollContent
        )
    }
}

extension View {
    func miniPlayerContentInset() -> some View {
        modifier(MiniPlayerContentInset())
    }
}
