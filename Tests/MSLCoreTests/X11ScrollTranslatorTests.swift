import XCTest
@testable import MSLCore

/// The scroll rules toolkits depend on (XI2proto "Smooth scrolling"; GTK's
/// gdkdevice-xi2.c, Qt's qxcbconnection_xi2.cpp, Chromium's
/// device_data_manager_x11.cc).
final class X11ScrollTranslatorTests: XCTestCase {
    /// AppKit positive Y = content moves down = scroll up: the vertical
    /// valuator decreases and the click is button 4 (XI2proto: button 5 is
    /// +1 unit on a Vertical valuator).
    func testDirectionFollowsAppKitAndXI2() {
        var t = X11ScrollTranslator()
        let up = t.translate(scrollingDeltaX: 0, scrollingDeltaY: 1, precise: false, beginsGesture: false)
        XCTAssertEqual(up.dy, -1)
        XCTAssertEqual(up.clicks, [4])
        let down = t.translate(scrollingDeltaX: 0, scrollingDeltaY: -2, precise: false, beginsGesture: false)
        XCTAssertEqual(down.dy, 2)
        XCTAssertEqual(down.clicks, [5, 5])
        let left = t.translate(scrollingDeltaX: 1, scrollingDeltaY: 0, precise: false, beginsGesture: false)
        XCTAssertEqual(left.clicks, [6])
        let right = t.translate(scrollingDeltaX: -1, scrollingDeltaY: 0, precise: false, beginsGesture: false)
        XCTAssertEqual(right.clicks, [7])
    }

    /// The old code truncated each wheel event with Int(dy), so macOS's
    /// fractional slow-wheel deltas never produced a click at all.
    func testFractionalWheelDeltasAccumulate() {
        var t = X11ScrollTranslator()
        var clicks: [UInt8] = []
        for _ in 0..<10 { clicks += t.translate(scrollingDeltaX: 0, scrollingDeltaY: -0.3, precise: false, beginsGesture: false).clicks }
        XCTAssertEqual(clicks, [5, 5, 5], "3.0 lines of travel is 3 clicks")
    }

    /// Touchpad: pixels of travel, one click per touchpadIncrement, in X
    /// pixels (Native Scaling divides points by the factor).
    func testTouchpadUsesPixelsAndIncrement() {
        var t = X11ScrollTranslator()
        let step = t.translate(scrollingDeltaX: 0, scrollingDeltaY: -40, precise: true, beginsGesture: true, scale: 0.8)
        XCTAssertEqual(step.source, .touchpad)
        XCTAssertEqual(step.dy, 50, accuracy: 1e-9, "40 points at 0.8 is 50 X pixels")
        XCTAssertEqual(step.clicks, [5], "exactly one increment")
    }

    /// A burst is capped per event; the excess carries over rather than
    /// vanishing.
    func testClickBurstIsCappedButNotLost() {
        var t = X11ScrollTranslator()
        let first = t.translate(scrollingDeltaX: 0, scrollingDeltaY: -20, precise: false, beginsGesture: false)
        XCTAssertEqual(first.clicks.count, X11ScrollTranslator.maxClicksPerEvent)
        XCTAssertEqual(first.dy, 20, "the valuator carries the full distance")
        let second = t.translate(scrollingDeltaX: 0, scrollingDeltaY: 0, precise: false, beginsGesture: false)
        XCTAssertEqual(second.clicks.count, X11ScrollTranslator.maxClicksPerEvent)
    }

    /// A new touch gesture starts clean: half a click left over from the
    /// last swipe must not fire on the first pixel of this one.
    func testNewGestureDropsLeftoverFraction() {
        var t = X11ScrollTranslator()
        _ = t.translate(scrollingDeltaX: 0, scrollingDeltaY: -45, precise: true, beginsGesture: true)
        let next = t.translate(scrollingDeltaX: 0, scrollingDeltaY: -10, precise: true, beginsGesture: true)
        XCTAssertEqual(next.clicks, [], "45 + 10 would have crossed 50 without the reset")
    }

    /// Pinch fallback: zoom in = Ctrl + scroll up, one click per 10%.
    func testPinchFallbackZoomsLikeCtrlWheel() {
        var z = X11PinchZoomFallback()
        var clicks: [UInt8] = []
        var dy = 0.0
        for _ in 0..<5 {
            let r = z.translate(magnification: 0.05)
            clicks += r.clicks
            dy += r.dy
        }
        XCTAssertEqual(clicks, [4, 4], "0.25 magnification is two whole 10% steps")
        XCTAssertLessThan(dy, 0, "zoom in scrolls up")
        z.reset()
        XCTAssertEqual(z.translate(magnification: -0.1).clicks, [5], "zoom out is scroll down")
    }
}

/// XI 2.4 pinch events, byte for byte against `xXIGesturePinchEvent`.
final class X11GesturePinchWireTests: XCTestCase {
    func testPinchEventLayout() {
        let b = X11Connection.xiGesturePinchBytes(
            evtype: XIEventType.gesturePinchUpdate, sequence: 7, time: 1234, root: 0x100, event: 0x200,
            rootX: 110.5, rootY: 220, eventX: 10.5, eventY: 20, scale: 1.25, angle: -15,
            mods: X11KeyboardSnapshot(baseMods: 0x04), flags: XIFlag.gesturePinchCancelled, littleEndian: true)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func fp(_ o: Int) -> Double { Double(Int32(bitPattern: u32(o))) / 65536 }
        XCTAssertEqual(b.count, 100)
        XCTAssertEqual(b[0], 35, "GenericEvent")
        XCTAssertEqual(32 + Int(u32(4)) * 4, b.count, "length field covers the event")
        XCTAssertEqual(u16(8), 28, "GesturePinchUpdate")
        XCTAssertEqual(u32(16), 2, "two touches")
        XCTAssertEqual(u32(24), 0x200, "event window")
        XCTAssertEqual(fp(32), 110.5); XCTAssertEqual(fp(44), 20)
        XCTAssertEqual(fp(64), 1.25, "scale at offset 64")
        XCTAssertEqual(fp(68), -15, "delta_angle at 68")
        XCTAssertEqual(u16(72), Int(XIDeviceUse.mslTouchpadID), "sourceid")
        XCTAssertEqual(u32(76), 0x04, "mods.base")
        XCTAssertEqual(u32(96), 1, "flags last: cancelled")
    }
}
