import SwiftUI

/// The "this is the track that's playing" treatment, shared by the queue and the library song
/// lists so they can't drift apart. Identity differs between them — the queue marks a *position*
/// (the same song can sit in several slots) while library lists mark a *song* — but the
/// appearance is deliberately identical.
struct NowPlayingIndicator: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .foregroundStyle(Color.accentColor)
            .font(.caption)
            .accessibilityLabel("Now playing")
    }
}
