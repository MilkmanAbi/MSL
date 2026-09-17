import XCTest
@testable import MSLCore

/// What `X11Connection.writeFull` may drop while the guest is not reading
/// its socket (paused for sleep, idle suspend): pointer motion only.
final class X11WriteBacklogTests: XCTestCase {
    func testRawMotionIsDroppable() {
        for littleEndian in [true, false] {
            let event = X11Connection.xiRawMotionEvent(sequence: 7, time: 1, dx: 3, dy: -2, littleEndian: littleEndian)
            XCTAssertTrue(X11Connection.isDroppableMotion(event, littleEndian: littleEndian))
        }
    }

    func testCoreMotionNotifyIsDroppable() {
        var event = [UInt8](repeating: 0, count: 32)
        event[0] = 6
        XCTAssertTrue(X11Connection.isDroppableMotion(event, littleEndian: true))
        event[0] = 6 | 0x80 // SendEvent flag
        XCTAssertTrue(X11Connection.isDroppableMotion(event, littleEndian: true))
    }

    func testButtonsKeysAndRepliesAreNeverDropped() {
        var press = [UInt8](repeating: 0, count: 32)
        press[0] = 4 // ButtonPress
        XCTAssertFalse(X11Connection.isDroppableMotion(press, littleEndian: true))

        var reply = [UInt8](repeating: 0, count: 32)
        reply[0] = 1
        XCTAssertFalse(X11Connection.isDroppableMotion(reply, littleEndian: true))

        // An XI2 button press has the same GenericEvent shape as motion.
        for littleEndian in [true, false] {
            var xiPress = X11Connection.xiRawMotionEvent(sequence: 1, time: 1, dx: 0, dy: 0, littleEndian: littleEndian)
            let evtype = XIEventType.buttonPress
            xiPress[8] = littleEndian ? UInt8(evtype & 0xFF) : UInt8(evtype >> 8)
            xiPress[9] = littleEndian ? UInt8(evtype >> 8) : UInt8(evtype & 0xFF)
            XCTAssertFalse(X11Connection.isDroppableMotion(xiPress, littleEndian: littleEndian))
        }
    }
}
