import Foundation

struct FLACTags {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var track: Int?
    var artworkData: Data?
}

/// Reads tags and cover art directly from a FLAC file's own metadata blocks (VORBIS_COMMENT
/// and PICTURE), bypassing AVFoundation's metadata APIs — which reliably decode FLAC audio but
/// have proven unreliable at surfacing its tags (album name in particular) and picture block
/// through the common/format-specific AVMetadataItem interfaces. The FLAC container format is
/// simple and fully documented, so parsing it directly is more robust than guessing at
/// AVFoundation's undocumented key names.
///
/// Reference: https://xiph.org/flac/format.html
enum FLACMetadataReader {
    private static let magic = Data("fLaC".utf8)
    private static let vorbisCommentBlockType: UInt8 = 4
    private static let pictureBlockType: UInt8 = 6

    static func read(url: URL) -> FLACTags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard (try? handle.read(upToCount: 4)) == magic else { return nil }

        var tags = FLACTags()
        var isLastBlock = false

        while !isLastBlock {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let headerByte = header[header.startIndex]
            isLastBlock = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])

            guard length >= 0, let block = try? handle.read(upToCount: length), block.count == length else {
                break
            }

            switch blockType {
            case vorbisCommentBlockType:
                parseVorbisComment(block, into: &tags)
            case pictureBlockType:
                if tags.artworkData == nil {
                    tags.artworkData = parsePicture(block)
                }
            default:
                break
            }
        }

        return tags
    }

    // MARK: - VORBIS_COMMENT (little-endian lengths, per Vorbis spec)

    private static func parseVorbisComment(_ data: Data, into tags: inout FLACTags) {
        var offset = 0
        guard let vendorLength = readUInt32LE(data, offset) else { return }
        offset += 4 + Int(vendorLength)

        guard let commentCount = readUInt32LE(data, offset) else { return }
        offset += 4

        for _ in 0..<commentCount {
            guard let commentLength = readUInt32LE(data, offset) else { break }
            offset += 4
            let length = Int(commentLength)
            guard offset + length <= data.count else { break }
            let start = data.startIndex + offset
            let commentBytes = data.subdata(in: start..<(start + length))
            offset += length

            guard let commentString = String(data: commentBytes, encoding: .utf8),
                  let equalsIndex = commentString.firstIndex(of: "=") else { continue }
            let key = String(commentString[..<equalsIndex]).uppercased()
            let value = String(commentString[commentString.index(after: equalsIndex)...])
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE": if tags.title == nil { tags.title = value }
            case "ARTIST": if tags.artist == nil { tags.artist = value }
            case "ALBUM": if tags.album == nil { tags.album = value }
            case "ALBUMARTIST", "ALBUM ARTIST": if tags.albumArtist == nil { tags.albumArtist = value }
            case "TRACKNUMBER": if tags.track == nil { tags.track = parseTrackNumber(value) }
            default: break
            }
        }
    }

    private static func parseTrackNumber(_ value: String) -> Int? {
        let firstComponent = value.split(separator: "/").first.map(String.init) ?? value
        return Int(firstComponent.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - PICTURE (big-endian lengths, per FLAC spec)

    private static func parsePicture(_ data: Data) -> Data? {
        var offset = 4 // picture type — unused, we take whichever picture block appears first
        guard let mimeLength = readUInt32BE(data, offset) else { return nil }
        offset += 4 + Int(mimeLength)

        guard let descriptionLength = readUInt32BE(data, offset) else { return nil }
        offset += 4 + Int(descriptionLength)

        offset += 16 // width, height, color depth, colors-used — all unused, skip

        guard let pictureDataLength = readUInt32BE(data, offset) else { return nil }
        offset += 4
        let length = Int(pictureDataLength)
        guard length > 0, offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + length))
    }

    // MARK: - Byte helpers

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }
}
