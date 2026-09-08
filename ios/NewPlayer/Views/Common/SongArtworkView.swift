import SwiftUI

/// Convenience wrapper around AlbumArtworkView for the many places a Song (rather than an
/// Album directly) is what's on hand — Queue, mini player, Now Playing, the flat Songs list.
/// Artwork lives on the album, so every song in an album shares one downloaded cover.
struct SongArtworkView: View {
    let song: Song
    var size: ArtworkDisplaySize = .thumbnail
    var cornerRadius: CGFloat = 6

    var body: some View {
        if let album = song.album {
            AlbumArtworkView(album: album, size: size, cornerRadius: cornerRadius)
        } else {
            ArtworkImageView(data: nil, cornerRadius: cornerRadius)
        }
    }
}
