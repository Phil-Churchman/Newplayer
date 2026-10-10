import SwiftUI

struct MiniPlayerBar: View {
    @Environment(PlaybackManager.self) private var playback
    let onTap: () -> Void

    var body: some View {
        // The same authority the full player uses, so the two can't disagree about what is
        // playing — and so a Spotify track with no library row still shows here.
        if let item = playback.nowPlayingItem {
            HStack(spacing: 12) {
                NowPlayingArtworkView(item: item, cornerRadius: 4)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                Button {
                    playback.skipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
            }
            .padding(.horizontal, LayoutMetrics.horizontalPadding)
            .frame(height: PersistentBarMetrics.miniPlayerHeight)
            .background(.thinMaterial)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
        }
    }
}
