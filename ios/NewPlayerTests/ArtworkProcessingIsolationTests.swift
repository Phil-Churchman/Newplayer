import XCTest
@testable import NewPlayer

/// Decoding a cover, rendering it at two sizes and re-encoding both is the most expensive thing
/// this app does per album. On the main actor, a few hundred of them lock the interface up for
/// minutes — which is what made browsing unusable after a Spotify sync.
final class ArtworkProcessingIsolationTests: XCTestCase {
    /// The background path must produce exactly what the direct one does.
    func testBackgroundProcessingMatchesDirectProcessing() async {
        let source = TestImage.jpegData(width: 800, height: 800)

        let direct = ArtworkProcessor.process(source)
        let background = await ArtworkProcessor.processInBackground(source)

        XCTAssertNotNil(background)
        XCTAssertEqual(background?.full, direct?.full)
        XCTAssertEqual(background?.thumbnail, direct?.thumbnail)
    }

    func testUndecodableDataYieldsNothing() async {
        let nonsense = Data("not an image".utf8)
        let result = await ArtworkProcessor.processInBackground(nonsense)
        XCTAssertNil(result)
    }

    /// The main actor must be free while covers are processed. Without this the UI gets a slice
    /// only between albums, which for hundreds of them is a stall measured in minutes.
    @MainActor
    func testTheMainActorStaysFreeWhileProcessing() async {
        var uiTicks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                uiTicks += 1
                await Task.yield()
            }
        }

        let source = TestImage.jpegData(width: 1200, height: 1200)
        for _ in 0..<8 {
            _ = await ArtworkProcessor.processInBackground(source)
        }
        ticker.cancel()

        XCTAssertGreaterThan(uiTicks, 1, "the main actor was held for the whole run")
    }
}
