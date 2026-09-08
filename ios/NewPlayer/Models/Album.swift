import Foundation
import SwiftData

@Model
final class Album {
    var name: String
    /// Full-size cover for the player (see ArtworkProcessor.fullDimension).
    @Attribute(.externalStorage) var artwork: Data?
    /// Small cover for list rows and the mini player, so scrolling doesn't decode the
    /// full-size image once per visible row.
    @Attribute(.externalStorage) var thumbnail: Data?
    /// Where the cover can be downloaded from, for sources that publish one over HTTP (Spotify).
    /// Kept so artwork need not be fetched during a sync: downloading and decoding hundreds of
    /// covers while importing makes every re-sync as slow as the first and holds them all in
    /// memory at once.
    var artworkURL: String?
    var artist: Artist?
    var source: Source?

    @Relationship(deleteRule: .cascade, inverse: \Song.album)
    var songs: [Song] = []

    init(
        name: String,
        artwork: Data? = nil,
        thumbnail: Data? = nil,
        artworkURL: String? = nil,
        artist: Artist? = nil,
        source: Source? = nil
    ) {
        self.name = name
        self.artwork = artwork
        self.thumbnail = thumbnail
        self.artworkURL = artworkURL
        self.artist = artist
        self.source = source
    }

    /// Applies a freshly processed cover to both stored sizes.
    func apply(_ processed: ArtworkProcessor.Processed) {
        artwork = processed.full
        thumbnail = processed.thumbnail
    }
}
