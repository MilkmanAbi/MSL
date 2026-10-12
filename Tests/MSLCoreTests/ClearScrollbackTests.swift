import XCTest
@testable import MSLCore

/// `clear` erased the screen and left the scrollback, so scrolling up showed
/// everything it was supposed to have removed.
///
/// The cause is in the guest: `clear` emits `ESC[H ESC[J` and nothing that
/// touches the scrollback, and on busybox distros it is an applet that
/// hardcodes those bytes and never reads terminfo - so no terminfo change
/// could fix it there either. `GuestIntegration.terminalShellLines` adds a
/// `clear` function that also sends `ESC[3J`.
///
/// These tests run the generated shell through a real `/bin/sh`, because the
/// thing that can go wrong is a quoting or syntax mistake in text Swift only
/// ever treats as a string - nothing in the type system would catch a stray
/// quote, and the symptom in the guest would be a login shell that prints an
/// error on every start.
final class ClearScrollbackTests: XCTestCase {

    /// Sources the generated lines in `/bin/sh` with a given `TERM` and
    /// `MSL_CLEAR_SCROLLBACK`, then runs `clear` and returns its bytes.
    private func clearOutput(term: String?, mslVariable: String?) throws -> (bytes: [UInt8], stderr: String) {
        let script = GuestIntegration.terminalShellLines().joined(separator: "\n") + "\nclear\n"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        var environment: [String: String] = [:]
        if let term { environment["TERM"] = term }
        if let mslVariable { environment["MSL_CLEAR_SCROLLBACK"] = mslVariable }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let bytes = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ([UInt8](bytes), String(data: errors, encoding: .utf8) ?? "")
    }

    /// `ESC [ H ESC [ 2 J ESC [ 3 J` - screen first, scrollback **last**.
    ///
    /// Deliberately the opposite of ncurses, which sends `E3` first. That
    /// order is wrong for Terminal.app, whose `ESC[2J` pushes the visible
    /// screen into the scrollback - so clearing the scrollback first just
    /// means the clear puts the last screenful straight back. Measured
    /// against Terminal.app's own `history`, Cmd+K as the reference.
    private let expected: [UInt8] = [0x1B, 0x5B, 0x48,
                                     0x1B, 0x5B, 0x32, 0x4A,
                                     0x1B, 0x5B, 0x33, 0x4A]

    func testTheGeneratedShellIsValid() throws {
        // The whole file is sourced by every login shell, so a syntax error
        // here would greet the person on every single prompt.
        let result = try clearOutput(term: "xterm-256color", mslVariable: nil)
        XCTAssertEqual(result.stderr, "", "the generated shell must not complain")
    }

    func testMSLsOwnTerminalsGetTheScrollbackClear() throws {
        // The rich tier sets the variable, and it wins regardless of TERM.
        let result = try clearOutput(term: "dumb", mslVariable: "1")
        XCTAssertEqual(result.bytes, expected)
    }

    func testSSHSessionsGetItFromTERMAlone() throws {
        // `msl ssh` never passes through TerminalProfile, so there is no
        // variable to read - TERM is the only thing it can go on.
        for term in ["xterm-256color", "xterm", "screen.xterm-256color",
                     "tmux-256color", "alacritty", "foot", "ghostty", "xterm-kitty"] {
            let result = try clearOutput(term: term, mslVariable: nil)
            XCTAssertEqual(result.bytes, expected, "TERM=\(term) should clear the scrollback")
        }
    }

    func testTerminalsThatPromiseNothingAreLeftAlone() throws {
        // The plain tier deliberately describes a terminal MSL does not
        // recognise, so it must not start inventing capabilities for it.
        for term in ["vt100", "dumb", "linux", ""] {
            let result = try clearOutput(term: term, mslVariable: nil)
            XCTAssertNotEqual(result.bytes, expected, "TERM=\(term) should not be assumed to do ESC[3J")
        }
    }

    func testTheHelperVariableDoesNotLeakIntoTheShell() throws {
        // This file is sourced into the person's own shell; leaving
        // scaffolding behind in their environment is rude.
        let script = GuestIntegration.terminalShellLines().joined(separator: "\n")
            + "\necho \"leftover=[${msl_clear_3j-}]\"\n"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = ["TERM": "xterm-256color"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertTrue(text.contains("leftover=[]"), "got \(text)")
    }

    // MARK: - One spelling, shared

    func testTheBannerAndTheGuestClearTheSameWay() {
        // `msl`'s session banner and the guest's `clear()` have to agree.
        // They did not: the banner erased the screen without discarding the
        // scrollback, so starting a session left the shell's own "last
        // login", the command line and a screenful of blank rows above it -
        // visible the moment anyone scrolled up.
        XCTAssertEqual(TerminalClear.full, "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        // The shell spelling is the same bytes, escaped for `printf`.
        XCTAssertEqual(TerminalClear.shellEscapes, #"\033[H\033[2J\033[3J"#)
        XCTAssertTrue(GuestIntegration.terminalShellLines()
            .contains { $0.contains(TerminalClear.shellEscapes) },
            "the guest's clear() should be built from the shared constant")
    }

    func testTheScrollbackIsDiscardedLast() {
        // The whole trick. ncurses sends E3 first; that order is wrong for
        // Terminal.app, whose ESC[2J pushes the screen into the scrollback -
        // so clearing the scrollback first just means the erase puts the
        // last screenful straight back.
        let bytes = Array(TerminalClear.full.utf8)
        let eraseScreen = bytes.firstRange(of: Array("\u{1B}[2J".utf8))
        let eraseScrollback = bytes.firstRange(of: Array("\u{1B}[3J".utf8))
        XCTAssertNotNil(eraseScreen); XCTAssertNotNil(eraseScrollback)
        guard let screen = eraseScreen, let scrollback = eraseScrollback else { return }
        XCTAssertLessThan(screen.lowerBound, scrollback.lowerBound,
                          "ESC[3J must come after ESC[2J or the erase undoes it")
    }

    // MARK: - The Mac half

    func testRichProfilesAdvertiseTheCapability() {
        // `exec "$SHELL" -l` keeps exported variables and discards
        // functions, which is exactly why this half is a variable and the
        // function is written into the file a login shell sources.
        XCTAssertTrue(TerminalProfile.rich(truecolor: true).exports.contains("export MSL_CLEAR_SCROLLBACK=1"))
        XCTAssertTrue(TerminalProfile.rich(truecolor: false).exports.contains("export MSL_CLEAR_SCROLLBACK=1"))
    }

    func testThePlainProfileUnsetsIt() {
        // And unsets rather than ignores: a reattached session could have
        // inherited it from a richer terminal.
        let exports = TerminalProfile.plain.exports
        XCTAssertFalse(exports.contains("export MSL_CLEAR_SCROLLBACK"))
        XCTAssertTrue(exports.contains("unset COLORTERM MSL_CLEAR_SCROLLBACK"))
    }

    func testTheSessionFileCarriesTheFunction() {
        // It has to be in the file login shells source, not in the exports.
        let command = GuestIntegration.sessionEnvFileCommand(settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("clear() { printf"), "the session env file must define clear()")
        XCTAssertTrue(command.contains(#"\033[3J"#), "and it must send ESC[3J")
    }
}
