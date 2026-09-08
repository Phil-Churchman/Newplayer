import SwiftUI

struct LetterSection<Item: Identifiable>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }
}

/// A List grouped by first letter with a drag-able alphabet index rail on the trailing edge,
/// reimplementing the Android app's FastScrollLazyColumn since SwiftUI's List has no direct
/// sectionIndexTitles bridge.
///
/// The grouping is cached in state rather than computed in `body`. As a computed property it
/// re-ran `Dictionary(grouping:)`, a sort, and a per-item `uppercased()` allocation on every
/// body evaluation — twice over, since `letters` read it again — which on a library of a few
/// thousand tracks made scrolling stutter badly whenever anything invalidated the view.
struct AlphabetIndexList<Item: Identifiable & Equatable, RowContent: View>: View {
    let items: [Item]
    let sectionKey: (Item) -> String
    @ViewBuilder let rowContent: (Item) -> RowContent

    @State private var sections: [LetterSection<Item>] = []
    @State private var dragLetter: String?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections) { section in
                        Section(header: Text(section.letter).id(section.letter)) {
                            ForEach(section.items) { item in
                                rowContent(item)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerContentInset()

                if sections.count > 1 {
                    indexRail(proxy: proxy)
                }
            }
        }
        .onChange(of: items, initial: true) { _, newItems in
            sections = Self.makeSections(from: newItems, sectionKey: sectionKey)
        }
    }

    static func makeSections(
        from items: [Item],
        sectionKey: (Item) -> String
    ) -> [LetterSection<Item>] {
        let grouped = Dictionary(grouping: items) { AlphabetIndexSection.label(forKey: sectionKey($0)) }
        return grouped.keys
            .sorted { lhs, rhs in
                let lhsRank = AlphabetIndexSection.sortRank(of: lhs)
                let rhsRank = AlphabetIndexSection.sortRank(of: rhs)
                return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
            }
            .map { label in
                LetterSection(letter: label, items: grouped[label] ?? [])
            }
    }

    private func indexRail(proxy: ScrollViewProxy) -> some View {
        let letters = sections.map(\.letter)
        return VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(dragLetter == letter ? Color.accentColor : .secondary)
            }
        }
        .padding(.trailing, 4)
        .frame(width: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = max(0, min(letters.count - 1, Int(value.location.y / 14)))
                    guard letters.indices.contains(index) else { return }
                    let letter = letters[index]
                    if letter != dragLetter {
                        dragLetter = letter
                        proxy.scrollTo(letter, anchor: .top)
                    }
                }
                .onEnded { _ in
                    dragLetter = nil
                }
        )
    }
}

/// Bucketing rules for the index rail. Kept out of the generic view because a generic type
/// can't hold static stored properties.
enum AlphabetIndexSection {
    /// Everything starting with a digit, collected into one section above A.
    static let numbersLabel = "#"
    /// Everything that isn't A–Z or a digit, collected into one section below Z.
    static let otherLabel = "&"

    /// Buckets a row's sort key into its index section.
    ///
    /// Diacritics are folded first, so "Édith Piaf" files under E rather than dropping into
    /// the catch-all — once folded it *is* a standard A–Z letter. Genuinely non-Latin titles
    /// (Cyrillic, CJK) and punctuation still land in the catch-all.
    static func label(forKey key: String) -> String {
        let folded = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive], locale: .current)
        guard let first = folded.first else { return otherLabel }
        if first.isNumber { return numbersLabel }
        if first.isASCII, first.isLetter { return first.uppercased() }
        return otherLabel
    }

    static func sortRank(of label: String) -> Int {
        switch label {
        case numbersLabel: return 0   // numbers first
        case otherLabel: return 2     // everything else last
        default: return 1             // A–Z in between
        }
    }
}
