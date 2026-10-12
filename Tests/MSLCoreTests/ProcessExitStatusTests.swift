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

    /// Spawned with `posix_spawn` rather than `Process`, so that this test
    /// is the only thing waiting for the child. Foundation reaps its own
    /// children on a private queue, and when it won the race this test's
    /// `waitpid` returned -1 with the status untouched - a failure that
    /// said "0 is not equal to 3" and had nothing to do with the decoding
    /// being tested.
    func testMatchesWhatTheSystemReallyReturns() throws {
        for expected: Int32 in [0, 3, 127] {
            var pid: pid_t = 0
            let arguments = ["/bin/sh", "-c", "exit \(expected)"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            argv.append(nil)
            defer { for argument in argv where argument != nil { free(argument) } }

            XCTAssertEqual(posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ), 0)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, 0), pid)
            XCTAssertEqual(ProcessExitStatus.code(fromWaitStatus: status), expected)
        }
    }
}
