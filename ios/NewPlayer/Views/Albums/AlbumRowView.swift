import SwiftUI

struct AlbumRowView: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtworkView(album: album)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .lineLimit(1)
                if let artistName = album.artist?.name {
                    Text(artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
