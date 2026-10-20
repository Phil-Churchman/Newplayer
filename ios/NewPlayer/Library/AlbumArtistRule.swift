import Foundation

/// How every source decides the one artist name an album groups under.
///
/// `LibraryRowBuilder` builds its Album and Artist rows from `RawSong.albumArtist` alone, so
/// this name is what the Albums and Artists lists show. Each track keeps its own performer on
/// `RawSong.artist`, which varies freely within an album and changes no grouping.
///
/// The rule reads the album-artist *tag*, not the track artists. An earlier version called an
/// album a compilation whenever its tracks credited more than one performer, which mislabelled
/// any record with a guest or a "feat." credit on it — and on the Apple Music source it also
/// overwrote each track's own artist, so who actually played a song was lost at import.
enum AlbumArtistRule {
    static let compilation = "Compilation"
    static let unknown = "Unknown Artist"

    /// The grouping artist for one album, from its tracks' album-artist tags and, failing
    /// those, their own performers.
    ///
    /// In order:
    ///
    /// - the album artist the tracks agree on;
    /// - "Compilation" when the album artists they do carry disagree;
    /// - with no album artist anywhere, the performer every track names — an untagged record by
    ///   one artist is that artist's, not a compilation, and file-based libraries are routinely
    ///   tagged that way;
    /// - "Unknown Artist" when nothing is named at all, which is an untagged file rather than
    ///   a compilation;
    /// - "Compilation" otherwise, meaning the performers themselves disagree.
    ///
    /// Absent album-artist tags are ignored rather than counted as disagreement: a single
    /// untagged track on an otherwise consistent album is a gap in the tagging, not a second
    /// artist. The track artists are consulted only when *no* track carries an album artist —
    /// a record that names one has answered the question.
    ///
    /// Compared with surrounding whitespace trimmed, so a stray trailing space is not a
    /// different artist. Case is *not* folded — "ABBA" and "Abba" are left to disagree, because
    /// deciding they are the same name means choosing which spelling to show.
    static func groupingArtist(albumArtists: [String?], trackArtists: [String?]) -> String {
        let named = Set(albumArtists.compactMap { trimmed($0) })
        if named.count == 1, let only = named.first { return only }
        if named.isEmpty {
            let performers = Set(trackArtists.compactMap { trimmed($0) })
            if performers.count == 1, let only = performers.first { return only }
            // Nothing named anywhere is not a compilation — it is an untagged file, and saying
            // so is both truer and what the song itself already shows.
            if performers.isEmpty { return unknown }
        }
        return compilation
    }

    /// The name to show for one track: its own performer, falling back to the album's.
    static func trackArtist(_ artist: String?, inAlbumBy albumArtist: String) -> String {
        trimmed(artist) ?? albumArtist
    }

    /// The album title a track files under.
    static func albumTitle(_ title: String?) -> String {
        trimmed(title) ?? "Unknown Album"
    }

    /// Splits the tracks sharing one album title into the albums they actually belong to.
    ///
    /// Two tracks are the same album when they share a non-empty album **id** or a non-empty
    /// album **artist**, followed transitively. Neither field alone is enough:
    ///
    /// - Ids vary *within* one album. Apple Music gives different ones to tracks added by
    ///   different routes — purchased, matched, uploaded — and Spotify's per-market relinking
    ///   hands one release back under different ids. Grouping on the id split a single album.
    /// - Album artists vary within one album too, which is exactly the case that should come
    ///   out as a compilation. Grouping on the artist made that disagreement invisible, because
    ///   tracks that disagreed were never in the same group to be compared.
    ///
    /// Linking on either, and then letting `groupingArtist` rename the whole component, keeps a
    /// record together in both cases. Two different albums that merely share a title — a
    /// "Greatest Hits" each — share neither field, so they stay apart.
    ///
    /// Sources with no album id of their own pass the containing folder instead, which is where
    /// a file-based library draws an album's boundary.
    static func albumComponents<Track>(
        _ tracks: [Track],
        id: (Track) -> String?,
        albumArtist: (Track) -> String?
    ) -> [[Track]] {
        // Union-find over the track indices.
        var parent = Array(tracks.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[rb] = ra }
        }

        // Tracks carrying neither field cannot be linked by one, so they share a sentinel and
        // become one album rather than one album each.
        var firstHolder: [String: Int] = [:]
        for (index, track) in tracks.enumerated() {
            var links = [trimmed(id(track)).map { "id\u{0}\($0)" },
                         trimmed(albumArtist(track)).map { "artist\u{0}\($0)" }]
                .compactMap { $0 }
            if links.isEmpty { links = ["untagged"] }

            for link in links {
                if let seen = firstHolder[link] { union(seen, index) } else { firstHolder[link] = index }
            }
        }

        var byRoot: [Int: [Track]] = [:]
        for (index, track) in tracks.enumerated() {
            byRoot[root(index), default: []].append(track)
        }
        return Array(byRoot.values)
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
