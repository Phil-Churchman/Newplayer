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

    /// How long a row must stay on screen before its cover is asked for.
    ///
    /// Rows flicked past during a fast scroll are never queued at all: SwiftUI cancels this
    /// `task` when the row goes away, so the wait below simply never finishes for them. Only
    /// rows the user has actually come to rest on reach the fetcher — which keeps the decode,
    /// the save and the resulting view invalidations out of the middle of a scroll, where they
    /// showed as judder.
    ///
    /// A settle delay rather than a scroll-phase check: `onScrollPhaseChange` is iOS 18, and
    /// this app targets 17. The effect is the same and it needs nothing from the scroll view.
    private static let settleDelayNanoseconds: UInt64 = 300_000_000

    var body: some View {
        ArtworkImageView(data: imageData, cornerRadius: cornerRadius)
            .task(id: album.persistentModelID) {
                guard imageData == nil else { return }
                try? await Task.sleep(nanoseconds: Self.settleDelayNanoseconds)
                guard !Task.isCancelled else { return }

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
