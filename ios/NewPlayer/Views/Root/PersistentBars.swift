import SwiftUI

extension View {
    /// Applies the mini player and the active-source indicator as bottom safe-area insets on
    /// an individual tab's content, rather than on the enclosing TabView itself. Attaching
    /// `.safeAreaInset` directly to a TabView is a known SwiftUI pitfall on iOS 17 — it can
    /// make the TabView's own tab bar stop receiving touches once the inset view is non-empty.
    /// Applying it per-tab instead achieves the same "bars pinned above the tab bar" look
    /// without ever touching the TabView's own hit-testing.
    ///
    /// Order matters: each `.safeAreaInset` call stacks further toward the screen edge than
    /// the previous one, so applying the mini player first and the source bar second renders,
    /// top to bottom: content → mini player → active-source bar → tab bar.
    /// The bars are clipped to their own bounds. Their content already sits correctly inside the
    /// iPad detail column, but a bottom `safeAreaInset` has its background extended to the
    /// window edges the way a toolbar's is — which ran the material out under the floating
    /// sidebar and read as the two overlapping.
    /// - Parameter leadingInset: how far in the bars should start. Non-zero only in the iPad
    ///   sidebar layout, where the detail column spans the whole window beneath a floating
    ///   sidebar, so an un-inset bar would run underneath it.
    func withPersistentBars(
        onShowNowPlaying: @escaping () -> Void,
        leadingInset: CGFloat = 0
    ) -> some View {
        // spacing: 0 — the default inserts padding between the content and the inset view,
        // which silently made each bar occupy more room than its own height and left the last
        // row tucked under it by exactly that much.
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(onTap: onShowNowPlaying)
                .padding(.leading, leadingInset)
                .clipped()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActiveSourceBar()
                .padding(.leading, leadingInset)
                .clipped()
                // Applied after the clip so it isn't cut: the bar's own background stops at its
                // bounds, which would leave list content showing through the home-indicator
                // strip beneath it. This fills that strip, and only downward — the width stays
                // the bar's, so it still can't reach under the sidebar.
                .background {
                    Color(.systemBackground)
                        .ignoresSafeArea(edges: .bottom)
                }
        }
    }
}
