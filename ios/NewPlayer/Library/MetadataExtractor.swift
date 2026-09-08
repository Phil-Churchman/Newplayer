import AVFoundation
import Foundation

struct ExtractedMetadata {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var track: Int
    var duration: TimeInterval
    var artworkData: Data?
}

enum MetadataExtractor {
    // AVFoundation has natively decoded FLAC since iOS 11, so it's included here. FLAC's own
    // tags/artwork are read via FLACMetadataReader rather than AVFoundation's metadata APIs —
    // see that file's header comment for why.
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    static func extract(url: URL) async -> ExtractedMetadata {
        let asset = AVURLAsset(url: url)
        let filenameFallback = url.deletingPathExtension().lastPathComponent

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var track: Int?
        var artworkData: Data?

        if url.pathExtension.lowercased() == "flac", let flacTags = FLACMetadataReader.read(url: url) {
            title = flacTags.title
            artist = flacTags.artist
            album = flacTags.album
            albumArtist = flacTags.albumArtist
            track = flacTags.track
            artworkData = flacTags.artworkData
        } else {
            (title, artist, album, albumArtist, track, artworkData) = await extractViaAVFoundation(asset: asset)
        }

        var duration: TimeInterval = 0
        if let loadedDuration = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(loadedDuration)
            if duration.isNaN || duration.isInfinite {
                duration = 0
            }
        }

        let resolvedTitle = nonBlank(title) ?? filenameFallback
        let resolvedArtist = nonBlank(artist) ?? "Unknown Artist"
        let resolvedAlbum = nonBlank(album) ?? "Unknown Album"
        let resolvedAlbumArtist = nonBlank(albumArtist) ?? resolvedArtist

        return ExtractedMetadata(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            albumArtist: resolvedAlbumArtist,
            track: track ?? 0,
            duration: duration,
            artworkData: artworkData
        )
    }

    private static func extractViaAVFoundation(
        asset: AVURLAsset
    ) async -> (title: String?, artist: String?, album: String?, albumArtist: String?, track: Int?, artworkData: Data?) {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var track: Int?
        var artworkData: Data?

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    artworkData = await loadData(from: item)
                default:
                    break
                }
            }
        }

        // Format-specific metadata for fields AVFoundation doesn't expose via commonMetadata.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    guard let keyString = item.key as? String ?? (item.identifier?.rawValue) else { continue }
                    let lowerKey = keyString.lowercased()
                    if albumArtist == nil, lowerKey.contains("albumartist") || lowerKey.contains("aart") || lowerKey.contains("tpe2") {
                        albumArtist = try? await item.load(.stringValue)
                    }
                    if album == nil, lowerKey == "album" || lowerKey.contains("talb") {
                        album = try? await item.load(.stringValue)
                    }
                    if track == nil, lowerKey.contains("tracknumber") || lowerKey.contains("trkn") || lowerKey.contains("trck") {
                        if let stringValue = try? await item.load(.stringValue) {
                            track = parseTrackNumber(from: stringValue)
                        } else if let numberValue = try? await item.load(.numberValue) {
                            track = numberValue.intValue
                        }
                    }
                    if artworkData == nil,
                       lowerKey.contains("artwork") || lowerKey.contains("covr") || lowerKey.contains("apic") || lowerKey.contains("picture") {
                        artworkData = await loadData(from: item)
                    }
                }
            }
        }

        return (title, artist, album, albumArtist, track, artworkData)
    }

    /// Some formats don't populate `dataValue` reliably; fall back to the generic `value`
    /// property, which AVFoundation may expose as `Data`.
    private static func loadData(from item: AVMetadataItem) async -> Data? {
        if let data = try? await item.load(.dataValue) {
            return data
        }
        if let value = try? await item.load(.value) {
            return value as? Data
        }
        return nil
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseTrackNumber(from string: String) -> Int? {
        // Handles "3", "3/12" style track-number strings.
        let firstComponent = string.split(separator: "/").first ?? Substring(string)
        return Int(firstComponent.trimmingCharacters(in: .whitespaces))
    }
}
