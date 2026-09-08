import SwiftData
import SwiftUI

struct MainTabView: View {
    let activeSourceID: PersistentIdentifier?
    let availability: LibraryAvailability
    let onShowNowPlaying: () -> Void

    // Only Artists and Albums can push detail screens, and those pushed views hold a direct
    // reference to a specific Album/Artist. Switching source has to pop them, or they keep
    // rendering the previous mode's content from relationships no matter how the root list is
    // scoped. Bound paths are used rather than `.id()` on the tabs: a TabView without an
    // explicit selection tracks its tabs by child identity, so giving several tabs the same
    // id collapses them together and every selection lands on the first one.
    @State private var artistsPath = NavigationPath()
    @State private var albumsPath = NavigationPath()

    var body: some View {
        TabView {
            NavigationStack {
                ActiveSourceGate(title: "Songs", availability: availability) {
                    LibraryRebuildGate {
                        HostSyncGate {
                            SongListView(activeSourceID: activeSourceID)
                        }
                    }
                }
            }
            .withPersistentBars(onShowNowPlaying: onShowNowPlaying)
            .tabItem { Label("Songs", systemImage: "music.note") }

            NavigationStack(path: $artistsPath) {
                ActiveSourceGate(title: "Artists", availability: availability) {
                    LibraryRebuildGate {
                        HostSyncGate {
                            ArtistListView(activeSourceID: activeSourceID, path: $artistsPath)
                        }
                    }
                }
            }
            .withPersistentBars(onShowNowPlaying: onShowNowPlaying)
            .tabItem { Label("Artists", systemImage: "person.wave.2") }

            NavigationStack(path: $albumsPath) {
                ActiveSourceGate(title: "Albums", availability: availability) {
                    LibraryRebuildGate {
                        HostSyncGate {
                            AlbumListView(activeSourceID: activeSourceID, path: $albumsPath)
                        }
                    }
                }
            }
            .withPersistentBars(onShowNowPlaying: onShowNowPlaying)
            .tabItem { Label("Albums", systemImage: "square.stack") }

            NavigationStack {
                ActiveSourceGate(title: "Queue", availability: availability) {
                    LibraryRebuildGate {
                        HostSyncGate {
                            QueueView()
                        }
                    }
                }
            }
            .withPersistentBars(onShowNowPlaying: onShowNowPlaying)
            .tabItem { Label("Queue", systemImage: "list.bullet") }

            NavigationStack {
                SourcesView()
            }
            .withPersistentBars(onShowNowPlaying: onShowNowPlaying)
            .tabItem { Label("Sources", systemImage: "externaldrive") }
        }
        .onChange(of: activeSourceID) { _, _ in
            artistsPath = NavigationPath()
            albumsPath = NavigationPath()
        }
    }
}
