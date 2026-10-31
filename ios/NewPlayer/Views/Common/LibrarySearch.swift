import SwiftUI

/// Filtering for the Songs, Artists and Albums lists.
///
/// Matches against what the row actually shows — a song's title and artist, an album's name and
/// artist, an artist's name. Searching on fields the list doesn't display makes results look
/// arbitrary: a song appearing for a word nowhere on screen reads as a bug.
enum LibrarySearch {
    /// Whether any of `fields` contains the query.
    ///
    /// `localizedStandardContains` rather than a lowercased `contains`: it ignores case *and*
    /// diacritics, and does so by the user's locale, so "Bjork" finds "Björk" and "aznavour"
    /// finds "Aznavour". Matching anywhere in the field rather than at the start, because a
    /// library is full of names you remember the middle of.
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    /// Whether a query is worth filtering by at all. Whitespace alone is not.
    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Always-on search for a library list.
///
/// Attached permanently rather than revealed by a toolbar icon. An icon meant the modifier had
/// to come and go, and removing it mid-dismissal tore the navigation bar's search drawer down
/// while the keyboard was still animating in its own window — which is what CoreAnimation was
/// complaining about. A field that is simply always there has nothing to tear down.
///
/// `displayMode: .always` so it stays put instead of hiding above the first row, where it is
/// only found by pulling the list down.
extension View {
    func librarySearchable(text: Binding<String>, prompt: String) -> some View {
        searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
    }
}
