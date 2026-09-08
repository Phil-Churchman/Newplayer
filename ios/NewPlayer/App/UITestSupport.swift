#if DEBUG
import Foundation
import SwiftData

/// Test-only hook: lets the UI tests launch with a populated library without needing a real
/// music folder or MPD server. Guarded by a launch argument and compiled out of release.
enum UITestSupport {
    static let seedArgument = "-uiTestSeedLibrary"
    /// The source selection lives in UserDefaults, which survives between test runs — a test
    /// that changes it would otherwise poison every run after it.
    static let resetSwitchesArgument = "-uiTestResetSourceSwitches"

    static func resetSourceSwitchesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(resetSwitchesArgument) else { return }
        // Seeded runs browse the local library, so that is the selected source.
        UserDefaults.standard.set(SourceKind.local.rawValue, forKey: "selectedSourceKind")
    }

    static var isSeedingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedArgument)
    }

    /// Enough rows to fill well past one screen, so scrolling to the very last one is a real test.
    static let seededSongCount = 40

    static func seedLibrary(into context: ModelContext) {
        let source = Source(name: "Local", isActive: true, kind: .local)
        let artist = Artist(name: "Test Artist", source: source)
        let album = Album(name: "Test Album", artist: artist, source: source)
        context.insert(source)
        context.insert(artist)
        context.insert(album)

        for index in 1...seededSongCount {
            let song = Song(
                title: String(format: "Track %02d", index),
                artist: "Test Artist",
                albumTitle: "Test Album",
                albumArtist: "Test Artist",
                track: index,
                duration: 100,
                relativePath: "track-\(index).mp3",
                album: album,
                source: source
            )
            context.insert(song)
        }
        try? context.save()
    }
}
#endif
