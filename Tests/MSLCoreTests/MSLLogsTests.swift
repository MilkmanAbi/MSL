import XCTest
@testable import MSLCore

final class MSLLogsTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-logs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLog(_ name: String, _ contents: String) {
        try? contents.write(to: directory.appendingPathComponent(name),
                            atomically: true, encoding: .utf8)
    }

    func testOnlyLogsAreListedAndLargestComesFirst() {
        makeLog("small.log", "a")
        makeLog("big.log", String(repeating: "b", count: 500))
        makeLog("notes.txt", "not a log")

        let files = MSLLogs.files(in: directory)
        XCTAssertEqual(files.map(\.name), ["big.log", "small.log"])
    }

    /// **The point of the whole file.** `mslhd` holds its log open for the
    /// life of the process, so unlinking it would leave the daemon writing to
    /// an inode with no name - the log would look permanently empty, the disk
    /// space would never come back, and nothing would be recorded anywhere
    /// readable until the daemon restarted. Clearing must leave the file
    /// there and empty.
    func testClearingEmptiesTheFileRatherThanRemovingIt() {
        makeLog("mslhd.log", String(repeating: "x", count: 1000))
        let path = directory.appendingPathComponent("mslhd.log").path

        // Hold it open exactly as the daemon does, and keep writing after.
        let fd = open(path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        let recovered = MSLLogs.clear(in: directory)
        XCTAssertEqual(recovered, 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "the log must still be there, or the daemon writes into nowhere")
        XCTAssertEqual(MSLLogs.totalBytes(in: directory), 0)

        // A writer that held the file across the clear still reaches it.
        let line = "after the clear\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        let afterwards = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(afterwards.contains("after the clear"),
                      "the daemon's open descriptor must still reach the real file")
    }

    /// **Clearing is only safe if writers hold the log with `O_APPEND`.**
    /// A handle that seeks to the end once keeps its offset, so the first
    /// write after a truncation lands there and the kernel fills the gap
    /// with NULs - the log returns to its old size, full of zeroes, having
    /// apparently been emptied. This is the shape of that bug, so that
    /// anything which opens a log the other way fails here first.
    func testAWriterThatSeeksInsteadOfAppendingLeavesAHole() {
        makeLog("seeking.log", String(repeating: "a", count: 4000))
        let path = directory.appendingPathComponent("seeking.log").path

        // The wrong way, kept here deliberately as the counter-example.
        let seeking = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        seeking.seekToEndOfFile()
        _ = MSLLogs.clear(in: directory)
        seeking.write(Data("x".utf8))
        try? seeking.close()
        XCTAssertGreaterThan(MSLLogs.totalBytes(in: directory), 4000,
                             "if this ever shrinks, the OS changed, not the code")

        // The right way, which is what `MSLLog` now does.
        makeLog("appending.log", String(repeating: "a", count: 4000))
        let appendPath = directory.appendingPathComponent("appending.log").path
        let fd = open(appendPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = MSLLogs.clear(in: directory)
        _ = "x".withCString { Darwin.write(fd, $0, 1) }
        close(fd)
        let size = (try? FileManager.default.attributesOfItem(atPath: appendPath)[.size]) as? Int
        XCTAssertEqual(size, 1, "an appending writer must land at the new end, not the old offset")
    }

    func testTailReturnsTheEndAndWholeLines() {
        makeLog("msl.log", (1...500).map { "line \($0)" }.joined(separator: "\n"))
        let tail = MSLLogs.tail(of: directory.appendingPathComponent("msl.log").path, lines: 3)
        XCTAssertEqual(tail, "line 498\nline 499\nline 500")
    }

    /// A log far bigger than the read window must still come back whole-lined
    /// rather than starting halfway through one.
    func testTailOfAHugeLogDoesNotStartMidLine() {
        makeLog("huge.log", (1...40_000).map { "line number \($0)" }.joined(separator: "\n"))
        let tail = MSLLogs.tail(of: directory.appendingPathComponent("huge.log").path, lines: 5)
        for line in tail.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("line number "), "got a partial line: \(line)")
        }
        XCTAssertTrue(tail.hasSuffix("line number 40000"))
    }

    func testClearingAnEmptyDirectoryIsHarmless() {
        XCTAssertEqual(MSLLogs.clear(in: directory), 0)
    }
}
