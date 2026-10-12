import AppKit
import XCTest
@testable import MSLCore

/// SHAPE bounding/input regions on any window - what GTK3 uses to put a
/// client-side popover above a native child (Cheese's menu over its video).
final class X11ShapeRegionTests: XCTestCase {
    private let full = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testSetReplacesAndUnionAdds() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10), b = CGRect(x: 50, y: 50, width: 10, height: 10)
        XCTAssertEqual(X11ShapeRegion.combine(current: [full], with: [a], op: X11ShapeRegion.set), [a])
        XCTAssertEqual(X11ShapeRegion.combine(current: [a], with: [b], op: X11ShapeRegion.union), [a, b])
    }

    /// Subtract is the popover case: the child keeps everything but the hole.
    func testSubtractCutsAHoleAndKeepsTheRest() {
        let hole = CGRect(x: 20, y: 30, width: 40, height: 20)
        let result = X11ShapeRegion.combine(current: [full], with: [hole], op: X11ShapeRegion.subtract)
        let area = result.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, 100 * 100 - 40 * 20, "exactly the hole is removed")
        XCTAssertFalse(X11ShapeRegion.contains(result, CGPoint(x: 30, y: 40)), "inside the hole")
        XCTAssertTrue(X11ShapeRegion.contains(result, CGPoint(x: 5, y: 5)))
        XCTAssertTrue(X11ShapeRegion.contains(result, CGPoint(x: 90, y: 40)), "beside the hole, same rows")
        for (i, a) in result.enumerated() { for b in result[(i + 1)...] { XCTAssertTrue(a.intersection(b).isEmpty, "pieces must not overlap") } }
    }

    func testIntersect() {
        let r = X11ShapeRegion.combine(current: [full], with: [CGRect(x: 90, y: 90, width: 50, height: 50)], op: X11ShapeRegion.intersect)
        XCTAssertEqual(r, [CGRect(x: 90, y: 90, width: 10, height: 10)])
    }

    /// Row 0 of the mask is the TOP row - the orientation the canvas mask
    /// path was measured with.
    func testMaskRowsAreTopDown() {
        let bytes = X11ShapeRegion.maskRGBA([CGRect(x: 0, y: 0, width: 4, height: 1)], width: 4, height: 2)
        XCTAssertEqual(bytes[3], 255, "top row inside")
        XCTAssertEqual(bytes[4 * 4 + 3], 0, "second row outside")
    }

    /// A click in the cut-out must fall through to the window beneath.
    /// In a real window, the way AppKit delivers clicks: `hitTest` on the
    /// content view takes WINDOW coordinates (bottom-left origin), so a
    /// top-left X11 point (x, y) is (x, 200 - y) there.
    func testClicksOutsideTheShapeFallThroughToTheParent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let parent = X11CanvasView(width: 200, height: 200)
        window.contentView = parent
        let child = X11CanvasView(width: 100, height: 100)
        child.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        parent.addSubview(child)
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? { parent.hitTest(NSPoint(x: x, y: 200 - y)) }

        XCTAssertTrue(hit(10, 10) === child, "unshaped: the child covers its area")
        child.shapeRects = X11ShapeRegion.combine(current: [full], with: [CGRect(x: 0, y: 0, width: 50, height: 50)],
                                                  op: X11ShapeRegion.subtract)
        XCTAssertTrue(hit(10, 10) === parent, "in the hole: the parent gets it")
        XCTAssertTrue(hit(80, 80) === child, "outside the hole: still the child")
        child.shapeRects = nil
        XCTAssertTrue(hit(10, 10) === child, "shape removed: the child again")
    }
}
