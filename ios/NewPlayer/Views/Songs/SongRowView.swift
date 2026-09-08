import SwiftUI

struct SongRowView: View {
    let song: Song
    /// Whether this is the track currently loaded in the player — matched by song identity, so
    /// it works the same in local and remote mode (MPD queue entries are resolved back to the
    /// same SwiftData songs these lists are showing).
    var isCurrent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            SongArtworkView(song: song)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                NowPlayingIndicator()
            }
        }
        .contentShape(Rectangle())
    }
}
