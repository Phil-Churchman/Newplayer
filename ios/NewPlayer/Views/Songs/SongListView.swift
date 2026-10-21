import SwiftData
import SwiftUI

struct SongListView: View {
    @State private var artworkScope = UUID()
    @Query private var songs: [Song]

    /// Built in `init` from the active source's id so the query changes identity when the
    /// source does — see SourceScopedQuery for why filtering on `source.isActive` didn't
    /// refresh when switching modes.
    init(activeSourceID: PersistentIdentifier?) {
        _songs = Query(
            filter: SourceScopedQuery.songs(inSourceWithID: activeSourceID),
            sort: [SortDescriptor(\Song.title)]
        )
    }
    @Environment(PlaybackManager.self) private var playback
    @State private var searchText = ""
    @State private var isSearching = false

    /// Matched on what the row shows: the title and the artist.
    private var visibleSongs: [Song] {
        guard LibrarySearch.isActive(searchText) else { return songs }
        return songs.filter { LibrarySearch.matches(searchText, in: [$0.title, $0.artist]) }
    }

    var body: some View {
        Group {
            if songs.isEmpty {
                EmptyLibraryView()
            } else if visibleSongs.isEmpty {
                NoSearchResultsView(query: searchText)
            } else {
                AlphabetIndexList(items: visibleSongs, sectionKey: { $0.title }) { song in
                    SongRowView(song: song, isCurrent: playback.isCurrent(song))
                        .onTapGesture {
                            playback.playNow(song)
                        }
                }
            }
        }
        .navigationTitle("Songs")
        .librarySearchable(text: $searchText, isPresented: $isSearching, prompt: "Songs and artists")
        .artworkScope(artworkScope)
    }
}

/// Shown when a search matches nothing, so an empty list is explained rather than looking like
/// a library that has gone missing.
struct NoSearchResultsView: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView(
            "No Songs",
            systemImage: "music.note.list",
            description: Text("Add a music folder from the Sources tab to get started.")
        )
    }
}
