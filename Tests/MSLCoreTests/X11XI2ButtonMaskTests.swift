import XCTest
@testable import MSLCore

/// XI2 device events carry a button bitmask. GDK3 reads bit N as button N
/// (`_gdk_x11_device_xi2_translate_state`, `XIMaskIsSet (mask, i)` for
/// i = 1...3) and turns it into GDK_BUTTON1_MASK etc. Without it no GTK
/// drag ever saw a held button.
final class X11XI2ButtonMaskTests: XCTestCase {
    func testButtonOneIsBitOneOfByteZero() {
        XCTAssertEqual(X11Connection.xi2ButtonMask([1]), [0x02, 0, 0, 0])
    }

    func testFirstThreeButtonsAndScrollButtons() {
        XCTAssertEqual(X11Connection.xi2ButtonMask([1, 2, 3]), [0x0E, 0, 0, 0])
        XCTAssertEqual(X11Connection.xi2ButtonMask([4, 5, 6, 7]), [0xF0, 0, 0, 0])
        XCTAssertEqual(X11Connection.xi2ButtonMask([8, 9]), [0, 0x03, 0, 0])
    }

    func testNothingHeldIsAnEmptyMaskNotAMissingOne() {
        XCTAssertEqual(X11Connection.xi2ButtonMask([]), [0, 0, 0, 0])
    }

    func testButtonsBeyondTheMaskAreDropped() {
        XCTAssertEqual(X11Connection.xi2ButtonMask([31]), [0, 0, 0, 0x80])
        XCTAssertEqual(X11Connection.xi2ButtonMask([32, 200]), [0, 0, 0, 0])
    }
}
