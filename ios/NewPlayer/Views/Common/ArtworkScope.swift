import SwiftUI

/// Identifies which screen an artwork request came from, so the fetcher can drop a previous
/// screen's queued requests when you navigate somewhere else instead of draining a backlog for
/// rows you can no longer see.
///
/// Deliberately driven by the requests themselves rather than by `onAppear`/`onDisappear`:
/// SwiftUI doesn't guarantee that a departing screen's `onDisappear` runs before the arriving
/// screen's rows start requesting, so hooking those could purge the *new* screen's requests.
/// Whichever screen most recently asked for artwork is by definition the active one.
private struct ArtworkScopeKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var artworkScope: UUID? {
        get { self[ArtworkScopeKey.self] }
        set { self[ArtworkScopeKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as its own artwork-loading scope. Apply to each screen that displays
    /// artwork; persistent chrome (mini player) deliberately leaves it unset so it never
    /// cancels the browsing screen's queue.
    func artworkScope(_ scope: UUID) -> some View {
        environment(\.artworkScope, scope)
    }
}
