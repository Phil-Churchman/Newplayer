import Foundation
import SwiftData

@Model
final class Artist {
    var name: String
    var source: Source?

    @Relationship(deleteRule: .cascade, inverse: \Album.artist)
    var albums: [Album] = []

    init(name: String, source: Source? = nil) {
        self.name = name
        self.source = source
    }
}
