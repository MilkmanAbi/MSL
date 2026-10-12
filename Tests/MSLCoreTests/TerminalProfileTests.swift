import XCTest
@testable import MSLCore

final class TerminalProfileTests: XCTestCase {
    func testTerminalAppIsRichWithoutTruecolor() {
        let env = ["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"]
        XCTAssertEqual(TerminalProfile.detect(environment: env, interactive: true), .rich(truecolor: false))
    }

    func testKnownTerminalsAreRich() {
        XCTAssertEqual(TerminalProfile.detect(environment: ["TERM_PROGRAM": "iTerm.app"], interactive: true),
                       .rich(truecolor: true))
        XCTAssertEqual(TerminalProfile.detect(environment: ["TERM_PROGRAM": "MSL"], interactive: true),
                       .rich(truecolor: true))
        XCTAssertEqual(TerminalProfile.detect(environment: ["TERM": "xterm-kitty"], interactive: true),
                       .rich(truecolor: true))
    }

    func testUnknownTerminalIsPlain() {
        XCTAssertEqual(TerminalProfile.detect(environment: ["TERM": "xterm"], interactive: true), .plain)
        XCTAssertTrue(TerminalProfile.plain.exports.contains("TERM=vt100"))
        XCTAssertTrue(TerminalProfile.plain.exports.contains("NO_COLOR=1"))
    }

    func testNoTerminalLeavesTheGuestAlone() {
        XCTAssertNil(TerminalProfile.detect(environment: ["TERM_PROGRAM": "Apple_Terminal"], interactive: false))
    }

    /// The guest only ever has the base terminfo entries.
    func testRichAlwaysUsesABaseTerminfoName() {
        for profile in [TerminalProfile.rich(truecolor: true), .rich(truecolor: false)] {
            XCTAssertTrue(profile.exports.hasPrefix("export TERM=xterm-256color"))
            XCTAssertTrue(profile.interactiveCommand.hasSuffix(#"exec "${SHELL:-/bin/sh}" -l"#))
        }
    }

    func testCommandsParseAsShell() throws {
        for profile in [TerminalProfile.rich(truecolor: true), .rich(truecolor: false), .plain] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", "-c", profile.interactiveCommand]
            try check.run()
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, profile.exports)
        }
    }
}
