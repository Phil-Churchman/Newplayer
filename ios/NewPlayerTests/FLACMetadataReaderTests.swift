import XCTest
@testable import NewPlayer

final class FLACMetadataReaderTests: XCTestCase {
    private var tempFile: URL!

    override func tearDownWithError() throws {
        if let tempFile {
            try? FileManager.default.removeItem(at: tempFile)
        }
    }

    // MARK: - Synthetic FLAC construction (metadata blocks only — no real audio frames needed
    // since FLACMetadataReader only ever reads the metadata-block chain before the audio).

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func vorbisCommentBlockData(comments: [String]) -> Data {
        var data = Data()
        let vendor = "test-vendor"
        appendUInt32LE(UInt32(vendor.utf8.count), to: &data)
        data.append(contentsOf: vendor.utf8)
        appendUInt32LE(UInt32(comments.count), to: &data)
        for comment in comments {
            appendUInt32LE(UInt32(comment.utf8.count), to: &data)
            data.append(contentsOf: comment.utf8)
        }
        return data
    }

    private func pictureBlockData(mime: String, pictureBytes: Data) -> Data {
        var data = Data()
        appendUInt32BE(3, to: &data) // picture type: front cover
        appendUInt32BE(UInt32(mime.utf8.count), to: &data)
        data.append(contentsOf: mime.utf8)
        appendUInt32BE(0, to: &data) // description length
        appendUInt32BE(0, to: &data) // width
        appendUInt32BE(0, to: &data) // height
        appendUInt32BE(0, to: &data) // color depth
        appendUInt32BE(0, to: &data) // colors used
        appendUInt32BE(UInt32(pictureBytes.count), to: &data)
        data.append(pictureBytes)
        return data
    }

    private func metadataBlockHeader(type: UInt8, length: Int, isLast: Bool) -> Data {
        var data = Data()
        let firstByte = type | (isLast ? 0x80 : 0)
        data.append(firstByte)
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        return data
    }

    private func writeFLACFile(vorbisComments: [String], pictureBytes: Data?) throws -> URL {
        var file = Data("fLaC".utf8)

        // STREAMINFO (type 0) — content is irrelevant to the reader, just needs to be skippable.
        let streamInfo = Data(repeating: 0, count: 34)
        file.append(metadataBlockHeader(type: 0, length: streamInfo.count, isLast: false))
        file.append(streamInfo)

        let vorbisBlock = vorbisCommentBlockData(comments: vorbisComments)
        let hasPicture = pictureBytes != nil
        file.append(metadataBlockHeader(type: 4, length: vorbisBlock.count, isLast: !hasPicture))
        file.append(vorbisBlock)

        if let pictureBytes {
            let pictureBlock = pictureBlockData(mime: "image/jpeg", pictureBytes: pictureBytes)
            file.append(metadataBlockHeader(type: 6, length: pictureBlock.count, isLast: true))
            file.append(pictureBlock)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        try file.write(to: url)
        tempFile = url
        return url
    }

    func testReadsVorbisCommentTags() throws {
        let url = try writeFLACFile(
            vorbisComments: [
                "TITLE=My Song",
                "ARTIST=My Artist",
                "ALBUM=My Album",
                "ALBUMARTIST=My Album Artist",
                "TRACKNUMBER=7/12",
            ],
            pictureBytes: nil
        )

        let tags = try XCTUnwrap(FLACMetadataReader.read(url: url))

        XCTAssertEqual(tags.title, "My Song")
        XCTAssertEqual(tags.artist, "My Artist")
        XCTAssertEqual(tags.album, "My Album")
        XCTAssertEqual(tags.albumArtist, "My Album Artist")
        XCTAssertEqual(tags.track, 7)
        XCTAssertNil(tags.artworkData)
    }

    func testTagKeysAreCaseInsensitive() throws {
        let url = try writeFLACFile(vorbisComments: ["title=lowercase title", "Album=Mixed Case Album"], pictureBytes: nil)

        let tags = try XCTUnwrap(FLACMetadataReader.read(url: url))

        XCTAssertEqual(tags.title, "lowercase title")
        XCTAssertEqual(tags.album, "Mixed Case Album")
    }

    func testExtractsEmbeddedPicture() throws {
        let fakeImageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        let url = try writeFLACFile(vorbisComments: ["TITLE=Has Art"], pictureBytes: fakeImageBytes)

        let tags = try XCTUnwrap(FLACMetadataReader.read(url: url))

        XCTAssertEqual(tags.artworkData, fakeImageBytes)
    }

    func testMissingTagsReturnNil() throws {
        let url = try writeFLACFile(vorbisComments: [], pictureBytes: nil)

        let tags = try XCTUnwrap(FLACMetadataReader.read(url: url))

        XCTAssertNil(tags.title)
        XCTAssertNil(tags.album)
        XCTAssertNil(tags.artworkData)
    }

    func testReturnsNilForNonFLACFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("not a flac file".utf8).write(to: url)
        tempFile = url

        XCTAssertNil(FLACMetadataReader.read(url: url))
    }
}
