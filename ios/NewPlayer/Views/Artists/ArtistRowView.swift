import SwiftData
import SwiftUI

struct ArtistRowView: View {
    let artist: Artist

    @Environment(\.modelContext) private var modelContext

    // Queried directly rather than via `artist.albums.first` for the same reason
    // MPDArtworkFetcher queries Song directly instead of `album.songs.first` — see its
    // header comment. Avoids depending on a to-many relationship array that may have been
    // faulted in (and cached empty) before all of an artist's albums existed yet.
    private var representativeAlbum: Album? {
        let artistID = artist.persistentModelID
        let predicate = #Predicate<Album> { $0.artist?.persistentModelID == artistID }
        var descriptor = FetchDescriptor<Album>(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    var body: some View {
        HStack(spacing: 12) {
            if let representativeAlbum {
                AlbumArtworkView(album: representativeAlbum)
                    .frame(width: 40, height: 40)
            } else {
                ArtworkImageView(data: nil)
                    .frame(width: 40, height: 40)
            }
            Text(artist.name)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
