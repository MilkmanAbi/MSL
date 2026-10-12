import XCTest
import CoreGraphics
@testable import MSLCore

/// M10 — `GetImage` answered every drawable at 32 bits per pixel.
///
/// A depth-1 pixmap (window shapes, cursor masks, stipples) and a depth-8
/// one (an A8 coverage mask, which this server's own RENDER path creates
/// constantly) were both misparsed by exactly the byte ratio.
final class X11DepthAwareGetImageTests: XCTestCase {
    /// Alpha is the value for both depths: a depth-1 or depth-8 drawable
    /// here is coverage, and `CGContextClipToMask` reads alpha, not
    /// luminance.
    private func coverageContext(width: Int, height: Int, opaqueColumns: Set<Int>) -> CGContext {
        let ctx = makeFlippedBitmapContext(width: width, height: height)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0, 0, 0, 0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!)
        for column in opaqueColumns {
            ctx.fill(CGRect(x: column, y: 0, width: 1, height: height))
        }
        return ctx
    }

    // MARK: depth 1

    /// One bit per pixel, LSB first, rows padded to 32 bits - the same
    /// stride rule `expandBitmap` demands on the way in.
    func testDepthOnePacksOneBitPerPixel() {
        let ctx = coverageContext(width: 8, height: 1, opaqueColumns: [0, 7])
        let bits = X11Connection.bitmapBytes(from: ctx, sourceWidth: 8, sourceHeight: 1,
                                             x: 0, y: 0, width: 8, height: 1)
        XCTAssertEqual(bits.count, 4, "8 pixels is one byte, padded to a 32-bit unit")
        XCTAssertEqual(bits[0], 0x81, "columns 0 and 7 are bits 0 and 7")
    }

    func testDepthOneRowsPadToThirtyTwoBits() {
        for width in [1, 8, 31, 32, 33, 100] {
            let ctx = coverageContext(width: width, height: 3, opaqueColumns: [])
            let bits = X11Connection.bitmapBytes(from: ctx, sourceWidth: width, sourceHeight: 3,
                                                 x: 0, y: 0, width: width, height: 3)
            XCTAssertEqual(bits.count, ((width + 31) / 32) * 4 * 3, "width \(width)")
        }
    }

    /// Half coverage counts as set, so a mask does not silently vanish at
    /// its antialiased edges.
    func testDepthOneThresholdsAtHalfCoverage() {
        let ctx = makeFlippedBitmapContext(width: 2, height: 1)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 0.6])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 0.4])!)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let bits = X11Connection.bitmapBytes(from: ctx, sourceWidth: 2, sourceHeight: 1,
                                             x: 0, y: 0, width: 2, height: 1)
        XCTAssertEqual(bits[0] & 0x01, 0x01, "60% coverage is set")
        XCTAssertEqual(bits[0] & 0x02, 0x00, "40% coverage is not")
    }

    // MARK: depth 8

    /// One byte per pixel, rows padded to 32 bits, carrying alpha.
    func testDepthEightPacksOneBytePerPixel() {
        let ctx = coverageContext(width: 4, height: 2, opaqueColumns: [0, 2])
        let bytes = X11Connection.eightBitBytes(from: ctx, sourceWidth: 4, sourceHeight: 2,
                                                x: 0, y: 0, width: 4, height: 2)
        XCTAssertEqual(bytes.count, 4 * 2)
        XCTAssertEqual(bytes[0], 255)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[2], 255)
        XCTAssertEqual(bytes[3], 0)
    }

    func testDepthEightRowsPadToFourBytes() {
        let ctx = coverageContext(width: 5, height: 2, opaqueColumns: [])
        let bytes = X11Connection.eightBitBytes(from: ctx, sourceWidth: 5, sourceHeight: 2,
                                                x: 0, y: 0, width: 5, height: 2)
        XCTAssertEqual(bytes.count, 8 * 2, "5 bytes pads to 8")
    }

    /// The ratio that used to be wrong, stated plainly: a depth-1 row is
    /// 32x smaller than the 32bpp answer it used to get, and a depth-8 row
    /// 4x smaller.
    func testTheByteRatiosThatUsedToBeWrong() {
        let width = 32
        let ctx = coverageContext(width: width, height: 1, opaqueColumns: [])
        let asBits = X11Connection.bitmapBytes(from: ctx, sourceWidth: width, sourceHeight: 1,
                                               x: 0, y: 0, width: width, height: 1)
        let asBytes = X11Connection.eightBitBytes(from: ctx, sourceWidth: width, sourceHeight: 1,
                                                  x: 0, y: 0, width: width, height: 1)
        let asPixels = X11Connection.zPixmapBytes(from: ctx, sourceWidth: width, sourceHeight: 1,
                                                  x: 0, y: 0, width: width, height: 1, includeAlpha: true)
        XCTAssertEqual(asPixels.count, asBits.count * 32)
        XCTAssertEqual(asPixels.count, asBytes.count * 4)
    }
}
