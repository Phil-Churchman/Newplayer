import XCTest
import SwiftData
@testable import NewPlayer

/// The merge runs on the main actor, so it must hand that actor back regularly. Without it a
/// few thousand tracks is one unbroken synchronous block and the app is frozen for the whole
/// rebuild — which surfaced as the app hanging at the end of a server sync, because that's when
/// the refresh runs.
@MainActor
final class LibraryRowBuilderResponsivenessTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeRawSongs(_ count: Int) -> [RawSong] {
        (0..<count).map { index in
            RawSong(
                title: "Track \(index)",
                artist: "Artist \(index % 40)",
                album: "Album \(index % 120)",
                albumArtist: "Artist \(index % 40)",
                track: index % 20,
                duration: 200,
                relativePath: "music/track-\(index).flac",
                artworkData: nil
            )
        }
    }

    /// Runs a "UI" task alongside the rebuild. If the rebuild never suspends, this task cannot
    /// run at all until it finishes — which is exactly what a frozen app is.
    func testTheMainActorIsGivenBackWhileMerging() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        context.insert(source)
        try context.save()

        var uiTicks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                uiTicks += 1
                await Task.yield()
            }
        }

        try await LibraryRowBuilder.merge(from: makeRawSongs(2000), source: source, modelContext: context)
        ticker.cancel()

        XCTAssertGreaterThan(uiTicks, 1, "the main actor was never yielded during the rebuild")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 2000)
    }

    /// Progress still reaches the UI, but as a handful of updates rather than one per song.
    func testProgressIsReportedPerBatchAndFinishesAtTheTotal() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        context.insert(source)
        try context.save()

        var reports: [(Int, Int)] = []
        try await LibraryRowBuilder.merge(
            from: makeRawSongs(1000),
            source: source,
            modelContext: context,
            onProgress: { processed, total in reports.append((processed, total)) }
        )

        XCTAssertFalse(reports.isEmpty, "the sync screen needs progress to show")
        XCTAssertLessThan(reports.count, 50, "1000 songs should not publish 1000 view updates")
        XCTAssertEqual(reports.last?.0, 1000, "progress must finish at the total")
        XCTAssertEqual(reports.last?.1, 1000)
    }

    /// A rebuild replaces what was there before rather than accumulating duplicates.
    func testASyncReplacesPreviousRows() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = Source(name: "Network", host: "h", port: 6600, isActive: true, kind: .network)
        context.insert(source)
        try context.save()

        try await LibraryRowBuilder.merge(from: makeRawSongs(500), source: source, modelContext: context)
        try await LibraryRowBuilder.merge(from: makeRawSongs(300), source: source, modelContext: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Song>()).count, 300)
    }
}
