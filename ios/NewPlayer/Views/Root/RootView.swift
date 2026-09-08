import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Query private var sources: [Source]
    @State private var showNowPlaying = false
    /// Regular width is an iPad (or an iPhone Max in landscape): wide enough for the sidebar
    /// layout, where a tab bar would waste the space and leave the screens stranded in a column.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeSource: Source? {
        SourceSelection.activeSource(among: sources)
    }

    private var availability: LibraryAvailability {
        LibraryAvailability.current(sources: sources, selectedKind: SourceSelection.selectedKind)
    }

    var body: some View {
        layout
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView {
                    showNowPlaying = false
                }
            }
            .task {
                await autoScanIfNeeded()
            }
            .onAppear {
                playback.setActiveSource(activeSource, resolveSong: makeSongResolver(for: activeSource))
            }
            .onChange(of: activeSource) { _, newValue in
                playback.setActiveSource(newValue, resolveSong: makeSongResolver(for: newValue))
            }
    }

    @ViewBuilder
    private var layout: some View {
        if horizontalSizeClass == .regular {
            SidebarNavigationView(
                activeSourceID: activeSource?.persistentModelID,
                availability: availability,
                onShowNowPlaying: { showNowPlaying = true }
            )
        } else {
            MainTabView(
                activeSourceID: activeSource?.persistentModelID,
                availability: availability,
                onShowNowPlaying: { showNowPlaying = true }
            )
        }
    }

    /// Looks up a song by MPD's relative-path file URI within the given source's own songs
    /// each time it's called (not a cached snapshot), so a resync while a network source is
    /// active doesn't leave PlaybackManager resolving against a stale song list.
    private func makeSongResolver(for source: Source?) -> (String) -> Song? {
        { relativePath in
            source?.songs.first { $0.relativePath == relativePath }
        }
    }

    private func autoScanIfNeeded() async {
        for source in sources where source.kind == .local && source.bookmarkData != nil && source.songs.isEmpty {
            await LibraryImportService.rescan(source: source, modelContext: modelContext)
        }
    }
}
