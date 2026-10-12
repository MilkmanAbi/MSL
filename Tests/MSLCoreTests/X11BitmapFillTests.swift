import XCTest
import CoreGraphics
@testable import MSLCore

/// A depth-1 pixmap's single bit lives in the ALPHA channel - every reader of
/// a bitmap looks there (`CopyPlane`, the A1/A8 mask formats, and
/// `CGContextClipToMask`, which uses alpha and not luminance).
///
/// Measured against a real X server (xdiff `draw.copy_plane`, 2026-09-28):
/// filling a mask with foreground 0 left every bit SET, so clearing part of a
/// mask did nothing and stipples, icon masks and shapes all came out solid.
/// Two things had to be true, and both are pinned here.
final class X11BitmapFillTests: XCTestCase {
    func testClearedBitIsFullyTransparentOnABitmap() {
        let clear = x11PixelColor(0, isBitmap: true)
        XCTAssertEqual(clear.alpha, 0, "a cleared bit must be alpha 0, not black-but-opaque")
        let set = x11PixelColor(1, isBitmap: true)
        XCTAssertEqual(set.alpha, 1)
        // Only the low bit counts on a depth-1 drawable.
        XCTAssertEqual(x11PixelColor(0xFFFF_FFFE, isBitmap: true).alpha, 0)
        XCTAssertEqual(x11PixelColor(0x00FF_00FF, isBitmap: true).alpha, 1)
    }

    func testColourPixelsAreUnchangedAndOpaque() {
        let red = x11PixelColor(0xFF0000, isBitmap: false)
        XCTAssertEqual(red.alpha, 1)
        XCTAssertEqual(red.components?[0], 1)
        XCTAssertEqual(red.components?[1], 0)
        XCTAssertEqual(red.components?[2], 0)
    }

    /// Painting alpha 0 with source-over changes nothing at all, so a bitmap
    /// fill has to REPLACE. This is the half that actually made the pixels
    /// wrong once the colour was right.
    func testBitmapFillsReplaceRatherThanCompose() {
        XCTAssertEqual(X11Connection.blendMode(forFunction: 3, isBitmap: true), .copy)
        XCTAssertEqual(X11Connection.blendMode(forFunction: 3, isBitmap: false), .normal)
        // GXxor stays XOR on both - a bitmap does not change what the
        // function means.
        XCTAssertEqual(X11Connection.blendMode(forFunction: 6, isBitmap: true), .difference)
        XCTAssertEqual(X11Connection.blendMode(forFunction: 6, isBitmap: false), .difference)
    }
}
