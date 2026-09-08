import SwiftUI

/// A row in Spotify's own queue. Draws from what Spotify reports rather than from a library row,
/// since the queue routinely holds tracks that were never imported here.
struct SpotifyQueueRowView: View {
    let entry: SpotifyQueueEntry
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtworkThumbnail(urlString: entry.artworkURL)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Text(entry.artist)
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

/// Loads a cover straight from its URL. Queue entries aren't library rows, so there is no Album
/// to hang stored artwork on — and the queue turns over often enough that caching it would be
/// storing images for tracks about to disappear.
struct RemoteArtworkThumbnail: View {
    let urlString: String?

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }
}
