import SwiftUI

struct MiniPlayerBar: View {
    @Environment(PlaybackManager.self) private var playback
    let onTap: () -> Void

    var body: some View {
        if let song = playback.currentSong {
            HStack(spacing: 12) {
                SongArtworkView(song: song, cornerRadius: 4)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(song.artist)
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
            .padding(.horizontal, 12)
            .frame(height: PersistentBarMetrics.miniPlayerHeight)
            .background(.thinMaterial)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
        }
    }
}
