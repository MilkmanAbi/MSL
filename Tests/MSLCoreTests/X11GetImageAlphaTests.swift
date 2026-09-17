import XCTest
import CoreGraphics
@testable import MSLCore

/// GetImage on a depth-32 (ARGB) pixmap must return alpha. GTK3 reads a
/// popover's outline back from a depth-32 surface to build its clickable
/// shape; with the alpha byte always 0 the shape was empty and no popover
/// menu item could be clicked.
final class X11GetImageAlphaTests: XCTestCase {
    private func semiTransparentContext() -> CGContext {
        let ctx = makeFlippedBitmapContext(width: 4, height: 2)
        // Straight (r .5, g .25, b 1, a .5) -> stored premultiplied.
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.5, 0.25, 1.0, 0.5])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return ctx
    }

    func testDepth32ReturnsPremultipliedBGRA() {
        let bytes = X11Connection.zPixmapBytes(from: semiTransparentContext(), sourceWidth: 4, sourceHeight: 2,
                                               x: 0, y: 0, width: 4, height: 2, includeAlpha: true)
        XCTAssertEqual(bytes.count, 16 * 2)
        XCTAssertEqual(Int(bytes[3]), 128, accuracy: 1, "alpha")
        XCTAssertEqual(Int(bytes[0]), 128, accuracy: 1, "blue, premultiplied")
        XCTAssertEqual(Int(bytes[1]), 32, accuracy: 1, "green, premultiplied")
        XCTAssertEqual(Int(bytes[2]), 64, accuracy: 1, "red, premultiplied")
    }

    func testDepth24KeepsTheZeroPad() {
        let bytes = X11Connection.zPixmapBytes(from: semiTransparentContext(), sourceWidth: 4, sourceHeight: 2,
                                               x: 0, y: 0, width: 4, height: 2, includeAlpha: false)
        XCTAssertEqual(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max(), 0)
        XCTAssertEqual(Int(bytes[0]), 128, accuracy: 1, "colour bytes unchanged")
    }

    func testPopoverOutlineReadsBackAsANonEmptyShape() {
        // A rounded outline on a transparent depth-32 surface, like
        // gtk_popover_fill_border_path.
        let ctx = makeFlippedBitmapContext(width: 40, height: 30)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0, 0, 0, 1])!)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 4, y: 6, width: 32, height: 20), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        let withAlpha = X11Connection.zPixmapBytes(from: ctx, sourceWidth: 40, sourceHeight: 30, x: 0, y: 0, width: 40, height: 30, includeAlpha: true)
        let opaque = stride(from: 3, to: withAlpha.count, by: 4).filter { withAlpha[$0] > 0 }.count
        XCTAssertGreaterThan(opaque, 500, "the shape region cairo builds from alpha must not be empty")
        // Corners outside the rounded rect stay transparent.
        XCTAssertEqual(withAlpha[3], 0)
    }

    func testOutOfBoundsRegionIsZeroFilled() {
        let bytes = X11Connection.zPixmapBytes(from: semiTransparentContext(), sourceWidth: 4, sourceHeight: 2,
                                               x: 10, y: 10, width: 2, height: 2, includeAlpha: true)
        XCTAssertEqual(bytes.max(), 0)
        XCTAssertEqual(bytes.count, 16)
    }
}
