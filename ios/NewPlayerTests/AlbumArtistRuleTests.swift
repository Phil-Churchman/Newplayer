import XCTest
@testable import NewPlayer

/// One rule, applied by every source: the album groups under the album-artist tag its tracks
/// agree on, and each track keeps its own performer.
final class AlbumArtistRuleTests: XCTestCase {
    func testTracksAgreeingOnAnAlbumArtistUseIt() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["Alice", "Alice", "Alice"], trackArtists: []), "Alice")
    }

    /// Nothing named anywhere is an untagged file, not a compilation.
    func testNothingTaggedAtAllIsUnknownArtist() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: [nil, nil], trackArtists: []), "Unknown Artist")
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["", "   "], trackArtists: [nil]), "Unknown Artist")
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: [], trackArtists: []), "Unknown Artist")
    }

    /// No album artist, but every track names the same performer: an untagged record by one
    /// artist is that artist's. File-based libraries are routinely tagged this way, and calling
    /// all of them compilations would have swamped the Artists list.
    func testNoAlbumArtistFallsBackToAConsistentTrackArtist() {
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: [nil, nil], trackArtists: ["Alice", "Alice"]),
            "Alice"
        )
        // Trimmed on the way, as album artists are.
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: [], trackArtists: ["Alice", " Alice "]),
            "Alice"
        )
    }

    /// No album artist and the performers differ: that is a compilation.
    func testNoAlbumArtistAndDifferingTrackArtistsIsACompilation() {
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: [nil, nil], trackArtists: ["Alice", "Bob"]),
            "Compilation"
        )
    }

    /// The track artists are only a fallback. A record that names an album artist has answered
    /// the question, and disagreeing ones are a compilation however consistent the performers.
    func testTrackArtistsDoNotOverrideADefinedAlbumArtist() {
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: ["Alice", "Bob"], trackArtists: ["Carol", "Carol"]),
            "Compilation"
        )
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: ["Alice", nil], trackArtists: ["Carol", "Carol"]),
            "Alice"
        )
    }

    func testDisagreeingAlbumArtistsAreACompilation() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["Alice", "Bob"], trackArtists: []), "Compilation")
    }

    /// A gap in the tagging is not a second artist: one untagged track on an otherwise
    /// consistent album would otherwise turn the whole record into a compilation.
    func testAMissingTagAmongstAgreeingOnesIsIgnored() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["Alice", nil, "Alice"], trackArtists: []), "Alice")
    }

    /// A stray space is not a different artist.
    func testSurroundingWhitespaceIsNotADisagreement() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["Alice", " Alice ", "Alice\n"], trackArtists: []), "Alice")
    }

    /// Case is deliberately left alone: calling these the same means choosing which spelling to
    /// show, and that is a judgement the rule does not make.
    func testCaseIsNotFolded() {
        XCTAssertEqual(AlbumArtistRule.groupingArtist(albumArtists: ["ABBA", "Abba"], trackArtists: []), "Compilation")
    }

    // MARK: - Which tracks make up an album

    private struct T: Equatable { let name: String; let id: String?; let albumArtist: String? }
    private func components(_ tracks: [T]) -> [[String]] {
        AlbumArtistRule.albumComponents(tracks, id: \.id, albumArtist: \.albumArtist)
            .map { $0.map(\.name).sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
    }

    /// Ids differ within one album — tracks added by different routes, or Spotify relinking.
    /// The shared album artist holds the record together.
    func testDifferentIDsWithOneAlbumArtistAreOneAlbum() {
        XCTAssertEqual(
            components([
                T(name: "a", id: "bought", albumArtist: "Alice"),
                T(name: "b", id: "matched", albumArtist: "Alice"),
            ]),
            [["a", "b"]]
        )
    }

    /// The case this exists for: album artists disagree, so the shared id has to hold the
    /// record together — and `groupingArtist` then renames the whole of it "Compilation", which
    /// is what stops it splitting into one album per artist.
    func testDifferentAlbumArtistsWithOneIDAreOneAlbum() {
        let tracks = [
            T(name: "a", id: "rec", albumArtist: "Alice"),
            T(name: "b", id: "rec", albumArtist: "Bob"),
        ]
        XCTAssertEqual(components(tracks), [["a", "b"]])
        XCTAssertEqual(
            AlbumArtistRule.groupingArtist(albumArtists: tracks.map(\.albumArtist), trackArtists: []),
            "Compilation"
        )
    }

    /// Sharing neither is two different records that happen to share a title.
    func testTracksSharingNeitherIDNorArtistAreSeparateAlbums() {
        XCTAssertEqual(
            components([
                T(name: "a", id: "alice-hits", albumArtist: "Alice"),
                T(name: "b", id: "bob-hits", albumArtist: "Bob"),
            ]),
            [["a"], ["b"]]
        )
    }

    /// Followed transitively, so a chain of partial overlaps is still one album.
    func testLinksAreFollowedTransitively() {
        XCTAssertEqual(
            components([
                T(name: "a", id: "one", albumArtist: "Alice"),
                T(name: "b", id: "one", albumArtist: "Bob"),
                T(name: "c", id: "two", albumArtist: "Bob"),
            ]),
            [["a", "b", "c"]]
        )
    }

    /// Tracks carrying neither field have nothing to link on, so they share a sentinel and
    /// become one album rather than one album each.
    func testUntaggedTracksBecomeOneAlbumNotOneEach() {
        XCTAssertEqual(
            components([
                T(name: "a", id: nil, albumArtist: nil),
                T(name: "b", id: "", albumArtist: "  "),
            ]),
            [["a", "b"]]
        )
    }

    /// The track credit is what survives; the album's name is only the fallback.
    func testTrackArtistFallsBackToTheAlbumArtist() {
        XCTAssertEqual(AlbumArtistRule.trackArtist("Bob", inAlbumBy: "Compilation"), "Bob")
        XCTAssertEqual(AlbumArtistRule.trackArtist(nil, inAlbumBy: "Alice"), "Alice")
        XCTAssertEqual(AlbumArtistRule.trackArtist("  ", inAlbumBy: "Alice"), "Alice")
    }
}
