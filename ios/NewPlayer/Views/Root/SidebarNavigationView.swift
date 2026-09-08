import SwiftData
import SwiftUI

/// The five screens, as a sidebar rather than a tab bar.
enum LibrarySection: String, CaseIterable, Identifiable {
    case songs, artists, albums, queue, sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .queue: return "Queue"
        case .sources: return "Sources"
        }
    }

    var icon: String {
        switch self {
        case .songs: return "music.note"
        case .artists: return "person.wave.2"
        case .albums: return "square.stack"
        case .queue: return "list.bullet"
        case .sources: return "externaldrive"
        }
    }
}

/// The iPad (and any regular-width) layout: a persistent sidebar beside the current screen,
/// instead of the phone's tab bar. The screens themselves are the same views the phone uses —
/// only the navigation chrome differs, so there is one implementation of each library screen.
struct SidebarNavigationView: View {
    let activeSourceID: PersistentIdentifier?
    let availability: LibraryAvailability
    let onShowNowPlaying: () -> Void

    @State private var selection: LibrarySection? = .songs
    /// `.all` rather than `.automatic`: binding this at all makes the split view honour the
    /// value, and automatic collapses the sidebar in portrait — which is not what this layout
    /// is for. It is bound only so the bars know whether the sidebar is taking up room.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // As on the phone: a pushed Artist/Album screen holds a specific row, so switching source
    // has to pop it rather than leave it rendering the previous source's content.
    @State private var artistsPath = NavigationPath()
    @State private var albumsPath = NavigationPath()

    var body: some View {
        // The bars sit in their own row below the split view rather than floating over it.
        //
        // Every overlay placement was lost when a screen was pushed — on the stack, on the
        // gated content, on the detail column — because a `safeAreaInset` inside a split view's
        // detail belongs to what is currently showing there. Out here they are a sibling of the
        // whole split view, so nothing inside any column can take them away, they keep their
        // full width, and the sidebar ends above them instead of being overlapped.
        VStack(spacing: 0) {
            splitView
            MiniPlayerBar(onTap: onShowNowPlaying)
            ActiveSourceBar()
        }
        // The bars take their own space here, so lists must not also reserve room for them.
        .environment(\.persistentBarsOverlayContent, false)
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(LibrarySection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("New player")
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: activeSourceID) { _, _ in
            artistsPath = NavigationPath()
            albumsPath = NavigationPath()
        }
    }

    @ViewBuilder
    private var detail: some View {
        // The bars go on each NavigationStack, never on the view inside it. Attached to the root
        // content they belong to that screen, so pushing an artist's albums or an album's songs
        // carried them off with it and the mini player vanished.
        switch selection ?? .songs {
        case .songs:
            NavigationStack {
                gated("Songs") { SongListView(activeSourceID: activeSourceID) }
            }
        case .artists:
            NavigationStack(path: $artistsPath) {
                gated("Artists") { ArtistListView(activeSourceID: activeSourceID, path: $artistsPath) }
            }
        case .albums:
            NavigationStack(path: $albumsPath) {
                gated("Albums") { AlbumListView(activeSourceID: activeSourceID, path: $albumsPath) }
            }
        case .queue:
            NavigationStack {
                gated("Queue") { QueueView() }
            }
        case .sources:
            NavigationStack {
                SourcesView()
            }
        }
    }

    /// Same two gates the phone applies, in the same order: with no source chosen there is
    /// nothing to say about a host sync.
    @ViewBuilder
    private func gated<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ActiveSourceGate(title: title, availability: availability) {
            LibraryRebuildGate {
                HostSyncGate {
                    content()
                }
            }
        }
    }
}
