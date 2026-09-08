import SwiftData
import SwiftUI

struct AlbumListView: View {
    @State private var artworkScope = UUID()
    @Query private var albums: [Album]
    @Binding private var path: NavigationPath

    /// Built in `init` from the active source's id so the query changes identity when the
    /// source does — see SourceScopedQuery for why filtering on `source.isActive` didn't
    /// refresh when switching modes.
    init(activeSourceID: PersistentIdentifier?, path: Binding<NavigationPath>) {
        _path = path
        _albums = Query(
            filter: SourceScopedQuery.albums(inSourceWithID: activeSourceID),
            sort: [SortDescriptor(\Album.name)]
        )
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                EmptyLibraryView()
            } else {
                AlphabetIndexList(items: albums, sectionKey: { $0.name }) { album in
                    // A Button pushing onto the bound path rather than a NavigationLink:
                    // inside a List, NavigationLink draws a disclosure chevron, which sits
                    // right under the alphabet rail and crowds it.
                    Button {
                        path.append(album)
                    } label: {
                        AlbumRowView(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Albums")
        .artworkScope(artworkScope)
        .navigationDestination(for: Album.self) { album in
            AlbumSongListView(album: album)
        }
    }
}
