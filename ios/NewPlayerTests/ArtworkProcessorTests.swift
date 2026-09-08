import XCTest
import UIKit
@testable import NewPlayer

final class ArtworkProcessorTests: XCTestCase {
    private func makeImageData(width: CGFloat, height: CGFloat) -> Data {
        // Force scale 1 so the rendered PNG's pixel dimensions exactly match the requested
        // size — UIImage(data:) decodes at scale 1.0, and the simulator's default renderer
        // scale (e.g. 3x) would otherwise inflate the "input" fixture.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }

    private func size(of data: Data) throws -> CGSize {
        try XCTUnwrap(UIImage(data: data)).size
    }

    func testProducesBothAFullSizeAndAThumbnailRendition() throws {
        let data = makeImageData(width: 3000, height: 3000)
        let processed = try XCTUnwrap(ArtworkProcessor.process(data))

        let fullSize = try size(of: processed.full)
        XCTAssertEqual(fullSize.width, ArtworkProcessor.fullDimension, accuracy: 1)
        XCTAssertEqual(fullSize.height, ArtworkProcessor.fullDimension, accuracy: 1)

        let thumbnailSize = try size(of: processed.thumbnail)
        XCTAssertEqual(thumbnailSize.width, ArtworkProcessor.thumbnailDimension, accuracy: 1)
        XCTAssertEqual(thumbnailSize.height, ArtworkProcessor.thumbnailDimension, accuracy: 1)

        XCTAssertLessThan(processed.thumbnail.count, processed.full.count)
    }

    func testPreservesAspectRatioOnBothRenditions() throws {
        let data = makeImageData(width: 2000, height: 1000)
        let processed = try XCTUnwrap(ArtworkProcessor.process(data))

        let fullSize = try size(of: processed.full)
        XCTAssertEqual(fullSize.width, 1024, accuracy: 1)
        XCTAssertEqual(fullSize.height, 512, accuracy: 1)

        let thumbnailSize = try size(of: processed.thumbnail)
        XCTAssertEqual(thumbnailSize.width, 256, accuracy: 1)
        XCTAssertEqual(thumbnailSize.height, 128, accuracy: 1)
    }

    func testDoesNotUpscaleImagesSmallerThanTheTargets() throws {
        let data = makeImageData(width: 100, height: 200)
        let processed = try XCTUnwrap(ArtworkProcessor.process(data))

        let fullSize = try size(of: processed.full)
        XCTAssertEqual(fullSize.width, 100, accuracy: 1)
        XCTAssertEqual(fullSize.height, 200, accuracy: 1)

        let thumbnailSize = try size(of: processed.thumbnail)
        XCTAssertEqual(thumbnailSize.width, 100, accuracy: 1)
        XCTAssertEqual(thumbnailSize.height, 200, accuracy: 1)
    }

    func testReturnsNilForInvalidData() {
        XCTAssertNil(ArtworkProcessor.process(Data([0x00, 0x01, 0x02])))
    }
}
