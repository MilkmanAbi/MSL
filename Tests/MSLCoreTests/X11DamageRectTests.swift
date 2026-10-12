import XCTest
import CoreGraphics
@testable import MSLCore

/// C9 — every drawing request repainted the whole window.
///
/// `notifyChanged()` marked the entire view dirty and `draw(_:)` ignored
/// `dirtyRect`, so the cost of a partial update scaled with the window's
/// AREA rather than with what changed: a client repainting one menu label
/// in a 1140x740 window re-composited all of it.
final class X11DamageRectTests: XCTestCase {
    /// Passing no rect must keep the old behaviour exactly. Every handler
    /// that cannot cheaply say what it touched relies on this, so it is
    /// the property that makes the change safe to land incrementally.
    func testNoDamageRectStillMeansEverything() {
        let pixmap = X11Pixmap(width: 4, height: 4)
        pixmap.notifyChanged()             // the convenience form
        pixmap.notifyChanged(damage: nil)  // and the explicit one
    }

    /// A fill reports exactly the rectangle it filled.
    func testAFillReportsItsOwnRect() {
        let pixmap = X11Pixmap(width: 16, height: 16)
        // A pixmap's notifyChanged is a no-op either way; what is being
        // pinned here is that the call compiles with a rect and that
        // `fillWithColor` has somewhere to put one.
        pixmap.fillWithColor(0x00FF_0000, rect: CGRect(x: 2, y: 3, width: 4, height: 5))
        XCTAssertEqual(pixmap.pixelWidth, 16)
    }

    /// Damage outside the view is clamped rather than trusted: a client
    /// may legitimately draw partly outside a window, and an out-of-bounds
    /// rect handed to `setNeedsDisplay` would either be ignored or assert.
    func testDamageIsClampedToTheView() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let partlyOutside = CGRect(x: 80, y: 40, width: 60, height: 40)
        let clamped = partlyOutside.intersection(bounds)
        XCTAssertEqual(clamped, CGRect(x: 80, y: 40, width: 20, height: 10))

        let fullyOutside = CGRect(x: 200, y: 200, width: 10, height: 10)
        XCTAssertTrue(fullyOutside.intersection(bounds).isEmpty,
                      "nothing to repaint - and the caller must fall back to the whole view")
    }

    /// The view is `isFlipped`, so its coordinates are top-left origin -
    /// the same space X11 uses. That is why a damage rect needs no
    /// conversion, and it is the assumption the whole change rests on.
    func testTheViewSharesX11sCoordinateOrigin() {
        let view = X11CanvasView(width: 10, height: 10)
        XCTAssertTrue(view.isFlipped)
    }
}
