import SwiftUI

struct ArtistAlbumListView: View {
    @State private var artworkScope = UUID()
    let artist: Artist

    private var albums: [Album] {
        artist.albums.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                EmptyLibraryView()
            } else {
                List(albums) { album in
                    NavigationLink(value: album) {
                        AlbumRowView(album: album)
                    }
                }
                .listStyle(.plain)
                .miniPlayerContentInset()
            }
        }
        .navigationTitle(artist.name)
        .artworkScope(artworkScope)
    }
}
