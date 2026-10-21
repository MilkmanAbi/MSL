import XCTest
@testable import MSLObserver

/// How the observer finds things out - the parts that can be checked without
/// breaking anything.
final class ObserverProbeTests: XCTestCase {

    // MARK: - Processes

    func testItFindsItsOwnProcess() {
        let processes = ObserverProbe.processes()
        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(processes.contains { $0.pid == getpid() },
                      "a scan that cannot see the scanner is not a scan")
    }

    /// Every process name the kernel reports is capped at 16 characters, so
    /// a name longer than that has to be compared in truncated form or it
    /// never matches anything.
    func testALongNameIsMatchedTheWayTheKernelRecordsIt() {
        // 16, measured on this Mac: the longest `p_comm` any process has is
        // "Microsoft Edge H", and `<sys/param.h>` says MAXCOMLEN 16.
        let long = ObserverProbe.Process(pid: 7, ppid: 1,
                                         name: "qtcreator-with-a", isZombie: false)
        XCTAssertEqual(ObserverProbe.pid(named: "qtcreator-with-a-long-name", in: [long]), 7)
        XCTAssertEqual(ObserverProbe.commLimit, 16)
    }

    /// A process that has exited and not been reaped is not running, however
    /// much it still looks like one - MSL's app hosts leave these behind.
    func testAZombieIsNotARunningProcess() {
        let zombie = ObserverProbe.Process(pid: 9, ppid: 1, name: "mslhd", isZombie: true)
        XCTAssertNil(ObserverProbe.pid(named: "mslhd", in: [zombie]))
    }

    func testTheInstanceComesFromTheHostsOwnArguments() {
        // Every app host is a copy of the same binary in the same directory,
        // so its arguments are the only thing that tells two instances apart.
        XCTAssertEqual(ObserverProbe.instance(
            inCommandLine: "/Users/a/Library/Caches/MSL/AppShims/Krita --instance Milk --app krita"),
            "Milk")
        XCTAssertNil(ObserverProbe.instance(inCommandLine: "/usr/bin/krita"))
        XCTAssertNil(ObserverProbe.instance(inCommandLine: "mslgui --instance"),
                     "a flag with nothing after it names no instance")
    }

    /// A name is not proof. Somebody else's `Python3` is not MSL's, and
    /// recording it as MSL's would put other people's processes in the
    /// observer's record.
    func testAnAppHostIsProvedByItsPathNotItsName() {
        XCTAssertTrue(ObserverProbe.isAppHost(
            "/Users/a/Library/Caches/MSL/AppShims/Python3 --instance Milk"))
        XCTAssertFalse(ObserverProbe.isAppHost("/opt/homebrew/bin/python3 -m http.server"))
    }

    // MARK: - Quoting MSL's own logs

    func testTheFirstSightOfALogStartsAtItsEnd() throws {
        let url = try write("10-22 01:00:00 mslhd power: something old\n")
        let (lines, offset) = ObserverProbe.newLines(in: url, from: nil)
        XCTAssertEqual(lines, [], "a log the observer has never read is history, not news")
        XCTAssertEqual(offset, UInt64(try Data(contentsOf: url).count))
    }

    func testNewLinesAreTheOnesSinceLastTime() throws {
        let url = try write("10-22 01:00:00 mslhd power: old\n")
        let (_, first) = ObserverProbe.newLines(in: url, from: nil)
        try append("10-22 01:00:05 mslhd power: new\n", to: url)
        let (lines, _) = ObserverProbe.newLines(in: url, from: first)
        XCTAssertEqual(lines, ["10-22 01:00:05 mslhd power: new"])
    }

    /// The MSL panel's Clear truncates these logs in place - it has to,
    /// because unlinking a file the daemon holds open sends its output to an
    /// inode with no name. A remembered offset past the new end has to go
    /// back to the start rather than read rubbish.
    func testATruncatedLogIsReadFromTheStartAgain() throws {
        let url = try write(String(repeating: "10-22 01:00:00 mslhd a: line\n", count: 40))
        let (_, offset) = ObserverProbe.newLines(in: url, from: nil)
        try write("10-22 02:00:00 mslhd a: after the clear\n", at: url)
        let (lines, _) = ObserverProbe.newLines(in: url, from: offset)
        XCTAssertEqual(lines, ["10-22 02:00:00 mslhd a: after the clear"])
    }

    func testAnObserverThatHasBeenAwayReadsOnlyTheNewestPart() throws {
        let url = try write("")
        let (_, offset) = ObserverProbe.newLines(in: url, from: nil)
        try append(String(repeating: "10-22 01:00:00 mslhd a: filler\n", count: 5000), to: url)
        let (lines, _) = ObserverProbe.newLines(in: url, from: offset, limit: 1024)
        XCTAssertLessThan(lines.count, 60, "a catch-up must not read a megabyte in one tick")
    }

    /// Guest kernel console output is the bulk of `mslhd.log` and is not MSL
    /// doing anything. MSL's own stamped lines are.
    func testGuestConsoleNoiseIsLeftOut() {
        XCTAssertTrue(ObserverProbe.isMSLOwnLine("10-22 01:00:00 mslhd idle: Imy: hibernating"))
        XCTAssertTrue(ObserverProbe.isMSLOwnLine("10-22 01:00:00 mslgui x11: window mapped"))
        XCTAssertFalse(ObserverProbe.isMSLOwnLine("[    0.123456] Linux version 6.18.54"))
        XCTAssertFalse(ObserverProbe.isMSLOwnLine("   "))
        // Anything that named itself a failure is worth keeping whatever
        // shape it is in.
        XCTAssertTrue(ObserverProbe.isMSLOwnLine("mslhd: FATAL: control socket could not be served"))
    }

    // MARK: - MSL's state

    func testAMissingRegistryIsAMacWithNoInstancesNotAFault() throws {
        try FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(
            at: ObserverPaths.appSupport.appendingPathComponent("instances.json"))
        XCTAssertTrue(ObserverProbe.registryReadable())
    }

    func testAnUnparseableRegistryIsAFault() throws {
        try FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                withIntermediateDirectories: true)
        try "{not json".write(to: ObserverPaths.appSupport.appendingPathComponent("instances.json"),
                              atomically: true, encoding: .utf8)
        XCTAssertFalse(ObserverProbe.registryReadable())
    }

    /// Tested by writing, because the permission bits lie on a read-only
    /// volume and `isWritableFile` believes them.
    func testAMissingStateFolderIsNotWritable() {
        try? FileManager.default.removeItem(at: ObserverPaths.appSupport)
        XCTAssertFalse(ObserverProbe.stateWritable())
        try? FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                 withIntermediateDirectories: true)
        XCTAssertTrue(ObserverProbe.stateWritable())
    }

    /// A probe must leave nothing behind.
    func testTheWriteProbeCleansUpAfterItself() throws {
        try FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ObserverProbe.stateWritable())
        let left = try FileManager.default.contentsOfDirectory(atPath: ObserverPaths.appSupport.path)
        XCTAssertFalse(left.contains { $0.contains("write-probe") }, "\(left)")
    }

    // MARK: - The daemon

    /// Nothing listening is "could not connect", never a hang and never a
    /// crash - the observer is often looking at a socket whose daemon is gone.
    func testProbingASocketThatIsNotThereAnswersCleanly() {
        setenv("MSL_OBSERVER_SOCKET",
               ObserverPaths.appSupport.appendingPathComponent("nothing.sock").path, 1)
        defer { unsetenv("MSL_OBSERVER_SOCKET") }
        let result = ObserverProbe.probeDaemon(timeout: 1)
        XCTAssertFalse(result.connected)
        XCTAssertNil(result.answered)
    }

    // MARK: - Helpers

    private func write(_ text: String) throws -> URL {
        let url = ObserverPaths.logs.appendingPathComponent("probe-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: ObserverPaths.logs,
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func write(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

/// What an incident quotes as evidence, which is the one genuine error code
/// in the whole business - an exception type and a signal, from macOS itself.
final class ObserverEvidenceTests: XCTestCase {
    func report(_ process: String, _ summary: String) -> ObserverProbe.CrashReport {
        ObserverProbe.CrashReport(name: "\(process)-x.ips", process: process,
                                  summary: summary, modified: Date())
    }

    /// Reports are scanned every sixth look. Held per-look, the evidence was
    /// absent from five raises in six - which is most of the ones that had
    /// anything to quote.
    func testEvidenceSurvivesAScanThatFindsNothing() {
        XCTAssertEqual(
            ObserverLoop.evidence(from: [], daemon: "mslhd",
                                  carrying: "mslhd: EXC_BAD_ACCESS (SIGSEGV)"),
            "mslhd: EXC_BAD_ACCESS (SIGSEGV)")
    }

    /// A Linux app host crashing says nothing about why the service will not
    /// stay up. Quoting it under a code about the service is worse than
    /// quoting nothing.
    func testAnAppHostsCrashIsNotEvidenceAboutTheService() {
        let reports = [report("mslhd", "EXC_BAD_ACCESS (SIGSEGV)"),
                       report("Krita", "EXC_CRASH (SIGABRT)")]
        XCTAssertEqual(ObserverLoop.evidence(from: reports, daemon: "mslhd", carrying: nil),
                       "mslhd: EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertNil(ObserverLoop.evidence(from: [report("Krita", "EXC_CRASH (SIGABRT)")],
                                           daemon: "mslhd", carrying: nil))
    }

    func testTheNewestReportWins() {
        let reports = [report("mslhd", "the older one"), report("mslhd", "the newer one")]
        XCTAssertEqual(ObserverLoop.evidence(from: reports, daemon: "mslhd", carrying: nil),
                       "mslhd: the newer one")
    }

    /// A report macOS wrote in a format the observer could not read is still
    /// worth saying happened.
    func testAnUnreadableReportStillCounts() {
        XCTAssertEqual(ObserverLoop.evidence(from: [report("mslhd", "")],
                                             daemon: "mslhd", carrying: nil),
                       "mslhd: macOS wrote a crash report")
    }
}
