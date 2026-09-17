import XCTest
@testable import MSLCore

final class X11RawMotionTests: XCTestCase {
    func testRawMotionWireLayout() {
        let e = X11Connection.xiRawMotionEvent(sequence: 0x1234, time: 0xAABBCCDD, dx: 3.5, dy: -2, littleEndian: true)
        XCTAssertEqual(e.count, 32 + 36)
        XCTAssertEqual(e[0], 35) // GenericEvent
        XCTAssertEqual(e[1], X11Opcode.xinputExtension)
        XCTAssertEqual(Array(e[2...3]), [0x34, 0x12])
        XCTAssertEqual(Array(e[4...7]), [9, 0, 0, 0]) // length = extra / 4
        XCTAssertEqual(Array(e[8...9]), [17, 0]) // XI_RawMotion
        XCTAssertEqual(Array(e[10...11]), [2, 0]) // deviceid
        XCTAssertEqual(Array(e[12...15]), [0xDD, 0xCC, 0xBB, 0xAA])
        XCTAssertEqual(Array(e[20...21]), [4, 0]) // sourceid
        XCTAssertEqual(Array(e[22...23]), [1, 0]) // valuators_len
        XCTAssertEqual(Array(e[32...35]), [3, 0, 0, 0]) // mask: axes 0 and 1
        // dx = 3.5 -> integral 3, frac 0x80000000.
        XCTAssertEqual(Array(e[36...43]), [3, 0, 0, 0, 0, 0, 0, 0x80])
        // dy = -2 -> integral -2, frac 0.
        XCTAssertEqual(Array(e[44...51]), [0xFE, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
        // Raw values repeat the values.
        XCTAssertEqual(Array(e[52...67]), Array(e[36...51]))
    }

    func testBigEndianLayout() {
        let e = X11Connection.xiRawMotionEvent(sequence: 1, time: 2, dx: 1, dy: 0, littleEndian: false)
        XCTAssertEqual(Array(e[8...9]), [0, 17])
        XCTAssertEqual(Array(e[4...7]), [0, 0, 0, 9])
    }

    func testThrottleSendsFirstMotionThenCoalesces() {
        var t = X11MotionThrottle(minimumInterval: 1.0 / 60)
        XCTAssertTrue(t.add(dx: 1, dy: 1, now: 10.0))
        XCTAssertEqual(t.take(now: 10.0)?.dx, 1)
        // Two motions inside the interval accumulate and wait.
        XCTAssertFalse(t.add(dx: 2, dy: 0, now: 10.005))
        XCTAssertFalse(t.add(dx: 3, dy: -1, now: 10.010))
        XCTAssertEqual(t.remaining(now: 10.010), 1.0 / 60 - 0.010, accuracy: 1e-9)
        let flushed = t.take(now: 10.02)
        XCTAssertEqual(flushed?.dx, 5)
        XCTAssertEqual(flushed?.dy, -1)
        XCTAssertNil(t.take(now: 10.03), "nothing pending after a flush")
        XCTAssertTrue(t.add(dx: 1, dy: 0, now: 10.04))
    }
}
