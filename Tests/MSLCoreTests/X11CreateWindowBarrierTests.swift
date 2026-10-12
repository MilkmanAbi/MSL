import XCTest
import CoreGraphics
@testable import MSLCore

/// T17 — the `handleCreateWindow` main-queue barrier.
///
/// Its comment claimed "once per window - not a hot path". Measured on
/// 2026-09-23: **xcalc (Xt/Athena) issues 69 `CreateWindow` requests where
/// Mousepad (GTK3) issues 4** - because that toolkit generation makes one
/// X window per *widget*. Every one of those 69 was a full barrier onto
/// the main queue, behind whatever drawing was already queued there.
final class X11CreateWindowBarrierTests: XCTestCase {
    /// The canvas can be handed a bitmap built off the main thread, which
    /// is the point: the allocation never needed AppKit.
    func testTheBackingBitmapCanBeBuiltByTheCaller() {
        let context = makeFlippedBitmapContext(width: 32, height: 16)
        let view = X11CanvasView(width: 32, height: 16, context: context)
        XCTAssertTrue(view.bitmapContext === context, "the prebuilt context is adopted, not replaced")
        XCTAssertEqual(view.pixelWidth, 32)
        XCTAssertEqual(view.pixelHeight, 16)
    }

    /// And it still builds its own when nobody supplies one, so every
    /// other caller is unaffected.
    func testItStillBuildsItsOwnWhenNoneIsGiven() {
        let view = X11CanvasView(width: 8, height: 8)
        XCTAssertEqual(view.bitmapContext.width, 8)
        XCTAssertEqual(view.bitmapContext.height, 8)
    }

    /// One fill, with the colour asked for. This used to fill white and
    /// then be filled again by the caller with the real background pixel.
    func testTheBackgroundIsFilledOnceWithTheRequestedColour() {
        let view = X11CanvasView(width: 2, height: 1, background: 0x00FF_0000) // red
        let pixels = view.bitmapContext.data!.bindMemory(to: UInt8.self, capacity: 8)
        // Stored BGRA-ish premultiplied; red channel is what matters here.
        XCTAssertEqual(Int(pixels[0]), 255, accuracy: 1, "red")
        XCTAssertEqual(Int(pixels[1]), 0, accuracy: 1, "green")
        XCTAssertEqual(Int(pixels[2]), 0, accuracy: 1, "blue")
    }

    /// No background given still means white, not transparent - a
    /// see-through canvas shows the desktop through the window and reads
    /// as broken.
    func testNoBackgroundMeansWhiteNotTransparent() {
        let view = X11CanvasView(width: 2, height: 1)
        let pixels = view.bitmapContext.data!.bindMemory(to: UInt8.self, capacity: 8)
        XCTAssertEqual(Int(pixels[3]), 255, accuracy: 1, "opaque")
        XCTAssertEqual(Int(pixels[0]), 255, accuracy: 1)
    }
}
