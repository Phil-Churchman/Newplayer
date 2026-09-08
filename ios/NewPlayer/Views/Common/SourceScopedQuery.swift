import Foundation
import SwiftData

/// Predicates scoping the library views to the active source.
///
/// These match on the source's identifier rather than on `source.isActive`. Filtering by a
/// *related* object's property means switching sources mutates only `Source` rows, touching no
/// Song/Album/Artist row — and `@Query` invalidation keys off changes to the entity being
/// queried, so those lists kept showing the previous mode's content until something unrelated
/// forced a refresh. Passing the id in instead means the query itself changes identity when the
/// active source changes, so SwiftUI rebuilds it immediately.
///
/// A nil id matches only rows with no source at all (there are none in practice), which is the
/// desired "nothing to show" state.
enum SourceScopedQuery {
    static func songs(inSourceWithID sourceID: PersistentIdentifier?) -> Predicate<Song> {
        #Predicate<Song> { $0.source?.persistentModelID == sourceID }
    }

    static func albums(inSourceWithID sourceID: PersistentIdentifier?) -> Predicate<Album> {
        #Predicate<Album> { $0.source?.persistentModelID == sourceID }
    }

    static func artists(inSourceWithID sourceID: PersistentIdentifier?) -> Predicate<Artist> {
        #Predicate<Artist> { $0.source?.persistentModelID == sourceID }
    }
}
