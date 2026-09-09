import AVFoundation
import Foundation
import MediaPlayer

/// One track as it exists in the device's Music (iTunes) library.
///
/// Carries no artwork of its own. Covers are large and only one per album is ever kept, so they
/// are fetched separately, by ID, for just the first track of each album — see
/// `MediaLibraryProviding.artworkData(forPersistentID:)`.
struct MediaLibraryTrack {
    /// The library's own stable identifier, stored as the song's `relativePath`. Asset URLs are
    /// not durable across syncs and library edits, so the ID is what gets persisted and the URL
    /// is looked up again at the moment of playback.
    var persistentID: String
    /// The library's own album grouping. Used in preference to the album title so that two
    /// different releases sharing a name aren't merged, and so "first track in the album" means
    /// the album iTunes says it is.
    var albumPersistentID: String
    var title: String?
    var artist: String?
    var albumTitle: String?
    var albumArtist: String?
    var trackNumber: Int
    var duration: TimeInterval
    /// False for anything this app can't play: DRM-protected tracks, and tracks not downloaded
    /// to the device. Those are skipped rather than imported as rows that fail silently on tap.
    var isPlayableLocally: Bool
}

enum MediaLibraryAccess: Equatable {
    case authorized
    case denied
    case restricted
}

@MainActor
protocol MediaLibraryProviding {
    func currentAccess() -> MediaLibraryAccess?
    func requestAccess() async -> MediaLibraryAccess
    func fetchTracks() -> [MediaLibraryTrack]
    /// Renders one track's cover. Looked up by ID at the moment it's needed rather than carried
    /// on the track: an earlier version captured the MPMediaItemArtwork in a closure, and since
    /// nothing else retained that autoreleased object it was gone by the time the closure ran,
    /// so every album silently imported without a cover.
    func artworkData(forPersistentID persistentID: String) -> Data?
    /// Resolved at playback time — see `MediaLibraryTrack.persistentID`.
    func assetURL(forPersistentID persistentID: String) -> URL?
    /// Whether the asset actually opens.
    ///
    /// `assetURL != nil` and `hasProtectedAsset == false` are Apple's own signals and cost
    /// nothing, but they are answered from the library's metadata rather than from the file.
    /// This asks AVFoundation to look, which catches the cases metadata can't: an encoding it
    /// won't decode, or a download the system has since evicted.
    func isPlayable(persistentID: String) async -> Bool
}

/// The real thing, over MediaPlayer's MPMediaLibrary.
@MainActor
final class SystemMediaLibrary: MediaLibraryProviding {
    /// Items from the last `fetchTracks`, so the import's per-album cover lookups don't each run
    /// a fresh query. Playback happens long after that and falls back to querying by ID.
    private var itemsByID: [String: MPMediaItem] = [:]

    /// Nil when the user hasn't been asked yet.
    func currentAccess() -> MediaLibraryAccess? {
        switch MPMediaLibrary.authorizationStatus() {
        case .notDetermined: return nil
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> MediaLibraryAccess {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                let access: MediaLibraryAccess
                switch status {
                case .authorized: access = .authorized
                case .restricted: access = .restricted
                default: access = .denied
                }
                continuation.resume(returning: access)
            }
        }
    }

    /// Whether a track can actually be played by this app.
    ///
    /// Two conditions, and only these two:
    ///
    /// - There must be a local asset to open. `assetURL` is nil for anything not downloaded to
    ///   the device, which is what "not locally stored" amounts to.
    /// - It must not be DRM-protected. Apple Music's own tracks are, and AVPlayer cannot open
    ///   them however they got here.
    ///
    /// Note what is deliberately *not* tested: `isCloudItem`. That is true of anything in your
    /// iCloud Music Library including tracks you have downloaded, which play perfectly well —
    /// filtering on it excluded music that works.
    static func isPlayableLocally(assetURL: URL?, hasProtectedAsset: Bool) -> Bool {
        assetURL != nil && !hasProtectedAsset
    }

    func fetchTracks() -> [MediaLibraryTrack] {
        // No filter predicate: everything is fetched and judged below, so unplayable tracks can
        // be counted and reported rather than disappearing before anyone notices.
        let items = MPMediaQuery.songs().items ?? []
        itemsByID = Dictionary(items.map { (String($0.persistentID), $0) }, uniquingKeysWith: { first, _ in first })

        return items.map { item in
            MediaLibraryTrack(
                persistentID: String(item.persistentID),
                albumPersistentID: String(item.albumPersistentID),
                title: item.title,
                artist: item.artist,
                albumTitle: item.albumTitle,
                albumArtist: item.albumArtist,
                trackNumber: item.albumTrackNumber,
                duration: item.playbackDuration,
                isPlayableLocally: Self.isPlayableLocally(
                    assetURL: item.assetURL,
                    hasProtectedAsset: item.hasProtectedAsset
                )
            )
        }
    }

    func artworkData(forPersistentID persistentID: String) -> Data? {
        guard let artwork = item(withPersistentID: persistentID)?.artwork else { return nil }

        // Ask for the artwork's own size rather than a fixed 1024: requesting more than it holds
        // gains nothing, and ArtworkProcessor downscales anyway. Capped so an unusually large
        // cover doesn't allocate a huge bitmap just to be shrunk.
        let natural = artwork.bounds.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let longestSide = max(natural.width, natural.height)
        let scale = longestSide > ArtworkProcessor.fullDimension ? ArtworkProcessor.fullDimension / longestSide : 1
        let target = CGSize(width: natural.width * scale, height: natural.height * scale)

        return artwork.image(at: target)?.jpegData(compressionQuality: 0.9)
    }

    private func item(withPersistentID persistentID: String) -> MPMediaItem? {
        if let cached = itemsByID[persistentID] { return cached }
        guard let id = UInt64(persistentID) else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: id),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        return query.items?.first
    }

    func assetURL(forPersistentID persistentID: String) -> URL? {
        item(withPersistentID: persistentID)?.assetURL
    }

    func isPlayable(persistentID: String) async -> Bool {
        guard let url = assetURL(forPersistentID: persistentID) else { return false }
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }
}
