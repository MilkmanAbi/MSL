import XCTest
@testable import MSLCore

/// The screen MSL puts up when it has nothing useful to say.
///
/// Tested mostly for what it must *not* do: a crash handler that loses the
/// crash report, or that reappears forever, is worse than no handler.
final class CrashScreenTests: XCTestCase {

    func testEachSignalGetsItsOwnStopCode() {
        // Specific enough to grep the logs for, and honest about not being
        // a diagnosis.
        XCTAssertEqual(CrashScreen.stopCode(signal: SIGSEGV), "WENT_SOMEWHERE_IT_SHOULDNT")
        XCTAssertEqual(CrashScreen.stopCode(signal: SIGABRT), "GAVE_UP_ON_ITSELF")
        XCTAssertEqual(CrashScreen.stopCode(signal: SIGFPE), "MATHS_HAPPENED")
        // Anything unexpected still produces something greppable.
        XCTAssertEqual(CrashScreen.stopCode(signal: 99), "SIGNAL_99")
    }

    func testAnExceptionNameBecomesAUsableStopCode() {
        let code = CrashScreen.stopCode(exception: "NSInvalidArgumentException")
        XCTAssertTrue(code.hasPrefix("UNCAUGHT_"))
        // No spaces or punctuation: it ends up in a log line and in
        // somebody's bug report.
        XCTAssertFalse(code.contains(" "))
        XCTAssertFalse(code.contains("."))
    }

    /// `note()` writes through a path resolved by `install()` and held as a
    /// C string, because the one place it runs is a signal handler, where
    /// building a `URL` is not safe. So a test that never installs is
    /// testing a writer with nowhere to write, and these two failed for that
    /// reason rather than for anything about crash notes.
    override func setUp() {
        super.setUp()
        CrashScreen.install(for: .cli, viewer: nil)
    }

    func testTheNoteRoundTrips() {
        CrashScreen.clearReport()
        XCTAssertNil(CrashScreen.lastReport())

        CrashScreen.note(stopCode: "WENT_SOMEWHERE_IT_SHOULDNT", detail: "signal 11")
        let report = CrashScreen.lastReport()
        XCTAssertEqual(report?.stopCode, "WENT_SOMEWHERE_IT_SHOULDNT")
        XCTAssertEqual(report?.detail, "signal 11")
        XCTAssertFalse(report?.component.isEmpty ?? true)
    }

    func testTheReportIsClearedSoTheScreenDoesNotHaunt() {
        // Read once. A crash screen that comes back on every ordinary
        // launch is its own bug, and a worse one than the crash.
        CrashScreen.note(stopCode: "X", detail: "y")
        XCTAssertNotNil(CrashScreen.lastReport())
        CrashScreen.clearReport()
        XCTAssertNil(CrashScreen.lastReport())
    }

    func testAGarbledNoteIsIgnoredRatherThanShown() {
        try? Data("nonsense with no tabs".utf8).write(to: CrashScreen.reportURL)
        XCTAssertNil(CrashScreen.lastReport(),
                     "half a note is not a crash report worth putting on screen")
        CrashScreen.clearReport()
    }
}
