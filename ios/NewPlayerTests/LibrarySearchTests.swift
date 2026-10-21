import XCTest
@testable import NewPlayer

/// Filtering for the Songs, Artists and Albums lists.
final class LibrarySearchTests: XCTestCase {
    func testMatchesAnywhereInAField() {
        XCTAssertTrue(LibrarySearch.matches("blue", in: ["Kind of Blue"]))
        XCTAssertTrue(LibrarySearch.matches("ind of", in: ["Kind of Blue"]))
    }

    func testIgnoresCase() {
        XCTAssertTrue(LibrarySearch.matches("MILES", in: ["Miles Davis"]))
        XCTAssertTrue(LibrarySearch.matches("miles", in: ["Miles Davis"]))
    }

    /// A library is full of names you cannot easily type.
    func testIgnoresDiacritics() {
        XCTAssertTrue(LibrarySearch.matches("bjork", in: ["Björk"]))
        XCTAssertTrue(LibrarySearch.matches("Aznavour", in: ["Charles Aznavour"]))
    }

    /// Any field may match — a song is found by its artist as readily as its title.
    func testAnyFieldCanMatch() {
        XCTAssertTrue(LibrarySearch.matches("davis", in: ["So What", "Miles Davis"]))
        XCTAssertFalse(LibrarySearch.matches("coltrane", in: ["So What", "Miles Davis"]))
    }

    /// An empty query filters nothing, so the full list stands.
    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(LibrarySearch.matches("", in: ["Anything"]))
        XCTAssertTrue(LibrarySearch.matches("   ", in: ["Anything"]))
        XCTAssertFalse(LibrarySearch.isActive(""))
        XCTAssertFalse(LibrarySearch.isActive("  \n "))
    }

    /// Typed with a trailing space, as a phone's keyboard often leaves it.
    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertTrue(LibrarySearch.matches("  blue  ", in: ["Kind of Blue"]))
        XCTAssertTrue(LibrarySearch.isActive(" blue "))
    }

    func testNoMatchIsNoMatch() {
        XCTAssertFalse(LibrarySearch.matches("zzz", in: ["Kind of Blue", "Miles Davis"]))
        XCTAssertFalse(LibrarySearch.matches("blue", in: []))
    }
}
