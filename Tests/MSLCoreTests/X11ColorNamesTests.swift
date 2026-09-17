import XCTest
@testable import MSLCore

final class X11ColorNamesTests: XCTestCase {
    func testTheNamesThatBrokeEmacsAndTk() {
        // Tk's IDLE died on exactly this one.
        XCTAssertEqual(X11ColorNames.lookup("grey75")?.red, 191 * 0x101)
        XCTAssertEqual(X11ColorNames.lookup("gray75")?.green, 191 * 0x101)
        // Emacs' default faces.
        XCTAssertNotNil(X11ColorNames.lookup("black"))
        XCTAssertNotNil(X11ColorNames.lookup("white"))
        XCTAssertNotNil(X11ColorNames.lookup("DarkGoldenrod"))
    }

    func testMatchingIsCaseInsensitiveButOtherwiseExact() {
        // xorg's OsLookupColor: strncasecmp over the whole name.
        let navajo = X11ColorNames.lookup("NavajoWhite")
        XCTAssertNotNil(navajo)
        XCTAssertEqual(X11ColorNames.lookup("navajowhite")?.red, navajo?.red)
        XCTAssertEqual(X11ColorNames.lookup("NAVAJOWHITE")?.blue, navajo?.blue)
        // The spaced spelling is its own entry in rgb.txt...
        XCTAssertEqual(X11ColorNames.lookup("navajo white")?.green, navajo?.green)
        // ...but no fuzzy matching beyond case.
        XCTAssertNil(X11ColorNames.lookup("navajo  white"))
        XCTAssertNil(X11ColorNames.lookup(" navajowhite"))
        XCTAssertNil(X11ColorNames.lookup("notacolour"))
        XCTAssertNil(X11ColorNames.lookup(""))
    }

    func testValuesMatchRgbTxt() {
        // Spot checks against rgb.txt's own lines.
        let snow = X11ColorNames.lookup("snow")
        XCTAssertEqual(snow?.red, 255 * 0x101)
        XCTAssertEqual(snow?.green, 250 * 0x101)
        XCTAssertEqual(snow?.blue, 250 * 0x101)
        let goldenrod = X11ColorNames.lookup("light goldenrod yellow")
        XCTAssertEqual(goldenrod?.red, 250 * 0x101)
        XCTAssertEqual(goldenrod?.blue, 210 * 0x101)
        // Every name in the file, both spellings of grey, is present.
        XCTAssertGreaterThan(X11ColorNames.count, 700)
    }
}
