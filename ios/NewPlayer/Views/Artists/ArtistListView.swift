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

    @State private var searchText = ""
    @State private var isSearching = false

    private var visibleArtists: [Artist] {
        guard LibrarySearch.isActive(searchText) else { return artists }
        return artists.filter { LibrarySearch.matches(searchText, in: [$0.name]) }
    }

    var body: some View {
        Group {
            if artists.isEmpty {
                EmptyLibraryView()
            } else if visibleArtists.isEmpty {
                NoSearchResultsView(query: searchText)
            } else {
                AlphabetIndexList(items: visibleArtists, sectionKey: { $0.name }) { artist in
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
        .librarySearchable(text: $searchText, isPresented: $isSearching, prompt: "Artists")
        .artworkScope(artworkScope)
        .navigationDestination(for: Artist.self) { artist in
            ArtistAlbumListView(artist: artist)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumSongListView(album: album)
        }
    }
}
