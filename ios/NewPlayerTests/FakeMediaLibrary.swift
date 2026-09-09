import Foundation
@testable import NewPlayer

/// Stands in for the device's Music library. The real one can't be populated in a simulator, so
/// everything above MediaPlayer is exercised through this.
@MainActor
final class FakeMediaLibrary: MediaLibraryProviding {
    var access: MediaLibraryAccess?
    var accessAfterRequest: MediaLibraryAccess = .authorized
    var tracks: [MediaLibraryTrack] = []
    var assetURLs: [String: URL] = [:]
    private(set) var requestCount = 0
    private(set) var artworkRenderCount = 0
    /// Track IDs the importer asked covers for, in order.
    private(set) var artworkRequests: [String] = []
    private var artworkByTrackID: [String: Data] = [:]

    init(access: MediaLibraryAccess? = .authorized) {
        self.access = access
    }

    func currentAccess() -> MediaLibraryAccess? { access }

    func requestAccess() async -> MediaLibraryAccess {
        requestCount += 1
        access = accessAfterRequest
        return accessAfterRequest
    }

    func fetchTracks() -> [MediaLibraryTrack] { tracks }

    func assetURL(forPersistentID persistentID: String) -> URL? { assetURLs[persistentID] }

    /// Track ids whose asset refuses to open despite the library claiming it is there.
    var unopenableIDs: Set<String> = []
    private(set) var playabilityChecks: [String] = []

    func isPlayable(persistentID: String) async -> Bool {
        playabilityChecks.append(persistentID)
        guard assetURLs[persistentID] != nil else { return false }
        return !unopenableIDs.contains(persistentID)
    }

    func artworkData(forPersistentID persistentID: String) -> Data? {
        artworkRenderCount += 1
        artworkRequests.append(persistentID)
        return artworkByTrackID[persistentID]
    }

    /// Builds a track whose artwork closure records each render, so tests can prove covers
    /// aren't rendered once per track.
    func addTrack(
        id: String,
        title: String,
        artist: String? = "Artist",
        album: String = "Album",
        albumID: String? = nil,
        albumArtist: String? = nil,
        track: Int = 1,
        duration: TimeInterval = 200,
        playable: Bool = true,
        artwork: Data? = nil
    ) {
        tracks.append(MediaLibraryTrack(
            persistentID: id,
            albumPersistentID: albumID ?? album,
            title: title,
            artist: artist,
            albumTitle: album,
            albumArtist: albumArtist ?? artist,
            trackNumber: track,
            duration: duration,
            isPlayableLocally: playable
        ))
        artworkByTrackID[id] = artwork
        if playable {
            assetURLs[id] = URL(string: "ipod-library://item/item.m4a?id=\(id)")!
        }
    }
}
