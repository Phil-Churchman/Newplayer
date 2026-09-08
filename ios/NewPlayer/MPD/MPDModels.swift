import Foundation

struct MPDStatus: Equatable {
    var state: String // "play", "pause", or "stop"
    var elapsed: TimeInterval
    var duration: TimeInterval
    /// 0-based position in MPD's queue, from the `song:` status field.
    var songPosition: Int?
    /// True while the server is rescanning its own music directory (the `updating_db` status
    /// field is only present at all while a database update job is running).
    var isUpdatingDatabase: Bool
    /// MPD's queue version counter (the `playlist:` status field) — it increments every time
    /// the server's queue changes, from any client. Comparing this against the last-seen value
    /// is the standard MPD-client way to know when to re-fetch the full queue rather than
    /// assuming a locally-tracked mirror is still accurate.
    var playlistVersion: Int? = nil
}

struct MPDSongInfo: Equatable {
    var file: String
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var track: Int?
    var duration: TimeInterval
}

enum MPDError: Error, Equatable {
    case notConnected
    case connectionFailed(String)
    case serverError(String)
    case malformedResponse
    case timedOut
}
