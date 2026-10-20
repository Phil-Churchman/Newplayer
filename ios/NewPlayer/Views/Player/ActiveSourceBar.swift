import SwiftData
import SwiftUI

/// Small persistent bar above the tab bar showing whether Local or a Remote (MPD) source is
/// currently active, so it's always obvious which one playback commands are going to.
struct ActiveSourceBar: View {
    @Query private var sources: [Source]

    private var activeSource: Source? {
        sources.first { $0.isActive }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
            Text(label)
                .font(.caption2.weight(.medium))
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LayoutMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PersistentBarMetrics.sourceBarHeight)
        // Painted in the page background colour rather than a material: the bar is chrome, not a
        // surface, and any tint made it read as a shaded strip across the bottom of every screen.
        // Opaque rather than clear, because list content still scrolls behind the inset.
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeSourceBar")
    }

    private var iconName: String {
        switch activeSource?.kind {
        case .local: return "folder"
        case .mediaLibrary: return "music.note.house"
        case .spotify: return "waveform.circle"
        case .network: return "network"
        case nil: return "questionmark.circle"
        }
    }

    /// The same names the Sources tab uses for its switches. They were the app's own words
    /// before — "Local Folder", "Music Library", "Remote" — so the bar named a source the
    /// Sources screen did not, and the two had to be matched up by the reader.
    private var label: String {
        guard let activeSource else { return "No active source" }
        switch activeSource.kind {
        case .local:
            return "Local files"
        case .mediaLibrary:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        case .network:
            // The host is kept: it is the one source where *which* one matters.
            return "MPD — \(activeSource.host):\(activeSource.port)"
        }
    }
}
