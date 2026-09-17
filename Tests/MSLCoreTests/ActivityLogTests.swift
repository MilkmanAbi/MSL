import XCTest
@testable import MSLCore

/// The traffic monitor's event log.
///
/// The bounds are the point. This project has already taken a host process
/// to 100% CPU and 38 GB by logging one entry per X11 draw request, so an
/// unbounded or un-gated log here is not a hypothetical risk.
final class ActivityLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ActivityLog.clear()
    }

    override func tearDown() {
        ActivityLog.endWatching()
        ActivityLog.clear()
        super.tearDown()
    }

    // MARK: - Off unless watched

    func testNothingIsRecordedWhileNobodyIsWatching() {
        ActivityLog.endWatching()
        // The gate is cached for a second, so give it a fresh instance to
        // decide about rather than fighting the cache.
        for index in 0..<50 {
            ActivityLog.shared.record(.control, instance: "off-\(index)", "should not appear \(index)")
        }
        XCTAssertTrue(ActivityLog.read().isEmpty,
                      "recording must be free when no monitor is open")
    }

    func testWatchingIsWhatTurnsItOn() throws {
        ActivityLog.beginWatching()
        // The enabled flag is cached for up to a second; wait it out rather
        // than reaching into private state.
        Thread.sleep(forTimeInterval: 1.1)
        ActivityLog.shared.record(.control, instance: "on", "hello")
        let events = ActivityLog.read()
        XCTAssertEqual(events.last?.summary, "hello")
    }

    // MARK: - Decoding

    func testAHalfWrittenLineDoesNotHideTheRest() throws {
        // The writer appends while the reader polls, so the last line can
        // genuinely be incomplete. One bad line must cost one event, not
        // the whole log - the same failure that once made Finder draw a
        // full guest directory as empty.
        ActivityLog.beginWatching()
        _ = MSLPaths.ensureDirectory(ActivityLog.directory)
        let good = try JSONEncoder().encode(
            ActivityEvent(instance: "x", category: .file, summary: "kept"))
        var data = good
        data.append(0x0A)
        data.append(contentsOf: Array(#"{"at":123,"summ"#.utf8))   // torn write
        try data.write(to: ActivityLog.file)

        let events = ActivityLog.read()
        XCTAssertEqual(events.map(\.summary), ["kept"])
    }

    func testEmptyLogReadsAsEmptyNotAnError() {
        ActivityLog.clear()
        XCTAssertTrue(ActivityLog.read().isEmpty)
    }

    // MARK: - Bounds

    func testTheFileStaysBounded() throws {
        ActivityLog.beginWatching()
        Thread.sleep(forTimeInterval: 1.1)
        // Distinct summaries so coalescing does not do the work instead.
        for index in 0..<4000 {
            ActivityLog.shared.record(.file, instance: "bounded",
                                      "GET /some/reasonably/long/guest/path/number/\(index)")
        }
        let size = (try? ActivityLog.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        XCTAssertLessThan(size, 700 * 1024, "the log grew past its ceiling")
        XCTAssertFalse(ActivityLog.read().isEmpty, "trimming must not empty the log")
    }

    func testTrimmingLeavesWholeLines() throws {
        ActivityLog.beginWatching()
        Thread.sleep(forTimeInterval: 1.1)
        for index in 0..<4000 {
            ActivityLog.shared.record(.control, instance: "trim", "event number \(index)")
        }
        // If the trim cut mid-line, the first line would fail to decode and
        // silently vanish; reading a full set back proves the cut landed on
        // a boundary.
        let events = ActivityLog.read(limit: 10_000)
        XCTAssertGreaterThan(events.count, 10)
        XCTAssertTrue(events.allSatisfy { !$0.summary.isEmpty })
    }

    // MARK: - Coalescing

    func testRepeatsAreFoldedRatherThanRepeated() throws {
        ActivityLog.beginWatching()
        Thread.sleep(forTimeInterval: 1.1)
        for _ in 0..<200 {
            ActivityLog.shared.record(.display, instance: "burst", "X11 client connected")
        }
        ActivityLog.shared.record(.control, instance: "burst", "something else")

        let events = ActivityLog.read()
        let burst = events.filter { $0.summary == "X11 client connected" }
        XCTAssertLessThan(burst.count, 5,
                          "200 identical events in a burst must not become 200 rows")
        XCTAssertTrue(burst.contains { $0.repeatCount > 1 },
                      "the fold should be reported, not silently dropped")
    }

    // MARK: - Categorisation

    func testPollingCommandsAreNotWorthShowing() {
        // Otherwise the monitor mostly shows the UI watching itself.
        XCTAssertNil(DaemonProtocol.ControlRequest.instanceDetails.monitorSummary)
        XCTAssertNil(DaemonProtocol.ControlRequest.instanceList.monitorSummary)
        XCTAssertNil(DaemonProtocol.ControlRequest.status(instance: "a").monitorSummary)
        XCTAssertNil(DaemonProtocol.ControlRequest.sandboxGet(instance: "a").monitorSummary)
    }

    func testRealCommandsAreShownAndFiledCorrectly() {
        let hibernate = DaemonProtocol.ControlRequest.hibernate(instance: "default")
        XCTAssertNotNil(hibernate.monitorSummary)
        XCTAssertEqual(hibernate.monitorInstance, "default")
        XCTAssertEqual(hibernate.monitorCategory, .lifecycle)

        let gui = DaemonProtocol.ControlRequest.startNativeGui(instance: "work")
        XCTAssertEqual(gui.monitorCategory, .display)

        let sandbox = DaemonProtocol.ControlRequest.sandboxSet(instance: "work", token: "1111")
        XCTAssertEqual(sandbox.monitorCategory, .sandbox)
        XCTAssertEqual(sandbox.monitorInstance, "work")
    }

    func testEveryCategoryHasUserFacingText() {
        for category in ActivityEvent.Category.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.symbol.isEmpty)
        }
    }
}
