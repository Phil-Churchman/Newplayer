import XCTest
import SwiftUI
@testable import NewPlayer

final class AlphabetIndexListTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        let title: String
    }

    private typealias List = AlphabetIndexList<Row, EmptyView>

    private func sections(for titles: [String]) -> [LetterSection<Row>] {
        List.makeSections(from: titles.map(Row.init(title:)), sectionKey: \.title)
    }

    func testDigitsCollapseIntoOneSectionAtTheTop() {
        let result = sections(for: ["2 Become 1", "Beck", "99 Problems", "Air"])

        XCTAssertEqual(result.map(\.letter), [AlphabetIndexSection.numbersLabel, "A", "B"])
        XCTAssertEqual(
            Set(result.first { $0.letter == "#" }?.items.map(\.title) ?? []),
            ["2 Become 1", "99 Problems"]
        )
    }

    func testNonAlphanumericCollapseIntoOneSectionAtTheBottom() {
        let result = sections(for: ["!!!", "Air", "…And Justice For All", "Zebra"])

        XCTAssertEqual(result.map(\.letter), ["A", "Z", "&"])
        XCTAssertEqual(
            Set(result.first { $0.letter == "&" }?.items.map(\.title) ?? []),
            ["!!!", "…And Justice For All"]
        )
    }

    func testNumbersFirstLettersThenEverythingElse() {
        let result = sections(for: ["1999", "Björk", "Air", "#hashtag", "Zappa"])

        XCTAssertEqual(result.map(\.letter), [AlphabetIndexSection.numbersLabel, "A", "B", "Z", "&"])
    }

    /// Accented names belong under their base letter, not lumped in with symbols — once the
    /// diacritic is folded away it is a standard A–Z letter.
    func testAccentedNamesFileUnderTheirBaseLetter() {
        let result = sections(for: ["Édith Piaf", "Eagles", "Ólafur Arnalds"])

        XCTAssertEqual(result.map(\.letter), ["E", "O"])
        XCTAssertEqual(
            Set(result.first { $0.letter == "E" }?.items.map(\.title) ?? []),
            ["Édith Piaf", "Eagles"]
        )
    }

    func testNonLatinTitlesFallIntoTheCatchAll() {
        let result = sections(for: ["Air", "Кино", "東京"])

        XCTAssertEqual(result.map(\.letter), ["A", "&"])
        XCTAssertEqual(result.first { $0.letter == "&" }?.items.count, 2)
    }

    func testLeadingWhitespaceIsIgnoredWhenBucketing() {
        let result = sections(for: ["   Aphex Twin"])

        XCTAssertEqual(result.map(\.letter), ["A"])
    }

    func testEmptyTitleFallsIntoTheCatchAll() {
        let result = sections(for: [""])

        XCTAssertEqual(result.map(\.letter), ["&"])
    }
}
