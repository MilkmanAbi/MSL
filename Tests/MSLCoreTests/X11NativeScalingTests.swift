import AppKit
import XCTest
@testable import MSLCore

/// Native Scaling: a top-level Linux window drawn at a fraction of a point
/// per X11 pixel. The property that matters most is that scale 1 is exactly
/// what mslgd always did - every app has been tested there.
final class X11NativeScalingTests: XCTestCase {
    func testScaleOneIsTheOldMappingExactly() {
        let x11 = CGRect(x: 100, y: 50, width: 640, height: 480)
        let maxY = X11Connection.primaryScreenMaxY
        XCTAssertEqual(X11Connection.cocoaScreenFrame(fromX11: x11, scale: 1),
                       CGRect(x: 100, y: maxY - 50 - 480, width: 640, height: 480))
    }

    /// Everything - origin too - shrinks by the factor, and the top edge
    /// still lands where the flip says.
    func testAScaledFrameShrinksAboutTheScreenTopLeft() {
        let x11 = CGRect(x: 200, y: 100, width: 1000, height: 600)
        let maxY = X11Connection.primaryScreenMaxY
        let cocoa = X11Connection.cocoaScreenFrame(fromX11: x11, scale: 0.85)
        XCTAssertEqual(cocoa.width, 850, accuracy: 0.001)
        XCTAssertEqual(cocoa.height, 510, accuracy: 0.001)
        XCTAssertEqual(cocoa.origin.x, 170, accuracy: 0.001)
        XCTAssertEqual(maxY - cocoa.maxY, 85, accuracy: 0.001, "the window's top edge: 100 pixels down is 85 points down")
    }

    func testDisabledByDefault() {
        XCTAssertFalse(MSLExperimentalSettings().nativeScaling)
        let old = try? JSONDecoder().decode(MSLExperimentalSettings.self, from: Data(#"{"guestClipboard":true}"#.utf8))
        XCTAssertEqual(old?.nativeScaling, false, "a settings file from before the flag loads with it off")
    }

    // MARK: the canvas

    /// Bounds stay in X11 pixels; only the frame is scaled. That single
    /// fact is what makes drawing, damage rects and mouse coordinates all
    /// come out in X11 pixels without converting anything.
    func testAScaledCanvasKeepsItsBoundsInX11Pixels() {
        let view = X11CanvasView(width: 400, height: 300)
        view.displayScale = 0.5
        XCTAssertEqual(view.frame.size, NSSize(width: 200, height: 150))
        XCTAssertEqual(view.bounds.size, NSSize(width: 400, height: 300))

        view.resize(width: 800, height: 600)
        XCTAssertEqual(view.frame.size, NSSize(width: 400, height: 300))
        XCTAssertEqual(view.bounds.size, NSSize(width: 800, height: 600))
    }

    /// Resizing the window by hand sets the content view's frame directly;
    /// the bounds must follow in pixels, since that is what windowDidResize
    /// reports to the client.
    func testAHandResizeKeepsBoundsInPixels() {
        let view = X11CanvasView(width: 400, height: 300)
        view.displayScale = 0.5
        view.setFrameSize(NSSize(width: 300, height: 250))
        XCTAssertEqual(view.bounds.size, NSSize(width: 600, height: 500))
    }

    /// Reparented into another window, a canvas is laid out in its parent's
    /// X11 bounds and must be unscaled again - bounds equal to frame.
    func testBackToScaleOneUndoesTheScaling() {
        let view = X11CanvasView(width: 400, height: 300)
        view.displayScale = 0.5
        view.displayScale = 1
        XCTAssertEqual(view.frame.size, NSSize(width: 400, height: 300))
        XCTAssertEqual(view.bounds.size, view.frame.size)
    }

    /// A mouse position in a scaled view converts to X11 pixels.
    func testMouseCoordinatesComeOutInPixels() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = X11CanvasView(width: 400, height: 300)
        view.displayScale = 0.5
        window.contentView = view
        // 50 points in from the left, 30 points down from the top.
        let inWindow = NSPoint(x: 50, y: 150 - 30)
        let point = view.convert(inWindow, from: nil)
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 60, accuracy: 0.001)
    }
}
