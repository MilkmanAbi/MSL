import XCTest
@testable import MSLCore

/// `caffeinate` really starts, is tied to this process, and really stops -
/// a keep-awake that outlived its install would hold a Mac up all night.
final class KeepAwakeTests: XCTestCase {
    private func caffeinatesWatchingUs() -> Int {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "caffeinate -dimsu -w \(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").count
    }

    func testHoldsWhileAliveAndStopsOnRelease() {
        let awake = KeepAwake()
        XCTAssertTrue(awake.isHolding)
        XCTAssertEqual(caffeinatesWatchingUs(), 1)

        awake.release()
        XCTAssertFalse(awake.isHolding)
        // terminate() is asynchronous; give it a moment to be gone.
        let deadline = Date().addingTimeInterval(3)
        while caffeinatesWatchingUs() > 0, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(caffeinatesWatchingUs(), 0)
        awake.release() // twice is fine
    }

    func testReleasedWhenDropped() {
        var awake: KeepAwake? = KeepAwake()
        XCTAssertTrue(awake?.isHolding == true)
        awake = nil
        let deadline = Date().addingTimeInterval(3)
        while caffeinatesWatchingUs() > 0, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(caffeinatesWatchingUs(), 0)
    }
}
