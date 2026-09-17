import XCTest
@testable import MSLCore

final class X11CoreTextSymbolTests: XCTestCase {
    func testXcalcSymbolLabels() {
        // From /etc/X11/app-defaults/XCalc, drawn in -adobe-symbol-*.
        XCTAssertEqual(X11CoreText.decode([0xD6, 0x60], symbolFont: true), "\u{221A}\u{203E}") // √ with its bar
        XCTAssertEqual(X11CoreText.decode([0xB8], symbolFont: true), "\u{00F7}") // ÷
        XCTAssertEqual(X11CoreText.decode([0x70], symbolFont: true), "\u{03C0}") // π
    }

    func testOrdinaryFontsStayLatin1() {
        XCTAssertEqual(X11CoreText.decode([0x78, 0xB2], symbolFont: false), "x\u{B2}")
        XCTAssertEqual(X11CoreText.decode([0x70, 0xB8], symbolFont: false), "p\u{B8}")
    }

    func testSymbolDigitsAndSpaceAreUnchanged() {
        XCTAssertEqual(X11CoreText.decode(Array("1 2".utf8), symbolFont: true), "1 2")
    }

    func testSymbolFontNameDetection() {
        XCTAssertTrue(X11CoreText.isSymbolFontName("-adobe-symbol-*-*-*-*-*-120-*-*-*-*-*-*"))
        XCTAssertTrue(X11CoreText.isSymbolFontName("-ADOBE-SYMBOL-MEDIUM-R-NORMAL--12-120-75-75-P-74-ADOBE-FONTSPECIFIC"))
        XCTAssertFalse(X11CoreText.isSymbolFontName("8x13"))
        XCTAssertFalse(X11CoreText.isSymbolFontName("-misc-fixed-medium-r-normal--13-*-*-*-*-*-iso8859-1"))
        XCTAssertFalse(X11CoreText.isSymbolFontName("symbol"))
    }
}
