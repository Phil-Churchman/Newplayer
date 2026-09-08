import Foundation

/// Pure parsing of MPD's line-based "key: value" text protocol responses, kept free of any
/// networking so it can be unit tested without a live server.
enum MPDResponseParser {
    static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
        let valueStart = line.index(after: colonIndex)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Parses a `listallinfo`-style response into songs. Each `file:` line starts a new song
    /// record; subsequent lines add tags to it until the next `file:`/`directory:` line.
    /// `directory:` entries (and any lines before the first `file:`) are ignored.
    static func parseSongs(fromLines lines: [String]) -> [MPDSongInfo] {
        var songs: [MPDSongInfo] = []
        var current: [String: String]?

        func flush() {
            guard let fields = current, let file = fields["file"] else { return }
            let track = fields["Track"].flatMap { rawTrack -> Int? in
                let firstComponent = rawTrack.split(separator: "/").first.map(String.init) ?? rawTrack
                return Int(firstComponent.trimmingCharacters(in: .whitespaces))
            }
            let duration = fields["duration"].flatMap(Double.init) ?? fields["Time"].flatMap(Double.init) ?? 0
            songs.append(MPDSongInfo(
                file: file,
                title: fields["Title"],
                artist: fields["Artist"],
                album: fields["Album"],
                albumArtist: fields["AlbumArtist"],
                track: track,
                duration: duration
            ))
        }

        for line in lines {
            guard let (key, value) = parseKeyValue(line) else { continue }
            if key == "file" {
                flush()
                current = ["file": value]
            } else if key == "directory" {
                flush()
                current = nil
            } else {
                current?[key] = value
            }
        }
        flush()
        return songs
    }

    static func parseStatus(fromLines lines: [String]) -> MPDStatus {
        var dict: [String: String] = [:]
        for line in lines {
            if let (key, value) = parseKeyValue(line) {
                dict[key] = value
            }
        }
        return MPDStatus(
            state: dict["state"] ?? "stop",
            elapsed: dict["elapsed"].flatMap(Double.init) ?? 0,
            duration: dict["duration"].flatMap(Double.init) ?? 0,
            songPosition: dict["song"].flatMap(Int.init),
            isUpdatingDatabase: dict["updating_db"] != nil,
            playlistVersion: dict["playlist"].flatMap(Int.init)
        )
    }
}
