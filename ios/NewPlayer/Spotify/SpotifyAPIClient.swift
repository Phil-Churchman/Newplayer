import Foundation

/// Reads a signed-in account's own saved library. Behind a protocol so the import can be tested
/// without a Spotify account or network.
protocol SpotifyAPIClient: Sendable {
    func fetchAccount(accessToken: String) async throws -> SpotifyAccount
    /// Every saved track, following Spotify's paging to the end.
    func fetchSavedTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack]
    /// Every track on every saved album. A Spotify library is Liked Songs *and* saved albums —
    /// the albums' tracks are not in /me/tracks, so fetching only that misses them entirely.
    func fetchSavedAlbumTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack]
    func fetchArtwork(url: URL) async throws -> Data

    // MARK: - Connect playback
    //
    // Spotify never hands over audio; these drive whichever Spotify client is currently active
    // (typically the Spotify app on this same phone), the way the MPD source drives a server.

    /// Nil when no Spotify client is active — there is then nothing to send commands to.
    func fetchPlayerState(accessToken: String) async throws -> SpotifyPlayerState?
    /// Every device Spotify can see for this account, active or merely available.
    func fetchDevices(accessToken: String) async throws -> [SpotifyDevice]
    /// What Spotify is playing and what it has lined up next — its own "Queue", including
    /// anything queued from the Spotify app itself.
    func fetchPlaybackQueue(accessToken: String) async throws -> SpotifyQueueSnapshot
    /// Starts a specific set of tracks at a position within them. Naming a device both targets
    /// and activates it, which is how an open-but-idle Spotify app is woken.
    func play(trackURIs: [String], startAt index: Int, deviceID: String?, accessToken: String) async throws
    /// Moves this account's playback onto a device, taking it over if another account is using
    /// it — a shared speaker can be visible to several accounts, and a transfer is how Connect
    /// claims one. Naming it in a play command only works on a device that is already ours.
    func transferPlayback(toDeviceID deviceID: String, play: Bool, accessToken: String) async throws
    func resume(deviceID: String?, accessToken: String) async throws
    func pause(deviceID: String?, accessToken: String) async throws
    func skipToNext(deviceID: String?, accessToken: String) async throws
    func skipToPrevious(deviceID: String?, accessToken: String) async throws
    func seek(toMilliseconds position: Int, deviceID: String?, accessToken: String) async throws
}

/// One entry in Spotify's queue.
///
/// Carries its own title and artist because Spotify's queue routinely holds tracks this app has
/// never imported — anything queued from a search, or playing from a context outside your saved
/// library. Those used to be dropped from the mirror, which left the app showing a queue that
/// was a *subset* of the real one.
struct SpotifyQueueEntry: Equatable, Identifiable {
    var trackID: String
    var title: String
    var artist: String
    var artworkURL: String?
    /// Position in the queue, so repeated tracks stay distinct rows.
    var position: Int

    var id: String { "\(position):\(trackID)" }
}

/// Spotify's own queue: the track playing and the ones lined up after it.
struct SpotifyQueueSnapshot: Equatable {
    var currentTrackID: String?
    var entries: [SpotifyQueueEntry]

    var upcomingTrackIDs: [String] {
        entries.dropFirst().map(\.trackID)
    }

    /// The whole thing in playing order.
    var orderedTrackIDs: [String] { entries.map(\.trackID) }
}

struct SpotifyPlayerState: Equatable {
    var isPlaying: Bool
    var progressSeconds: TimeInterval
    var durationSeconds: TimeInterval
    /// The track Spotify says is playing, so the app can follow along when the user changes it
    /// from another device.
    var trackID: String?
    /// The device Spotify is actually playing on — the only way to confirm a transfer took.
    var activeDeviceID: String?
}

struct SpotifyWebAPIClient: SpotifyAPIClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.makeConfiguration())
    }

    /// The session these requests run on.
    ///
    /// Timeouts are explicit: the default session waits a very long time, and a stuck request
    /// part-way through paging a large library looks exactly like the app having hung.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        return configuration
    }

    func fetchAccount(accessToken: String) async throws -> SpotifyAccount {
        struct Profile: Decodable {
            let display_name: String?
            let product: String?
        }
        let profile: Profile = try await get(URL(string: "https://api.spotify.com/v1/me")!, accessToken: accessToken)
        return SpotifyAccount(
            displayName: profile.display_name ?? "Spotify",
            product: profile.product ?? "unknown"
        )
    }

    func fetchSavedTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack] {
        var url: URL? = URL(string: "https://api.spotify.com/v1/me/tracks?limit=50")
        var all: [SpotifyTrack] = []

        while let next = url {
            let page: SavedTracksPage = try await get(next, accessToken: accessToken)
            all.append(contentsOf: page.items.compactMap { $0.track?.asTrack })
            onPage(all.count)
            url = page.next.flatMap(URL.init(string:))
        }
        return all
    }

    func fetchSavedAlbumTracks(accessToken: String, onPage: @Sendable (Int) -> Void) async throws -> [SpotifyTrack] {
        var url: URL? = URL(string: "https://api.spotify.com/v1/me/albums?limit=50")
        var all: [SpotifyTrack] = []

        while let next = url {
            let page: SavedAlbumsPage = try await get(next, accessToken: accessToken)
            for item in page.items {
                guard let album = item.album else { continue }
                all.append(contentsOf: album.tracksAsSpotifyTracks)
            }
            onPage(all.count)
            url = page.next.flatMap(URL.init(string:))
        }
        return all
    }

    func fetchArtwork(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpotifyError.requestFailed("artwork request failed")
        }
        return data
    }

    // MARK: - Connect playback

    func fetchPlayerState(accessToken: String) async throws -> SpotifyPlayerState? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.requestFailed("no response")
        }
        // 204: nothing is playing anywhere, so there is no device to control.
        if http.statusCode == 204 { return nil }
        if http.statusCode == 401 {
            throw SpotifyError.permissionsMissing
        }
        if http.statusCode == 403 {
            throw SpotifyError.actionNotAllowed(Self.reason(in: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.requestFailed("HTTP \(http.statusCode)")
        }

        struct PlayerResponse: Decodable {
            struct Item: Decodable { let id: String? ; let duration_ms: Int? }
            struct Device: Decodable { let id: String? }
            let is_playing: Bool?
            let progress_ms: Int?
            let item: Item?
            let device: Device?
        }
        let decoded = try JSONDecoder().decode(PlayerResponse.self, from: data)
        return SpotifyPlayerState(
            isPlaying: decoded.is_playing ?? false,
            progressSeconds: TimeInterval(decoded.progress_ms ?? 0) / 1000,
            durationSeconds: TimeInterval(decoded.item?.duration_ms ?? 0) / 1000,
            trackID: decoded.item?.id,
            activeDeviceID: decoded.device?.id
        )
    }

    func fetchDevices(accessToken: String) async throws -> [SpotifyDevice] {
        struct DevicesResponse: Decodable {
            struct Device: Decodable {
                let id: String?
                let name: String?
                let is_active: Bool?
                let is_restricted: Bool?
                let type: String?
            }
            let devices: [Device]
        }
        let response: DevicesResponse = try await get(
            URL(string: "https://api.spotify.com/v1/me/player/devices")!,
            accessToken: accessToken
        )
        return response.devices.compactMap { device in
            guard let id = device.id else { return nil }
            return SpotifyDevice(
                id: id,
                name: device.name ?? "Spotify",
                isActive: device.is_active ?? false,
                isRestricted: device.is_restricted ?? false,
                type: device.type ?? ""
            )
        }
    }

    func play(trackURIs: [String], startAt index: Int, deviceID: String?, accessToken: String) async throws {
        let body: [String: Any] = [
            "uris": trackURIs,
            "offset": ["position": index],
        ]
        try await send(
            "PUT",
            path: Self.path("me/player/play", deviceID: deviceID),
            body: try JSONSerialization.data(withJSONObject: body),
            accessToken: accessToken
        )
    }

    func fetchPlaybackQueue(accessToken: String) async throws -> SpotifyQueueSnapshot {
        struct QueueResponse: Decodable {
            struct Artist: Decodable { let name: String? }
            struct Image: Decodable { let url: String? }
            struct Album: Decodable { let images: [Image]? }
            struct Item: Decodable {
                let id: String?
                let name: String?
                let artists: [Artist]?
                let album: Album?
            }
            let currently_playing: Item?
            let queue: [Item]?
        }
        let response: QueueResponse = try await get(
            URL(string: "https://api.spotify.com/v1/me/player/queue")!,
            accessToken: accessToken
        )

        // Spotify pads the queue from the playing context: with a short album it repeats those
        // tracks over and over to fill roughly twenty slots, and it also repeats the currently
        // playing track inside `queue`. Taken verbatim that showed the same album three times
        // over. Keeping the first occurrence of each track collapses it back to the run that was
        // actually asked for — which is what Spotify's own app displays.
        let ordered = ([response.currently_playing].compactMap { $0 }) + (response.queue ?? [])
        var seen = Set<String>()
        var entries: [SpotifyQueueEntry] = []
        for item in ordered {
            guard let id = item.id, seen.insert(id).inserted else { continue }
            entries.append(SpotifyQueueEntry(
                trackID: id,
                title: item.name ?? "Unknown Title",
                artist: item.artists?.compactMap(\.name).joined(separator: ", ") ?? "",
                artworkURL: item.album?.images?.first?.url,
                position: entries.count
            ))
        }
        return SpotifyQueueSnapshot(currentTrackID: response.currently_playing?.id, entries: entries)
    }

    func transferPlayback(toDeviceID deviceID: String, play: Bool, accessToken: String) async throws {
        let body: [String: Any] = ["device_ids": [deviceID], "play": play]
        try await send(
            "PUT",
            path: "me/player",
            body: try JSONSerialization.data(withJSONObject: body),
            accessToken: accessToken
        )
    }

    func resume(deviceID: String?, accessToken: String) async throws {
        try await send("PUT", path: Self.path("me/player/play", deviceID: deviceID), body: nil, accessToken: accessToken)
    }

    func pause(deviceID: String?, accessToken: String) async throws {
        try await send("PUT", path: Self.path("me/player/pause", deviceID: deviceID), body: nil, accessToken: accessToken)
    }

    func skipToNext(deviceID: String?, accessToken: String) async throws {
        try await send("POST", path: Self.path("me/player/next", deviceID: deviceID), body: nil, accessToken: accessToken)
    }

    func skipToPrevious(deviceID: String?, accessToken: String) async throws {
        try await send("POST", path: Self.path("me/player/previous", deviceID: deviceID), body: nil, accessToken: accessToken)
    }

    func seek(toMilliseconds position: Int, deviceID: String?, accessToken: String) async throws {
        let base = "me/player/seek?position_ms=\(position)"
        let path = deviceID.map { "\(base)&device_id=\($0)" } ?? base
        try await send("PUT", path: path, body: nil, accessToken: accessToken)
    }

    /// Spotify explains a refusal in `error.message` — "Cannot skip to previous track" and the
    /// like. Far more use than the status code on its own.
    private static func reason(in data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
    }

    private static let maximumRetries = 3
    /// Longer than this and the user is told to come back later rather than watching a spinner.
    private static let longestRetryAfterToWaitOut = 10

    private static func path(_ base: String, deviceID: String?) -> String {
        deviceID.map { "\(base)?device_id=\($0)" } ?? base
    }

    private func send(_ method: String, path: String, body: Data?, accessToken: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.requestFailed("no response")
        }
        // 404 here means "no active device" rather than a bad URL — Spotify's way of saying
        // there is nothing to control.
        if http.statusCode == 404 {
            throw SpotifyError.noActiveDevice
        }
        if http.statusCode == 429 {
            throw SpotifyError.rateLimited(
                retryAfterSeconds: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "")
            )
        }
        if http.statusCode == 401 {
            throw SpotifyError.permissionsMissing
        }
        if http.statusCode == 403 {
            throw SpotifyError.actionNotAllowed(Self.reason(in: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError.requestFailed("HTTP \(http.statusCode) \(detail)")
        }
    }

    private func get<T: Decodable>(_ url: URL, accessToken: String, attempt: Int = 0) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.requestFailed("no response")
        }
        // Spotify throttles a long paging run. A short wait is honoured and retried, so a sync
        // isn't abandoned halfway; a long one is reported instead of slept through, because
        // Spotify's back-off can run to minutes and a frozen progress bar explains nothing.
        if http.statusCode == 429 {
            let retryAfter = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "")
            let waitSeconds = retryAfter ?? 2
            guard attempt < Self.maximumRetries, waitSeconds <= Self.longestRetryAfterToWaitOut else {
                throw SpotifyError.rateLimited(retryAfterSeconds: retryAfter)
            }
            try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
            return try await get(url, accessToken: accessToken, attempt: attempt + 1)
        }
        if http.statusCode == 401 {
            throw SpotifyError.permissionsMissing
        }
        if http.statusCode == 403 {
            throw SpotifyError.actionNotAllowed(Self.reason(in: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.requestFailed("HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Wire format

private struct SavedTracksPage: Decodable {
    let items: [SavedTrackItem]
    let next: String?
}

private struct SavedTrackItem: Decodable {
    let track: TrackObject?
}

private struct TrackObject: Decodable {
    let id: String?
    let name: String
    let track_number: Int?
    let duration_ms: Int?
    let artists: [NamedObject]
    let album: AlbumObject

    var asTrack: SpotifyTrack? {
        guard let id else { return nil } // local files in a playlist have no id
        return SpotifyTrack(
            id: id,
            title: name,
            artistNames: artists.map(\.name),
            albumName: album.name,
            albumArtistNames: album.artists.map(\.name),
            trackNumber: track_number ?? 0,
            durationSeconds: TimeInterval(duration_ms ?? 0) / 1000,
            albumID: album.id,
            // Spotify lists images largest first; ArtworkProcessor downsizes from there.
            albumArtworkURL: album.images.first.flatMap { URL(string: $0.url) }
        )
    }
}

private struct SavedAlbumsPage: Decodable {
    let items: [SavedAlbumItem]
    let next: String?
}

private struct SavedAlbumItem: Decodable {
    let album: SavedAlbumObject?
}

private struct SavedAlbumObject: Decodable {
    struct TracksPage: Decodable {
        let items: [AlbumTrackObject]
    }
    let id: String
    let name: String
    let artists: [NamedObject]
    let images: [ImageObject]
    let tracks: TracksPage?

    /// A saved album carries its own track list, so no extra request per album is needed for
    /// the first 50 — which is all but the longest compilations.
    var tracksAsSpotifyTracks: [SpotifyTrack] {
        (tracks?.items ?? []).compactMap { track in
            guard let id = track.id else { return nil }
            return SpotifyTrack(
                id: id,
                title: track.name,
                artistNames: track.artists.map(\.name),
                albumName: name,
                albumArtistNames: artists.map(\.name),
                trackNumber: track.track_number ?? 0,
                durationSeconds: TimeInterval(track.duration_ms ?? 0) / 1000,
                albumID: id_,
                albumArtworkURL: images.first.flatMap { URL(string: $0.url) }
            )
        }
    }

    private var id_: String { id }
}

private struct AlbumTrackObject: Decodable {
    let id: String?
    let name: String
    let track_number: Int?
    let duration_ms: Int?
    let artists: [NamedObject]
}

private struct AlbumObject: Decodable {
    let id: String
    let name: String
    let artists: [NamedObject]
    let images: [ImageObject]
}

private struct NamedObject: Decodable {
    let name: String
}

private struct ImageObject: Decodable {
    let url: String
}
