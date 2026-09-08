import Foundation

/// Abstraction over an MPD server connection so PlaybackManager and MPDLibrarySyncService can
/// be unit tested against a mock without a live server.
protocol MPDClientProtocol: Sendable {
    func connect(host: String, port: UInt16) async throws
    func disconnect() async

    func fetchStatus() async throws -> MPDStatus
    func fetchAllSongs() async throws -> [MPDSongInfo]
    /// The ordered list of file URIs currently in MPD's own queue — the actual source of
    /// truth for what's queued, as opposed to whatever PlaybackManager last told it to queue.
    func fetchQueue() async throws -> [String]
    /// Returns raw (unprocessed) artwork bytes for a song file, or nil if none is available.
    func fetchAlbumArt(forFile file: String) async -> Data?

    /// Tells the MPD server to rescan its own music directory for new/changed/removed files.
    /// This only updates the server's database — the app's mirrored catalogue still needs a
    /// separate `fetchAllSongs` (via MPDLibrarySyncService) afterwards to pick up the changes.
    func updateDatabase() async throws

    func setPause(_ paused: Bool) async throws
    func stop() async throws
    func next() async throws
    func previous() async throws
    func seek(seconds: Double) async throws

    /// Clears MPD's queue, adds each uri in order, then starts playback at `startAt`.
    func replaceQueue(uris: [String], startAt: Int) async throws
    func addToQueue(uri: String) async throws
    /// Stops playback and empties the server's queue.
    func clearQueue() async throws
    func playAtQueuePosition(_ position: Int) async throws
    func deleteFromQueue(position: Int) async throws
}
