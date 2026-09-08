import Foundation

enum FolderBookmarkError: Error {
    case noFolderChosen
    case resolveFailed
    case accessDenied
}

enum FolderBookmarkStore {
    /// Creates bookmark data for a freshly-picked folder URL.
    static func makeBookmark(for url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        return try url.bookmarkData()
    }

    /// Resolves a source's stored bookmark to a URL, refreshing the bookmark if it was stale.
    /// The caller is responsible for calling `startAccessingSecurityScopedResource()` /
    /// `stopAccessingSecurityScopedResource()` around actual use of the returned URL.
    static func resolveURL(for source: Source) throws -> URL {
        guard let data = source.bookmarkData else {
            throw FolderBookmarkError.noFolderChosen
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            source.bookmarkData = try? makeBookmark(for: url)
        }
        return url
    }
}
