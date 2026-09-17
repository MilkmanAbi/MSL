import XCTest
import CoreGraphics
@testable import MSLCore

final class X11ShapeMaskTests: XCTestCase {
    /// A depth-1 mask as xeyes builds it: clear with foreground 0, then draw
    /// with foreground 1 (0x000001).
    private func maskPixmap(width: Int, height: Int, inside: CGRect) -> CGContext {
        let ctx = makeFlippedBitmapContext(width: width, height: height)
        ctx.setFillColor(x11Color(red: 0, green: 0, blue: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(x11Color(red: 0, green: 0, blue: 1.0 / 255))
        ctx.fill(inside)
        return ctx
    }

    private func alpha(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    func testSetBitsAreInsideAndTopLeftOriented() {
        // Inside = the top-left 4x2 block of a 10x6 mask.
        let pixmap = maskPixmap(width: 10, height: 6, inside: CGRect(x: 0, y: 0, width: 4, height: 2))
        let out = X11Connection.shapeMaskRGBA(from: pixmap, sourceWidth: 10, sourceHeight: 6, width: 10, height: 6, xOffset: 0, yOffset: 0)
        XCTAssertEqual(alpha(out, width: 10, x: 0, y: 0), 255)
        XCTAssertEqual(alpha(out, width: 10, x: 3, y: 1), 255)
        XCTAssertEqual(alpha(out, width: 10, x: 4, y: 1), 0)
        XCTAssertEqual(alpha(out, width: 10, x: 0, y: 2), 0)
        XCTAssertEqual(alpha(out, width: 10, x: 9, y: 5), 0, "foreground-0 (black) pixels are outside")
    }

    func testOffsetShiftsTheMaskAndUncoveredAreaIsOutside() {
        let pixmap = maskPixmap(width: 4, height: 4, inside: CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = X11Connection.shapeMaskRGBA(from: pixmap, sourceWidth: 4, sourceHeight: 4, width: 10, height: 10, xOffset: 3, yOffset: 5)
        XCTAssertEqual(alpha(out, width: 10, x: 2, y: 5), 0)
        XCTAssertEqual(alpha(out, width: 10, x: 3, y: 5), 255)
        XCTAssertEqual(alpha(out, width: 10, x: 6, y: 8), 255)
        XCTAssertEqual(alpha(out, width: 10, x: 7, y: 8), 0)
        XCTAssertEqual(alpha(out, width: 10, x: 3, y: 9), 0)
    }

    func testNeverDrawnPixmapIsEntirelyOutside() {
        let blank = makeFlippedBitmapContext(width: 5, height: 5)
        let out = X11Connection.shapeMaskRGBA(from: blank, sourceWidth: 5, sourceHeight: 5, width: 5, height: 5, xOffset: 0, yOffset: 0)
        XCTAssertEqual(out.max(), 0)
    }

    func testMaskRowsMatchContentImageRows() {
        // The view draws the mask through the same transform as
        // `bitmapContext.makeImage()`, so row 0 of both must be the same
        // X11 row. Content: top row red. Mask: top row inside.
        let content = makeFlippedBitmapContext(width: 3, height: 3)
        content.setFillColor(x11Color(red: 1, green: 0, blue: 0))
        content.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
        let contentImage = content.makeImage()!
        let contentRow0Red = (contentImage.dataProvider!.data! as Data)[0]

        let pixmap = maskPixmap(width: 3, height: 3, inside: CGRect(x: 0, y: 0, width: 3, height: 1))
        let out = X11Connection.shapeMaskRGBA(from: pixmap, sourceWidth: 3, sourceHeight: 3, width: 3, height: 3, xOffset: 0, yOffset: 0)
        XCTAssertEqual(contentRow0Red, 255)
        XCTAssertEqual(alpha(out, width: 3, x: 0, y: 0), 255)
        XCTAssertEqual(alpha(out, width: 3, x: 0, y: 2), 0)
    }
}
