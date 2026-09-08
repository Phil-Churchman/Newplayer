import Foundation
import SwiftData

enum LibraryImportError: Error {
    case accessDenied
}

@MainActor
enum LibraryImportService {
    /// Full wipe-and-reinsert rescan of a source's library, mirroring the Android app's
    /// scanForSongs(): delete this source's existing Artist/Album/Song rows, then re-import
    /// everything found under the source's bookmarked root folder.
    static func rescan(
        source: Source,
        modelContext: ModelContext,
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void = { _, _ in }
    ) async {
        source.lastSyncStatus = .syncing
        try? modelContext.save()

        do {
            let rawSongs = try await scanFiles(source: source)
            try await LibraryRowBuilder.merge(from: rawSongs, source: source, modelContext: modelContext, onProgress: onProgress)
            source.lastSyncStatus = .success
        } catch {
            source.lastSyncStatus = .failed
            print("LibraryImportService.rescan failed: \(error)")
        }
        source.lastSyncDate = .now
        try? modelContext.save()
    }

    private static func scanFiles(source: Source) async throws -> [RawSong] {
        let root = try FolderBookmarkStore.resolveURL(for: source)
        guard root.startAccessingSecurityScopedResource() else {
            throw LibraryImportError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let audioURLs = enumerateAudioFiles(at: root)
        print("LibraryImportService: found \(audioURLs.count) candidate audio file(s) under \(root.path)")

        // LibraryRowBuilder only ever uses the artwork carried by the first song it encounters
        // per (album, albumArtist) — every other song's artwork is dropped on the floor there
        // anyway. Discarding it here too, immediately after each extraction, keeps only one
        // album's worth of artwork resident at a time instead of accumulating every song's
        // full-size embedded picture (which for FLAC especially can be several MB each) across
        // the whole scan — the difference between an OOM kill and a bounded-memory scan on a
        // library of any real size.
        var seenAlbumKeys = Set<String>()
        var coverFileCache: [String: Data?] = [:]
        var rawSongs: [RawSong] = []
        for fileURL in audioURLs {
            let metadata = await MetadataExtractor.extract(url: fileURL)
            let relativePath = String(fileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let albumKey = "\(metadata.album)\u{0}\(metadata.albumArtist)"
            let isFirstForAlbum = seenAlbumKeys.insert(albumKey).inserted

            var artworkData: Data?
            if isFirstForAlbum {
                // Fall back to a cover file sitting alongside the music when the tags carry no
                // embedded picture — a very common way for local libraries to be organised.
                artworkData = metadata.artworkData ?? coverImageData(nextTo: fileURL, cache: &coverFileCache)
            }

            rawSongs.append(RawSong(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                albumArtist: metadata.albumArtist,
                track: metadata.track,
                duration: metadata.duration,
                relativePath: relativePath,
                artworkData: artworkData
            ))
        }
        return rawSongs
    }

    private static let coverFileNames: Set<String> = ["cover.jpg", "cover.jpeg"]
    /// Multi-disc albums often keep the cover one level up or beside a disc folder, so a
    /// shallow walk is worth it — but it stays shallow so a flat library laid out as one huge
    /// folder can't turn this into a full-tree scan per album.
    private static let coverSearchMaxDepth = 2

    private static func coverImageData(nextTo fileURL: URL, cache: inout [String: Data?]) -> Data? {
        let directory = fileURL.deletingLastPathComponent()
        if let cached = cache[directory.path] {
            return cached
        }
        let found = searchForCoverImage(in: directory, depth: 0)
        cache[directory.path] = found
        return found
    }

    private static func searchForCoverImage(in directory: URL, depth: Int) -> Data? {
        guard depth <= coverSearchMaxDepth else { return nil }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Check this folder's own files before descending.
        for entry in entries where coverFileNames.contains(entry.lastPathComponent.lowercased()) {
            if let data = try? Data(contentsOf: entry) {
                return data
            }
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            if let nested = searchForCoverImage(in: entry, depth: depth + 1) {
                return nested
            }
        }
        return nil
    }

    private static func enumerateAudioFiles(at root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var audioURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard MetadataExtractor.supportedExtensions.contains(ext) else { continue }
            audioURLs.append(fileURL)
        }
        return audioURLs
    }
}
