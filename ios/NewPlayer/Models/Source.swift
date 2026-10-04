import Foundation
import SwiftData

enum SourceKind: Int, Codable {
    /// A folder the user picked, reached through a security-scoped bookmark.
    case local
    /// An MPD server; playback happens on the server.
    case network
    /// The device's own Music (iTunes) library, addressed by persistent ID.
    case mediaLibrary
    /// A Spotify account's saved library, read over the Web API. Metadata only — see
    /// SpotifyImportService for why these tracks can be browsed but not played here.
    case spotify
}

@Model
final class Source {
    var name: String
    var host: String = ""
    var port: Int = 6600
    var isActive: Bool = false
    var bookmarkData: Data?
    var bookmarkDisplayName: String?
    var lastSyncStatusRaw: Int = SyncStatus.idle.rawValue
    var lastSyncDate: Date?
    var kindRaw: Int = SourceKind.local.rawValue
    /// The Spotify application's client ID, from the user's own Spotify developer dashboard.
    /// An app can't ship one: it is tied to the redirect URI registered against it.
    var spotifyClientID: String = ""
    /// The signed-in account's display name, shown so it's clear whose library this is.
    var spotifyAccountName: String?
    /// The Connect device the user picked to play on. Nil means "whichever one is available",
    /// which is what the app works out for itself.
    var spotifyDeviceID: String?
    /// Drives Spotify without the network: commands go straight to the Spotify app on this
    /// phone instead of out to Spotify Connect, and the state poll stops.
    ///
    /// Deliberate rather than inferred from reachability. "Online" is not the same question as
    /// "will Spotify play this", and a flaky connection flipping the app's behaviour unasked is
    /// worse than being told.
    var isOfflineMode: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Artist.source)
    var artists: [Artist] = []

    @Relationship(deleteRule: .cascade, inverse: \Album.source)
    var albums: [Album] = []

    @Relationship(deleteRule: .cascade, inverse: \Song.source)
    var songs: [Song] = []

    var lastSyncStatus: SyncStatus {
        get { SyncStatus(rawValue: lastSyncStatusRaw) ?? .idle }
        set { lastSyncStatusRaw = newValue.rawValue }
    }

    var kind: SourceKind {
        get { SourceKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    init(name: String, host: String = "", port: Int = 6600, isActive: Bool = false, kind: SourceKind = .local) {
        self.name = name
        self.host = host
        self.port = port
        self.isActive = isActive
        self.kindRaw = kind.rawValue
    }
}
