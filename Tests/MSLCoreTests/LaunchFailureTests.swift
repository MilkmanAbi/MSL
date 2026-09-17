import XCTest
@testable import MSLCore

final class LaunchFailureTests: XCTestCase {
    private func message(_ code: Int32, runTime: TimeInterval = 1, output: String = "") -> String? {
        LinuxAppLauncher.failureMessage(appName: "Chess", instance: "debian", command: "gnome-chess --new",
                                        exitCode: code, output: output, runTime: runTime)
    }

    func testCleanExitSaysNothing() {
        XCTAssertNil(message(0))
    }

    /// The silent failure that started this: exit 127, nothing on screen.
    func testNotFoundAlwaysExplained() {
        let text = message(127, runTime: 60)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("gnome-chess isn't installed in debian"))
    }

    func testQuickCrashShowsTheLastOutput() {
        let text = message(1, output: "a\nb\nc\nd\nGtk-WARNING: cannot open display")
        XCTAssertTrue(text!.contains("quit right away"))
        XCTAssertTrue(text!.contains("cannot open display"))
        XCTAssertFalse(text!.contains("\na\n"))
    }

    func testLongRunningAppsMayExitHowTheyLike() {
        XCTAssertNil(message(1, runTime: 600))
    }
}
