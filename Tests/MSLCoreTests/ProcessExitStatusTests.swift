import XCTest
@testable import MSLCore

final class ProcessExitStatusTests: XCTestCase {
    func testTheTerminalTabsExit32512IsReally127() {
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: 32512), 127)
    }

    func testNormalExits() {
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: 0), 0)
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: 1 << 8), 1)
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: 255 << 8), 255)
    }

    func testAKilledProcessReportsTheShellConvention() {
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: SIGHUP), 128 + SIGHUP)
        XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: SIGKILL), 137)
    }

    func testMatchesWhatTheSystemReallyReturns() throws {
        for expected: Int32 in [0, 3, 127] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit \(expected)"]
            try process.run()
            var status: Int32 = 0
            waitpid(process.processIdentifier, &status, 0)
            XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: status), expected)
        }
    }
}
