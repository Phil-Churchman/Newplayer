import SwiftUI

/// The cover for whatever is playing: from the library row when there is one, and from Spotify's
/// own image URL when the track has no row here.
///
/// The URL case cannot go through `RemoteArtworkFetcher`, which stores what it downloads onto an
/// Album row — there is no row to store it on. It is fetched for display only.
struct NowPlayingArtworkView: View {
    let item: PlaybackManager.NowPlayingItem
    var size: ArtworkDisplaySize = .thumbnail
    var cornerRadius: CGFloat = 6

    var body: some View {
        switch item {
        case .song(let song):
            SongArtworkView(song: song, size: size, cornerRadius: cornerRadius)
        case .spotifyTrack(let entry):
            AsyncImage(url: entry.artworkURL.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    // Same arrangement as ArtworkImageView, and for the same reason: sizing the
                    // image itself with `.fill` reports a size larger than the box for any cover
                    // that isn't square, which widens whatever is laid out beside it.
                    Color.clear
                        .overlay { image.resizable().aspectRatio(contentMode: .fill) }
                } else {
                    // Covers loading and failure alike: the placeholder is what an album with no
                    // cover already shows, so a slow image looks like the rest of the app.
                    ArtworkImageView(data: nil, cornerRadius: cornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
