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

    var body: some View {
        Group {
            if songs.isEmpty {
                EmptyLibraryView()
            } else {
                AlphabetIndexList(items: songs, sectionKey: { $0.title }) { song in
                    SongRowView(song: song, isCurrent: playback.isCurrent(song))
                        .onTapGesture {
                            playback.playNow(song)
                        }
                }
            }
        }
        .navigationTitle("Songs")
        .artworkScope(artworkScope)
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
