import UIKit

enum ArtworkProcessor {
    /// Sized for the full-screen player, which renders the cover at roughly screen width — a
    /// little over 1000px on a current @3x iPhone.
    static let fullDimension: CGFloat = 1024
    /// Sized for list rows and the mini player (40–44pt, so ~130px at @3x), with headroom.
    /// Kept separate so scrolling a long list doesn't decode full-size JPEGs per row.
    static let thumbnailDimension: CGFloat = 256
    private static let jpegQuality: CGFloat = 0.85

    struct Processed: Equatable {
        let full: Data
        let thumbnail: Data
    }

    /// Produces both stored representations, off the main actor.
    ///
    /// Decoding a JPEG, rendering it at two sizes and re-encoding both is tens to hundreds of
    /// milliseconds each. Done on the main actor for a few hundred albums it locks the interface
    /// up for minutes, which is what made browsing after a sync unusable.
    static func processInBackground(_ data: Data) async -> Processed? {
        await Task.detached(priority: .utility) { process(data) }.value
    }

    /// Produces both stored representations from one decode of the source image.
    static func process(_ data: Data) -> Processed? {
        guard let image = UIImage(data: data) else { return nil }
        guard let full = encode(image, maxDimension: fullDimension),
              let thumbnail = encode(image, maxDimension: thumbnailDimension) else {
            return nil
        }
        return Processed(full: full, thumbnail: thumbnail)
    }

    /// Downscales so the longest edge is at most `maxDimension` (preserving aspect ratio) and
    /// re-encodes as JPEG. Images already within bounds are re-encoded, not upscaled.
    static func resized(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return encode(image, maxDimension: maxDimension)
    }

    private static func encode(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let longestEdge = max(image.size.width, image.size.height)
        let outputImage: UIImage
        if longestEdge <= maxDimension {
            outputImage = image
        } else {
            let scale = maxDimension / longestEdge
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            // Force renderer scale 1 so the encoded JPEG's actual pixel dimensions equal
            // `newSize` exactly — the device/simulator screen scale (e.g. 3x) must not get
            // baked into stored artwork, or the cap would be tripled in practice.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            outputImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return outputImage.jpegData(compressionQuality: jpegQuality)
    }
}
