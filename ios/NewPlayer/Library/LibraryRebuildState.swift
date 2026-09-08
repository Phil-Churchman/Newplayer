import Foundation

/// Whether a source's library is being wiped and rebuilt right now.
///
/// The library screens are backed by `@Query`, so every intermediate save during a rebuild makes
/// each of them re-fetch and re-render — thousands of rows, dozens of times, on the main actor.
/// That cost scales with what is *already* in the library, which is why a first sync into an
/// empty store is smooth and a second one over a full library locks the app up.
///
/// While a rebuild runs, those screens show progress instead, so no list is querying rows that
/// are being deleted and reinserted underneath it.
@MainActor
@Observable
final class LibraryRebuildState {
    static let shared = LibraryRebuildState()

    private(set) var isRebuilding = false
    private(set) var processed = 0
    private(set) var total = 0

    func begin() {
        isRebuilding = true
        processed = 0
        total = 0
    }

    func report(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }

    func finish() {
        isRebuilding = false
    }
}
