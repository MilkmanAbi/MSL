import XCTest
import CoreGraphics
@testable import MSLCore

/// F4 — the GC model stored four of twenty-three components.
///
/// The two that matter most: `clip-x/y-origin`, which is on the GTK/Qt
/// path, and `function`, where `GXxor` drawn as `GXcopy` leaves artifacts
/// by construction rather than by accident.
final class X11GCComponentTests: XCTestCase {
    // MARK: clip origin

    /// The rectangles are stored as sent and moved by the origin when
    /// read, so a later `XSetClipOrigin` actually moves them. Baking the
    /// origin in at set time is correct exactly once - and a toolkit
    /// reusing one GC across widgets sets the rectangles once and then
    /// shifts them per widget.
    func testTheClipOriginMovesTheRectangles() {
        let gc = X11State.GCRecord(id: 1)
        gc.clipRectanglesRaw = [CGRect(x: 10, y: 20, width: 30, height: 40)]

        XCTAssertEqual(gc.clipRectangles, [CGRect(x: 10, y: 20, width: 30, height: 40)])

        gc.clipOrigin = CGPoint(x: 100, y: 200)
        XCTAssertEqual(gc.clipRectangles, [CGRect(x: 110, y: 220, width: 30, height: 40)],
                       "the origin shifts the rectangles, it does not replace them")

        gc.clipOrigin = CGPoint(x: -5, y: -5)
        XCTAssertEqual(gc.clipRectangles, [CGRect(x: 5, y: 15, width: 30, height: 40)],
                       "a negative origin is legal")
    }

    /// No clip is still no clip, whatever the origin says.
    func testAnUnclippedGCStaysUnclipped() {
        let gc = X11State.GCRecord(id: 1)
        gc.clipOrigin = CGPoint(x: 50, y: 50)
        XCTAssertNil(gc.clipRectangles)
    }

    /// Setting through the computed property (what every existing call
    /// site does) means "these exact rectangles", so the origin resets.
    func testAssigningRectanglesDirectlyClearsTheOrigin() {
        let gc = X11State.GCRecord(id: 1)
        gc.clipOrigin = CGPoint(x: 100, y: 100)
        gc.clipRectangles = [CGRect(x: 1, y: 2, width: 3, height: 4)]
        XCTAssertEqual(gc.clipOrigin, .zero)
        XCTAssertEqual(gc.clipRectangles, [CGRect(x: 1, y: 2, width: 3, height: 4)])
    }

    // MARK: function

    /// `GXcopy` is the default and must stay ordinary drawing.
    func testTheDefaultFunctionIsPlainDrawing() {
        XCTAssertEqual(X11State.GCRecord(id: 1).function, 3, "GXcopy")
        XCTAssertEqual(X11Connection.blendMode(forFunction: 3), .normal)
    }

    /// `GXxor` (6) must be an involution: drawing the same mark twice has
    /// to restore what was underneath, because that is the entire idiom -
    /// draw once to show a rubber band or caret, draw again to erase it.
    func testXorIsAnInvolution() {
        XCTAssertEqual(X11Connection.blendMode(forFunction: 6), .difference)

        let ctx = makeFlippedBitmapContext(width: 4, height: 1)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.25, 0.5, 0.75, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        let original = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: 16), count: 16))

        // Draw a white mark twice with the XOR blend.
        for _ in 0..<2 {
            ctx.saveGState()
            ctx.setBlendMode(X11Connection.blendMode(forFunction: 6))
            ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
            ctx.restoreGState()
        }
        let after = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: 16), count: 16))

        for (index, (a, b)) in zip(original, after).enumerated() {
            XCTAssertEqual(Int(a), Int(b), accuracy: 1, "byte \(index) must come back")
        }
    }

    /// And a single draw must actually change something, or "erasing"
    /// would be indistinguishable from never drawing.
    func testASingleXorDrawIsVisible() {
        let ctx = makeFlippedBitmapContext(width: 2, height: 1)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.25, 0.25, 0.25, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let before = ctx.data!.bindMemory(to: UInt8.self, capacity: 8)[0]

        ctx.setBlendMode(X11Connection.blendMode(forFunction: 6))
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let after = ctx.data!.bindMemory(to: UInt8.self, capacity: 8)[0]

        XCTAssertNotEqual(before, after)
    }

    // MARK: function on the blits

    /// `CopyArea` and `PutImage` blit an IMAGE, not a fill, and ignored the
    /// GC function entirely. Through `withFunction`, an XOR blit of the same
    /// tile twice must restore what was underneath - the same involution
    /// the fills above rely on.
    func testAnXorImageBlitUndoesItself() {
        let ctx = makeFlippedBitmapContext(width: 4, height: 1)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.25, 0.5, 0.75, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        let original = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: 16), count: 16))

        let tile = Self.whiteTile(width: 4, height: 1)
        for _ in 0..<2 {
            X11Connection.withFunction(6, on: ctx) {
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: 4, height: 1))
            }
        }
        let after = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: 16), count: 16))
        for (index, (a, b)) in zip(original, after).enumerated() {
            XCTAssertEqual(Int(a), Int(b), accuracy: 1, "byte \(index) must come back")
        }
    }

    /// `GXcopy` through the same seam stays an ordinary replace, and leaves
    /// the blend mode exactly as it found it.
    func testACopyBlitStillReplaces() {
        let ctx = makeFlippedBitmapContext(width: 2, height: 1)
        ctx.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))

        X11Connection.withFunction(3, on: ctx) {
            ctx.draw(Self.whiteTile(width: 2, height: 1), in: CGRect(x: 0, y: 0, width: 2, height: 1))
        }
        let pixel = ctx.data!.bindMemory(to: UInt8.self, capacity: 8)
        XCTAssertEqual(pixel[0], 255, "white replaced black")
        XCTAssertEqual(pixel[1], 255)
        XCTAssertEqual(pixel[2], 255)
    }

    private static func whiteTile(width: Int, height: Int) -> CGImage {
        let tile = makeFlippedBitmapContext(width: width, height: height)
        tile.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!)
        tile.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return tile.makeImage()!
    }
}

/// F9 — picture attributes. Same clip-origin defect as the core GC, plus
/// the subpixel-text flag that was being dropped entirely.
final class X11PictureAttributeTests: XCTestCase {
    func testThePictureClipOriginMovesTheRectangles() {
        let picture = X11State.PictureRecord(id: 1)
        picture.clipRectanglesRaw = [CGRect(x: 4, y: 8, width: 16, height: 32)]
        XCTAssertEqual(picture.clipRectangles, [CGRect(x: 4, y: 8, width: 16, height: 32)])

        picture.clipOrigin = CGPoint(x: 20, y: 30)
        XCTAssertEqual(picture.clipRectangles, [CGRect(x: 24, y: 38, width: 16, height: 32)])
    }

    func testAnUnclippedPictureStaysUnclipped() {
        let picture = X11State.PictureRecord(id: 1)
        picture.clipOrigin = CGPoint(x: 9, y: 9)
        XCTAssertNil(picture.clipRectangles)
    }

    /// Off by default: an ordinary mask is a single alpha, and treating it
    /// as per-channel coverage would be the mirror-image bug.
    func testComponentAlphaDefaultsOff() {
        XCTAssertFalse(X11State.PictureRecord(id: 1).componentAlpha)
    }
}
