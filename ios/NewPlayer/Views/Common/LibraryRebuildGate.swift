import SwiftUI

/// Shown in place of the library screens while a source's rows are being replaced.
struct LibraryRebuildingView: View {
    let processed: Int
    let total: Int

    var body: some View {
        ContentUnavailableView {
            Label("Updating Library", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            if total > 0 {
                Text("\(processed) of \(total) tracks")
            } else {
                Text("Please wait…")
            }
        }
    }
}

/// Keeps `@Query`-backed screens from re-fetching thousands of rows on every intermediate save
/// of a rebuild. Applied to every screen except Sources, which reports the sync itself.
struct LibraryRebuildGate<Content: View>: View {
    @State private var state = LibraryRebuildState.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        if state.isRebuilding {
            LibraryRebuildingView(processed: state.processed, total: state.total)
        } else {
            content()
        }
    }
}
