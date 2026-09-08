import SwiftUI

struct SourceRowView: View {
    let source: Source
    let isActive: Bool
    let progress: LibrarySyncProgress?
    let onRescan: () -> Void

    private var statusText: String {
        switch source.lastSyncStatus {
        case .idle: return "Not synced yet"
        case .syncing:
            if let progress {
                return "Syncing… \(progress.processed) / \(progress.total) tracks"
            }
            return "Syncing…"
        case .success:
            let songCount = source.songs.count
            let songsPart = "\(songCount) song\(songCount == 1 ? "" : "s")"
            if let date = source.lastSyncDate {
                return "\(songsPart) — synced \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return songsPart
        case .failed: return "Sync failed"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                if source.kind == .network {
                    // `verbatim:` matters here — interpolating an Int into a Text string
                    // literal makes it a LocalizedStringKey, which formats numbers for the
                    // locale and renders port 6600 as "6,600".
                    Text(verbatim: "\(source.host):\(source.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let folderName = source.bookmarkDisplayName {
                    Text(folderName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(source.lastSyncStatus == .failed ? .red : .secondary)
            }
            Spacer()
            if source.lastSyncStatus == .syncing {
                ProgressView()
            } else {
                // No "Use" button: the switch above this row is what selects a source now,
                // so a second control for the same thing could only contradict it.
                Button(action: onRescan) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
