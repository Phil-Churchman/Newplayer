import XCTest
import UIKit
import SwiftData
@testable import NewPlayer

@MainActor
final class LibraryImportServiceTests: XCTestCase {
    private var tempFolder: URL!

    override func setUpWithError() throws {
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFolder)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Writes a minimal valid, untagged mono 8-bit PCM WAV file so the scan pipeline has a
    /// real decodable file to extract duration from, with no ID3/iTunes metadata at all —
    /// exercising the "untagged file" fallback policy (filename title, Unknown Artist/Album).
    private func writeUntaggedWavFile(named name: String, in folder: URL? = nil) throws -> URL {
        let sampleRate: UInt32 = 8000
        let sampleCount = 800 // 0.1s of audio
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let byteRate = sampleRate * 1 * 8 / 8
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + sampleCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(sampleRate)
        append(byteRate)
        append(UInt16(1)) // block align
        append(UInt16(8)) // bits per sample
        data.append(contentsOf: "data".utf8)
        append(UInt32(sampleCount))
        data.append(Data(repeating: 128, count: sampleCount))

        let url = (folder ?? tempFolder).appendingPathComponent("\(name).wav")
        try data.write(to: url)
        return url
    }

    func testRescanImportsUntaggedFileWithFallbackMetadata() async throws {
        _ = try writeUntaggedWavFile(named: "My Untagged Track")

        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Local", isActive: true)
        source.bookmarkData = try FolderBookmarkStore.makeBookmark(for: tempFolder)
        context.insert(source)
        try context.save()

        await LibraryImportService.rescan(source: source, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.title, "My Untagged Track")
        XCTAssertEqual(songs.first?.artist, "Unknown Artist")
        XCTAssertEqual(songs.first?.albumTitle, "Unknown Album")

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.name, "Unknown Album")

        XCTAssertEqual(source.lastSyncStatus, .success)
    }

    func testRescanWipesPreviousRowsForSameSource() async throws {
        _ = try writeUntaggedWavFile(named: "Track One")

        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Local", isActive: true)
        source.bookmarkData = try FolderBookmarkStore.makeBookmark(for: tempFolder)
        context.insert(source)
        try context.save()

        await LibraryImportService.rescan(source: source, modelContext: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 1)

        // Remove the file and rescan again — the stale row should be gone, not duplicated.
        try FileManager.default.removeItem(at: tempFolder.appendingPathComponent("Track One.wav"))
        _ = try writeUntaggedWavFile(named: "Track Two")

        await LibraryImportService.rescan(source: source, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.title, "Track Two")
    }

    /// Guards against the exact symptom reported when testing on a real folder: picking a
    /// folder whose audio files live in nested subdirectories (Artist/Album/track.ext, as
    /// most real music collections are laid out) must still find and import them, with a
    /// correct relativePath for later playback URL resolution.
    func testRescanFindsFilesInNestedSubdirectories() async throws {
        let nested = tempFolder
            .appendingPathComponent("Some Artist")
            .appendingPathComponent("Some Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try writeUntaggedWavFile(named: "Nested Track", in: nested)

        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Local", isActive: true)
        source.bookmarkData = try FolderBookmarkStore.makeBookmark(for: tempFolder)
        context.insert(source)
        try context.save()

        await LibraryImportService.rescan(source: source, modelContext: context)

        let songs = try context.fetch(FetchDescriptor<Song>())
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.relativePath, "Some Artist/Some Album/Nested Track.wav")
        XCTAssertEqual(source.lastSyncStatus, .success)
    }

    private func makeCoverImageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format)
        return renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.jpegData(compressionQuality: 0.9)!
    }

    func testUsesCoverFileFromTheAlbumFolderWhenTagsHaveNoEmbeddedArt() async throws {
        // The synthetic WAV carries no embedded picture, so a cover file beside it is the
        // only artwork available — a very common local-library layout.
        _ = try writeUntaggedWavFile(named: "Track One")
        try makeCoverImageData().write(to: tempFolder.appendingPathComponent("cover.jpg"))

        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Local", isActive: true, kind: .local)
        source.bookmarkData = try FolderBookmarkStore.makeBookmark(for: tempFolder)
        context.insert(source)
        try context.save()

        await LibraryImportService.rescan(source: source, modelContext: context)

        let album = try XCTUnwrap(context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertNotNil(album.artwork, "cover.jpg beside the tracks should be used as the album art")
        XCTAssertNotNil(album.thumbnail)
    }

    func testFindsCoverFileInASubfolder() async throws {
        let discFolder = tempFolder.appendingPathComponent("Disc 1")
        try FileManager.default.createDirectory(at: discFolder, withIntermediateDirectories: true)
        _ = try writeUntaggedWavFile(named: "Track One")
        try makeCoverImageData().write(to: discFolder.appendingPathComponent("cover.jpeg"))

        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Local", isActive: true, kind: .local)
        source.bookmarkData = try FolderBookmarkStore.makeBookmark(for: tempFolder)
        context.insert(source)
        try context.save()

        await LibraryImportService.rescan(source: source, modelContext: context)

        let album = try XCTUnwrap(context.fetch(FetchDescriptor<Album>()).first)
        XCTAssertNotNil(album.artwork, "cover.jpeg in a subfolder should be found too")
    }

    func testSupportedExtensionsIncludeFLAC() {
        XCTAssertTrue(MetadataExtractor.supportedExtensions.contains("flac"))
    }
}
