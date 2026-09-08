import Foundation
import SwiftData

enum AppContainer {
    @MainActor
    static func makeModelContainer() -> ModelContainer {
        ensureApplicationSupportDirectoryExists()

        let schema = Schema([Source.self, Artist.self, Album.self, Song.self])

        #if DEBUG
        UITestSupport.resetSourceSwitchesIfRequested()
        if UITestSupport.isSeedingRequested {
            // In-memory, so a UI test run never touches (or inherits) the real library.
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
                fatalError("Failed to create in-memory ModelContainer for UI testing")
            }
            UITestSupport.seedLibrary(into: container.mainContext)
            return container
        }
        #endif

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// iOS doesn't create `Library/Application Support` for an app, but that's where SwiftData
    /// puts its store by default. On a first launch CoreData therefore fails to create the
    /// store, dumps several hundred lines of filesystem diagnostics to the console, and only
    /// then recovers by creating the directory itself. The end state is fine, but the noise
    /// buries anything genuinely worth reading in the log — so create it up front instead.
    private static func ensureApplicationSupportDirectoryExists() {
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
