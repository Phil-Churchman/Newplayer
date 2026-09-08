import Foundation
import SwiftData

@Model
final class Song {
    var title: String
    var artist: String
    var albumTitle: String
    var albumArtist: String
    var track: Int
    var duration: TimeInterval
    /// Path of the audio file relative to its Source's bookmarked root folder.
    var relativePath: String
    var album: Album?
    var source: Source?

    init(
        title: String,
        artist: String,
        albumTitle: String,
        albumArtist: String,
        track: Int,
        duration: TimeInterval,
        relativePath: String,
        album: Album? = nil,
        source: Source? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.track = track
        self.duration = duration
        self.relativePath = relativePath
        self.album = album
        self.source = source
    }
}
