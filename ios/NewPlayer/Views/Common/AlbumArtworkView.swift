import SwiftData
import SwiftUI

enum ArtworkDisplaySize {
    /// List rows and the mini player.
    case thumbnail
    /// The album header and the full-screen player.
    case full
}

/// Displays an album's artwork at the appropriate stored size, triggering an on-demand fetch
/// from the MPD server (via MPDArtworkFetcher) if this is a network-sourced album whose art
/// hasn't been downloaded yet. No-op for local albums (artwork is resolved at scan time) and
/// for network albums that already have art cached.
struct AlbumArtworkView: View {
    let album: Album
    var size: ArtworkDisplaySize = .thumbnail
    var cornerRadius: CGFloat = 6

    @Environment(\.modelContext) private var modelContext
    @Environment(\.artworkScope) private var artworkScope

    /// Falls back to the other stored size when one is missing — albums synced before covers
    /// were stored at two sizes only have the full image.
    private var imageData: Data? {
        switch size {
        case .thumbnail: return album.thumbnail ?? album.artwork
        case .full: return album.artwork ?? album.thumbnail
        }
    }

    var body: some View {
        ArtworkImageView(data: imageData, cornerRadius: cornerRadius)
            .task(id: album.persistentModelID) {
                // Two ways a cover arrives late: pulled from an MPD server over its binary
                // protocol, or downloaded from a URL the sync recorded (Spotify).
                if album.artworkURL != nil {
                    RemoteArtworkFetcher.shared.fetchIfNeeded(
                        album: album,
                        modelContext: modelContext,
                        scope: artworkScope
                    )
                } else {
                    MPDArtworkFetcher.shared.fetchIfNeeded(
                        album: album,
                        modelContext: modelContext,
                        scope: artworkScope
                    )
                }
            }
    }
}
