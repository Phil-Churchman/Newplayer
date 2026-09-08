import XCTest
@testable import NewPlayer

final class MPDResponseParserTests: XCTestCase {
    func testParseSongsGroupsFieldsPerFileLine() {
        let lines = [
            "directory: Some Artist",
            "file: Some Artist/Some Album/01 - First.flac",
            "Last-Modified: 2020-01-01T00:00:00Z",
            "Title: First",
            "Artist: Some Artist",
            "Album: Some Album",
            "AlbumArtist: Some Artist",
            "Track: 1",
            "Time: 245",
            "duration: 245.320",
            "Pos: 0",
            "Id: 1",
            "file: Some Artist/Some Album/02 - Second.flac",
            "Title: Second",
            "Artist: Some Artist",
            "Album: Some Album",
            "AlbumArtist: Some Artist",
            "Track: 2/12",
            "duration: 198.0",
            "Pos: 1",
            "Id: 2",
        ]

        let songs = MPDResponseParser.parseSongs(fromLines: lines)

        XCTAssertEqual(songs.count, 2)
        XCTAssertEqual(songs[0].file, "Some Artist/Some Album/01 - First.flac")
        XCTAssertEqual(songs[0].title, "First")
        XCTAssertEqual(songs[0].track, 1)
        XCTAssertEqual(songs[0].duration, 245.320, accuracy: 0.001)

        XCTAssertEqual(songs[1].file, "Some Artist/Some Album/02 - Second.flac")
        XCTAssertEqual(songs[1].track, 2, "a Track value like '2/12' should parse the numerator only")
        XCTAssertEqual(songs[1].duration, 198.0, accuracy: 0.001)
    }

    func testParseSongsFallsBackToTimeWhenDurationFieldMissing() {
        let lines = [
            "file: track.mp3",
            "Time: 100",
        ]

        let songs = MPDResponseParser.parseSongs(fromLines: lines)

        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].duration, 100, accuracy: 0.001)
    }

    func testParseSongsIgnoresLinesBeforeFirstFile() {
        let lines = [
            "directory: Empty Folder",
            "directory: Another Folder",
        ]

        XCTAssertTrue(MPDResponseParser.parseSongs(fromLines: lines).isEmpty)
    }

    func testParseSongsHandlesMissingOptionalTags() {
        let lines = ["file: untagged.mp3"]

        let songs = MPDResponseParser.parseSongs(fromLines: lines)

        XCTAssertEqual(songs.count, 1)
        XCTAssertNil(songs[0].title)
        XCTAssertNil(songs[0].artist)
        XCTAssertNil(songs[0].album)
        XCTAssertEqual(songs[0].duration, 0)
    }

    func testParseStatusExtractsTransportFields() {
        let lines = [
            "volume: 80",
            "repeat: 0",
            "random: 0",
            "state: play",
            "song: 3",
            "elapsed: 12.500",
            "duration: 245.0",
        ]

        let status = MPDResponseParser.parseStatus(fromLines: lines)

        XCTAssertEqual(status.state, "play")
        XCTAssertEqual(status.songPosition, 3)
        XCTAssertEqual(status.elapsed, 12.5, accuracy: 0.001)
        XCTAssertEqual(status.duration, 245.0, accuracy: 0.001)
    }

    func testParseStatusDefaultsToStoppedWithNoState() {
        let status = MPDResponseParser.parseStatus(fromLines: [])

        XCTAssertEqual(status.state, "stop")
        XCTAssertNil(status.songPosition)
        XCTAssertEqual(status.elapsed, 0)
        XCTAssertEqual(status.duration, 0)
        XCTAssertFalse(status.isUpdatingDatabase)
    }

    func testParseStatusDetectsUpdatingDatabase() {
        let status = MPDResponseParser.parseStatus(fromLines: ["state: play", "updating_db: 7"])

        XCTAssertTrue(status.isUpdatingDatabase)
    }

    func testParseStatusNotUpdatingWhenFieldAbsent() {
        let status = MPDResponseParser.parseStatus(fromLines: ["state: play"])

        XCTAssertFalse(status.isUpdatingDatabase)
    }
}
