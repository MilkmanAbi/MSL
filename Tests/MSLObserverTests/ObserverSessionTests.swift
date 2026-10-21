import XCTest
@testable import MSLObserver

/// The record, and the one rule about how long it lives.
///
/// These run against a throwaway directory: `ObserverPaths` puts itself in a
/// temporary folder whenever XCTest is loaded, precisely so a test of code
/// that **deletes logs** can never reach a real one.
final class ObserverSessionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: ObserverPaths.logs)
        try? FileManager.default.removeItem(at: ObserverPaths.appSupport)
    }

    func testTheTestDirectoryIsNotTheRealOne() {
        // If this ever fails, every other test in this file is deleting
        // somebody's logs.
        XCTAssertFalse(ObserverPaths.logs.path.hasPrefix(NSHomeDirectory() + "/Library/Logs"),
                       ObserverPaths.logs.path)
    }

    // MARK: - One file per boot

    func testARecordStartedThisBootIsContinued() {
        let first = ObserverSession()
        first.write("the first thing")
        first.saveState(force: true)

        // A second observer in the same boot: the record continues.
        let second = ObserverSession()
        second.write("the second thing")
        let text = (try? String(contentsOf: ObserverPaths.log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("the first thing"), text)
        XCTAssertTrue(text.contains("the second thing"), text)
        XCTAssertEqual(text.components(separatedBy: "#session ").count - 1, 1,
                       "one session header per boot")
    }

    /// The header is the file's first line, unstamped, because that is what
    /// the boot check reads. Stamping it put the date in front of `#session`
    /// and every start looked like a new boot - which wiped the record it was
    /// meant to continue.
    func testTheHeaderIsTheFirstLineAndCarriesTheBoot() {
        _ = ObserverSession()
        let text = (try? String(contentsOf: ObserverPaths.log, encoding: .utf8)) ?? ""
        let first = text.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(first.hasPrefix("#session boot="), first)
        XCTAssertTrue(ObserverSession.logBelongs(toBoot: ObserverSession.bootTime()))
        XCTAssertFalse(ObserverSession.logBelongs(toBoot: 1))
    }

    func testARecordFromAnotherBootIsThrownAway() throws {
        try FileManager.default.createDirectory(at: ObserverPaths.logs,
                                                withIntermediateDirectories: true)
        try "#session boot=1 version=MSL-2.0.0\nfrom another boot\n"
            .write(to: ObserverPaths.log, atomically: true, encoding: .utf8)
        _ = ObserverSession()
        let text = try String(contentsOf: ObserverPaths.log, encoding: .utf8)
        XCTAssertFalse(text.contains("from another boot"), text)
    }

    /// The observer must never reach for anything that is not its own, and
    /// `mslhd.log` is MSL's.
    func testOnlyTheObserversOwnFilesAreTouched() {
        XCTAssertEqual(ObserverSession.disposal(of: "observer.log"), .remove)
        XCTAssertEqual(ObserverSession.disposal(of: "observer-session.json"), .remove)
        // launchd holds this one open. Unlinking it would leave launchd
        // writing to an inode with no name for the rest of the boot - so the
        // one log that explains a broken observer would be the one certain
        // to be lost.
        XCTAssertEqual(ObserverSession.disposal(of: "observer-launchd.log"), .truncate)
        XCTAssertEqual(ObserverSession.disposal(of: "mslhd.log"), .leave)
        XCTAssertEqual(ObserverSession.disposal(of: "msl.log"), .leave)
        XCTAssertEqual(ObserverSession.disposal(of: "something-else.txt"), .leave)
    }

    func testStaleLogsGoAndMSLsOwnStay() throws {
        try FileManager.default.createDirectory(at: ObserverPaths.logs,
                                                withIntermediateDirectories: true)
        let mslhd = ObserverPaths.logs.appendingPathComponent("mslhd.log")
        try "mslhd's own log".write(to: mslhd, atomically: true, encoding: .utf8)
        let launchd = ObserverPaths.logs.appendingPathComponent("observer-launchd.log")
        try "stderr from last boot".write(to: launchd, atomically: true, encoding: .utf8)
        try "#session boot=1\nold".write(to: ObserverPaths.log, atomically: true, encoding: .utf8)

        _ = ObserverSession()

        XCTAssertEqual(try String(contentsOf: mslhd, encoding: .utf8), "mslhd's own log")
        XCTAssertEqual(try String(contentsOf: launchd, encoding: .utf8), "",
                       "truncated, not deleted")
        XCTAssertFalse(try String(contentsOf: ObserverPaths.log, encoding: .utf8).contains("old"))
    }

    // MARK: - What it remembers

    func testTheLatchSurvivesTheObserverRestarting() {
        let first = ObserverSession()
        first.remember(raised: [0x20])
        XCTAssertEqual(ObserverSession().raised, [0x20],
                       "a crash screen must not reappear because the watchdog restarted")
    }

    func testALatchFromAnotherBootIsNotInherited() throws {
        let first = ObserverSession()
        first.remember(raised: [0x20])
        // The log says another boot wrote it, so the state goes with it.
        try "#session boot=1 version=x\n".write(to: ObserverPaths.log,
                                                atomically: true, encoding: .utf8)
        XCTAssertEqual(ObserverSession().raised, [])
    }

    func testACrashReportIsNoticedOnce() {
        let session = ObserverSession()
        XCTAssertTrue(session.noticing(report: "mslhd-2026-10-22.ips"))
        XCTAssertFalse(session.noticing(report: "mslhd-2026-10-22.ips"))
    }

    // MARK: - The incident report

    func testAnIncidentCarriesTheFactsAndTheTail() throws {
        let session = ObserverSession()
        session.write("something before the trouble")
        session.writeIncident(code: .serviceWillNotStayUp,
                              detail: "4 restarts within 300s")

        let text = try String(contentsOf: ObserverPaths.incident, encoding: .utf8)
        let incident = try XCTUnwrap(ObserverIncident.parse(text))
        XCTAssertEqual(incident.code, "0x00000020")
        XCTAssertEqual(incident.name, "SERVICE_WILL_NOT_STAY_UP")
        XCTAssertEqual(incident.subsystem, ObserverStopCode.serviceWillNotStayUp.subsystem)
        XCTAssertEqual(incident.observed, "4 restarts within 300s")
        XCTAssertEqual(incident.reference,
                       ObserverWiki.page(for: .serviceWillNotStayUp))
        XCTAssertNotNil(incident.recorded)
        XCTAssertTrue(incident.body.contains("something before the trouble"),
                      "the report must carry what the observer saw - the log is this boot's only")
        XCTAssertTrue(incident.body.contains(ObserverStopCode.serviceWillNotStayUp.next))
    }

    /// The report is written by one process and read by another, which may be
    /// a different version. A field it does not know must not throw the rest
    /// away.
    func testAnUnknownFieldIsKeptRatherThanFatal() throws {
        let incident = try XCTUnwrap(ObserverIncident.parse("""
        code: 0x00000099
        something-new: a value from a later version

        the body
        """))
        XCTAssertEqual(incident.code, "0x00000099")
        XCTAssertEqual(incident.fields["something-new"], "a value from a later version")
        XCTAssertEqual(incident.body, "the body")
    }

    func testNothingParsesToNothing() {
        XCTAssertNil(ObserverIncident.parse(""))
    }

    /// A value with a colon in it - an address, every time - must survive.
    func testAValueMayContainColons() throws {
        let incident = try XCTUnwrap(ObserverIncident.parse(
            "reference: https://milkmanabi.github.io/MSL-Wiki/error-codes/all-codes.html#x\n\nbody"))
        XCTAssertEqual(incident.reference,
                       "https://milkmanabi.github.io/MSL-Wiki/error-codes/all-codes.html#x")
    }

    // MARK: - Handing over to a newer observer

    /// Installing MSL replaces the observer's program, but launchd goes on
    /// running the copy it already started - and nothing in the install can
    /// restart the job, because the binary is written by the app at launch,
    /// after any script that might have done it.
    ///
    /// Measured 2026-10-22: after a full rebuild and install, the running
    /// observer was still the previous build. Quietly, with no sign of it
    /// anywhere - a stale watchdog looks exactly like a working one.
    func testANewerProgramIsNoticed() throws {
        let binary = ObserverPaths.logs.appendingPathComponent("pretend-mslod")
        try FileManager.default.createDirectory(at: ObserverPaths.logs,
                                                withIntermediateDirectories: true)
        try "v1".write(to: binary, atomically: true, encoding: .utf8)
        let stamp = ObserverLoop.stamp(of: binary)
        XCTAssertNotNil(stamp)
        XCTAssertFalse(ObserverLoop.replaced(since: stamp, binary: binary))

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: binary.path)
        XCTAssertTrue(ObserverLoop.replaced(since: stamp, binary: binary))
    }

    /// A program that is simply *gone* is MSL being removed, which the judge
    /// handles by going quiet - not a handover, which would exit into a
    /// launchd job that cannot start anything.
    func testAMissingProgramIsNotAHandover() {
        let missing = ObserverPaths.logs.appendingPathComponent("not-there")
        XCTAssertFalse(ObserverLoop.replaced(since: Date(), binary: missing))
    }

    // MARK: - The note the crash window reads

    /// The window splits that note on tabs and takes one line, so a detail
    /// carrying either would silently lose everything after it.
    func testTheCrashNoteIsOneLineOfThreeFields() throws {
        ObserverAlarm.writeCrashNote(code: .serviceStoppedAnswering,
                                     detail: "has not\tanswered\nfor 300s")
        let note = try String(contentsOf: ObserverPaths.crashNote, encoding: .utf8)
        XCTAssertEqual(note.components(separatedBy: "\n").count, 2, note)
        let fields = note.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 3, note)
        XCTAssertEqual(fields[0], "mslod")
        XCTAssertEqual(fields[1], "SERVICE_STOPPED_ANSWERING")
        XCTAssertEqual(fields[2], "has not answered for 300s")
    }
}
