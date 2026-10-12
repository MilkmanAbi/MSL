import XCTest
@testable import MSLCore

/// `CopyArea` must tell a client which part of the destination its source
/// could not fill. Getting this wrong is invisible in a screenshot and shows
/// up as pixels that never repaint, so the geometry is pinned here.
final class CopyAreaExposeTests: XCTestCase {
    private func rects(srcX: Int, srcY: Int, w: Int, h: Int,
                       srcW: Int = 100, srcH: Int = 100)
        -> [(x: Int, y: Int, w: Int, h: Int)] {
        X11Connection.uncoveredDestinationRects(
            srcX: srcX, srcY: srcY, dstX: 0, dstY: 0, w: w, h: h,
            sourceWidth: srcW, sourceHeight: srcH)
    }

    func testAFullyContainedCopyLeavesNothingUncovered() {
        XCTAssertTrue(rects(srcX: 10, srcY: 10, w: 20, h: 20).isEmpty)
    }

    func testACopyFlushWithTheSourceEdgeIsStillFullyCovered() {
        XCTAssertTrue(rects(srcX: 80, srcY: 80, w: 20, h: 20).isEmpty)
    }

    func testOverhangingTheRightEdgeUncoversOnlyTheStripBeyondIt() {
        let out = rects(srcX: 90, srcY: 0, w: 20, h: 10)
        XCTAssertEqual(out.count, 1)
        // 10 columns existed, 10 did not - and the uncovered strip is in
        // DESTINATION coordinates, which start at 0 here.
        XCTAssertEqual(out[0].x, 10)
        XCTAssertEqual(out[0].w, 10)
        XCTAssertEqual(out[0].h, 10)
    }

    func testANegativeOriginUncoversTheStripBeforeTheSourceBegins() {
        let out = rects(srcX: -5, srcY: 0, w: 20, h: 10)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].x, 0)
        XCTAssertEqual(out[0].w, 5)
    }

    func testAWhollyOutsideSourceUncoversTheEntireDestination() {
        let out = rects(srcX: 500, srcY: 500, w: 30, h: 40)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].w, 30)
        XCTAssertEqual(out[0].h, 40)
    }

    func testOverhangingTwoEdgesUncoversTwoStripsThatDoNotOverlap() {
        let out = rects(srcX: 95, srcY: 95, w: 10, h: 10)
        XCTAssertEqual(out.count, 2)
        let area = out.reduce(0) { $0 + $1.w * $1.h }
        // 10x10 asked for, a 5x5 corner existed.
        XCTAssertEqual(area, 100 - 25)
    }

    func testAZeroSizedCopyUncoversNothing() {
        XCTAssertTrue(rects(srcX: 500, srcY: 500, w: 0, h: 0).isEmpty)
    }
}
