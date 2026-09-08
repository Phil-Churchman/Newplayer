import Foundation
import SwiftData

/// Which source the app is set to use.
///
/// Held per *kind* rather than as a flag on a Source row, because a kind can be chosen before it
/// has a row at all — before a folder is picked, a host entered, or Spotify signed into. That is
/// what lets the library screens distinguish "nothing chosen" from "chosen, but nothing loaded
/// into it yet".
///
/// `Source.isActive` is kept in step with this so playback and the source-scoped queries carry on
/// working from the row; this is the authority, that is the derived value.
@MainActor
enum SourceSelection {
    private static let key = "selectedSourceKind"
    private static let noneStored = -1

    static var selectedKind: SourceKind? {
        get {
            let raw = UserDefaults.standard.object(forKey: key) as? Int ?? noneStored
            return raw == noneStored ? nil : SourceKind(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? noneStored, forKey: key)
        }
    }

    /// Chooses a kind and brings every Source row into line: the one of that kind becomes active,
    /// all others do not. Selection is exclusive — choosing one source is choosing away from the
    /// rest.
    static func select(_ kind: SourceKind?, among sources: [Source], modelContext: ModelContext) {
        selectedKind = kind
        for source in sources {
            let shouldBeActive = source.kind == kind
            if source.isActive != shouldBeActive {
                source.isActive = shouldBeActive
            }
        }
        try? modelContext.save()
    }

    /// The row for the chosen kind, if one exists yet.
    static func activeSource(among sources: [Source]) -> Source? {
        guard let selectedKind else { return nil }
        return sources.first { $0.kind == selectedKind }
    }
}

/// What the library screens can show right now.
enum LibraryAvailability: Equatable {
    /// No source chosen in Sources.
    case noSourceSelected
    /// A source is chosen, but it has nothing in it — no folder picked, no host connected, not
    /// signed in, or simply not synced yet.
    case selectedSourceEmpty
    case ready

    static func current(sources: [Source], selectedKind: SourceKind?) -> LibraryAvailability {
        guard let selectedKind else { return .noSourceSelected }
        guard let source = sources.first(where: { $0.kind == selectedKind }) else {
            return .selectedSourceEmpty
        }
        return source.songs.isEmpty ? .selectedSourceEmpty : .ready
    }
}
