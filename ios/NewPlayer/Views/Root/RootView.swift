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
            // Gated as well as unreachable: the mini player is the only way to open this, and
            // it is hidden offline — but a mode switch while the player is open would otherwise
            // leave it up with nothing behind it.
            .fullScreenCover(isPresented: Binding(
                get: { showNowPlaying && playback.isPlayerAvailable },
                set: { showNowPlaying = $0 }
            )) {
                NowPlayingView {
                    showNowPlaying = false
                }
            }
            .task {
                await autoScanIfNeeded()
            }
            // Offered as a choice rather than reported as text. Spotify's own words describe
            // its world — "Restriction violated", "The Internet connection appears to be
            // offline" — and name nothing the user can do from here. Each of these two does.
            .alert(
                playback.spotifyPrompt?.title ?? "",
                isPresented: Binding(
                    get: { playback.spotifyPrompt != nil },
                    set: { if !$0 { playback.dismissSpotifyPrompt() } }
                ),
                presenting: playback.spotifyPrompt
            ) { prompt in
                Button(prompt.confirmTitle) { apply(prompt) }
                Button("Not now", role: .cancel) { playback.dismissSpotifyPrompt() }
            } message: { prompt in
                Text(prompt.detail)
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

    /// Carries out what the prompt offered.
    ///
    /// Both halves have to be written through to the Source as well as to the player: the
    /// pinned device and the offline switch are stored there, and a change only the player knew
    /// about would be undone by the next launch.
    private func apply(_ prompt: PlaybackManager.SpotifyPrompt) {
        playback.dismissSpotifyPrompt()
        guard let source = activeSource else { return }
        switch prompt {
        case .staleConnection:
            source.spotifyDeviceID = nil
            try? modelContext.save()
            playback.resetSpotifyDevices()
        case .offline:
            source.isOfflineMode = true
            try? modelContext.save()
            playback.setSpotifyOfflineMode(true)
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
