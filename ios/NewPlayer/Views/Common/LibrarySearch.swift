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

/// The magnifying glass that reveals the search field, and the field itself.
///
/// The `searchable` modifier is attached only while searching, rather than always with an
/// `isPresented` binding to hide it. Dismissed, it does not go away: it collapses into the
/// navigation bar's search drawer and sits there under the title as an empty bar. Removing the
/// modifier outright is the only way to get the space back.
///
/// The text is cleared on the way out, because a hidden field holding a query would leave the
/// list filtered with nothing on screen to explain why.
struct LibrarySearchable: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        searchField(content)
            .onChange(of: isPresented) { _, nowPresented in
                if !nowPresented { text = "" }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Hidden while searching: the field has its own Cancel, and two ways out
                    // sitting side by side is one too many.
                    if !isPresented {
                        Button {
                            isPresented = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Search")
                    }
                }
            }
    }

    @ViewBuilder
    private func searchField(_ content: Content) -> some View {
        if isPresented {
            content.searchable(text: $text, isPresented: $isPresented, prompt: prompt)
        } else {
            content
        }
    }
}

extension View {
    func librarySearchable(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        modifier(LibrarySearchable(text: text, isPresented: isPresented, prompt: prompt))
    }
}
