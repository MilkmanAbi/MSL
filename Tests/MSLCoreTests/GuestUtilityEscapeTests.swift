import XCTest
@testable import MSLCore

/// Utility output comes over a pty, so it can carry terminal escapes - and one
/// in front of the result line hid Arch's result entirely.
final class GuestUtilityEscapeTests: XCTestCase {
    func testACursorEscapeBeforeTheResultLineStillParses() {
        let output = "\u{1B}[?25lNo database errors\n\u{1B}[?25hMSL-RESULT ok package manager is healthy\n"
        let result = GuestUtilityResult.parse(exitCode: 0, output: output)
        XCTAssertEqual(result.status, GuestUtilityResult.Status(rawValue: "ok"))
        XCTAssertEqual(result.summary, "package manager is healthy")
    }

    func testOSCSequencesAreRemovedToo() {
        let osc = "\u{1B}]3008;start=abc;user=root;hostname=arch\u{1B}\\"
        let output = "\(osc)checking\n\(osc)MSL-RESULT fail database is locked\u{07}\n"
        let result = GuestUtilityResult.parse(exitCode: 1, output: output)
        XCTAssertEqual(result.status, GuestUtilityResult.Status(rawValue: "fail"))
        XCTAssertEqual(result.output, "checking")
    }

    func testTheLogShownToTheUserHasNoEscapes() {
        let output = "\u{1B}[1;32mdone\u{1B}[0m\nMSL-RESULT ok fine\n"
        let result = GuestUtilityResult.parse(exitCode: 0, output: output)
        XCTAssertEqual(result.output, "done")
        XCTAssertFalse(result.output.contains("\u{1B}"))
    }

    func testPlainOutputIsUnchanged() {
        XCTAssertEqual(GuestUtilityResult.strippingTerminalEscapes("no escapes here\n"), "no escapes here\n")
    }
}
