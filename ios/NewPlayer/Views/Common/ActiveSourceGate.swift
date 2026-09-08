import SwiftData
import SwiftUI

/// Shown in place of the library screens when there is nothing to browse. The two cases are
/// deliberately distinct: "you haven't chosen a source" and "you have, but it holds nothing yet"
/// call for entirely different actions, and one message covering both told the user neither.
struct NoLibraryView: View {
    let availability: LibraryAvailability

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }
    }

    private var title: String {
        switch availability {
        case .noSourceSelected, .ready: return "Please Select Source"
        case .selectedSourceEmpty: return "Please Load Content for Selected Source"
        }
    }

    private var icon: String {
        switch availability {
        case .noSourceSelected, .ready: return "externaldrive.badge.questionmark"
        case .selectedSourceEmpty: return "arrow.down.circle"
        }
    }

    private var detail: String {
        switch availability {
        case .noSourceSelected, .ready:
            return "Turn on a source in the Sources tab to start browsing."
        case .selectedSourceEmpty:
            return "Open the Sources tab to choose a folder, connect a host, or sync this source."
        }
    }
}

/// Wraps a screen so it defers to `NoLibraryView` until there is a library to show. Applied to
/// every screen except Sources, which is where a source gets chosen and loaded.
struct ActiveSourceGate<Content: View>: View {
    /// The screen's own title. The gate stands in for content that sets its own
    /// `navigationTitle`, so without this the tab loses its name exactly when the user is being
    /// asked to go and do something — and has least idea where they are.
    let title: String
    let availability: LibraryAvailability
    @ViewBuilder let content: () -> Content

    var body: some View {
        if availability == .ready {
            content()
        } else {
            NoLibraryView(availability: availability)
                .navigationTitle(title)
        }
    }
}
