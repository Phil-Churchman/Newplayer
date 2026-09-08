import SwiftData
import SwiftUI

struct ArtistListView: View {
    @State private var artworkScope = UUID()
    @Query private var artists: [Artist]
    @Binding private var path: NavigationPath

    /// Built in `init` from the active source's id so the query changes identity when the
    /// source does — see SourceScopedQuery for why filtering on `source.isActive` didn't
    /// refresh when switching modes.
    init(activeSourceID: PersistentIdentifier?, path: Binding<NavigationPath>) {
        _path = path
        _artists = Query(
            filter: SourceScopedQuery.artists(inSourceWithID: activeSourceID),
            sort: [SortDescriptor(\Artist.name)]
        )
    }

    var body: some View {
        Group {
            if artists.isEmpty {
                EmptyLibraryView()
            } else {
                AlphabetIndexList(items: artists, sectionKey: { $0.name }) { artist in
                    // A Button pushing onto the bound path rather than a NavigationLink:
                    // inside a List, NavigationLink draws a disclosure chevron, which sits
                    // right under the alphabet rail and crowds it.
                    Button {
                        path.append(artist)
                    } label: {
                        ArtistRowView(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Artists")
        .artworkScope(artworkScope)
        .navigationDestination(for: Artist.self) { artist in
            ArtistAlbumListView(artist: artist)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumSongListView(album: album)
        }
    }
}
