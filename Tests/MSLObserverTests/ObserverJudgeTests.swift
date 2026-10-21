import XCTest
@testable import MSLObserver

/// The judge is the only part of the observer that can put a window in front
/// of somebody, so these tests are mostly about it **not** doing that.
///
/// Every legitimate outage MSL has is in here as a case that must stay quiet:
/// an upgrade replacing the daemon's binary, the installer booting it out, a
/// `kickstart -k`, the Mac waking from sleep, a crash that launchd recovered
/// from, and MSL having already explained itself. A false crash screen is
/// worse than no observer at all, and those are the ways one would happen.
final class ObserverJudgeTests: XCTestCase {

    /// A healthy Mac: the daemon is up, answering, everything in place.
    func healthy(uptime: Double, pid: Int32 = 500, answered: Bool? = true) -> ObserverFacts {
        ObserverFacts(wall: Date(timeIntervalSince1970: 1_000_000 + uptime), uptime: uptime,
                      daemonPID: pid, daemonBinaryUsable: true, optedOut: false,
                      socketConnected: answered == nil ? nil : true, socketAnswered: answered,
                      stateWritable: true, registryReadable: true)
    }

    /// Runs a stretch of history at a fixed tick, returning every raise.
    func run(_ judge: inout ObserverJudge, seconds: Double, tick: Double = 5,
             from: Double = 0, facts: (Double) -> ObserverFacts) -> [ObserverStopCode] {
        var raises: [ObserverStopCode] = []
        var uptime = from
        while uptime <= from + seconds {
            if let raise = judge.judge(facts(uptime)).raise { raises.append(raise.code) }
            uptime += tick
        }
        return raises
    }

    // MARK: - Nothing wrong

    func testHealthyMacRaisesNothing() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 3600) { healthy(uptime: $0) }
        XCTAssertEqual(raises, [])
    }

    func testFirstSightOfAWorkingDaemonIsNoted() {
        var judge = ObserverJudge()
        let judgement = judge.judge(healthy(uptime: 10))
        XCTAssertNil(judgement.raise)
        XCTAssertTrue(judgement.notes.contains { $0.contains("running as pid 500") })
    }

    // MARK: - The legitimate outages, which must stay quiet

    /// `HostToolInstaller` unlinks `mslhd` and copies the new one in, and the
    /// installer boots the job out. Both are brief; neither is a fault.
    func testAnUpgradeReplacingTheBinaryIsQuiet() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 600) { uptime in
            var facts = healthy(uptime: uptime)
            // Gone for 20 seconds, and the daemon restarts after it.
            if (100...120).contains(uptime) {
                facts.daemonBinaryUsable = false
                facts.daemonPID = nil
                facts.socketConnected = false
                facts.socketAnswered = false
            } else if uptime > 120 {
                facts.daemonPID = 777
            }
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// One `launchctl kickstart -k`, or one crash that KeepAlive recovered.
    /// A single restart is the system working.
    func testOneRestartIsQuiet() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1800) { uptime in
            healthy(uptime: uptime, pid: uptime < 300 ? 500 : 900)
        }
        XCTAssertEqual(raises, [])
    }

    /// Three restarts is still not a loop, so the fourth is where the line is.
    /// Checked from below as well as above, because a threshold tested only
    /// from one side is a threshold nobody knows the value of.
    func testThreeRestartsWithoutServiceIsStillQuiet() {
        var judge = ObserverJudge()
        var raises: [ObserverStopCode] = []
        // Four pids is three restarts: first sight of a daemon is not one.
        for (index, uptime) in stride(from: 10.0, to: 90.0, by: 20).enumerated() {
            var facts = healthy(uptime: uptime, pid: Int32(500 + index), answered: false)
            facts.socketConnected = false
            if let raise = judge.judge(facts).raise { raises.append(raise.code) }
        }
        XCTAssertEqual(raises, [])
    }

    func testFourRestartsWithoutServiceStops() {
        var judge = ObserverJudge()
        var raised: ObserverStopCode?
        // Five pids is four restarts, which is where the line is.
        for (index, uptime) in stride(from: 10.0, through: 90.0, by: 20).enumerated() {
            var facts = healthy(uptime: uptime, pid: Int32(500 + index), answered: false)
            facts.socketConnected = false
            facts.newestCrashReport = "mslhd: EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS"
            if let raise = judge.judge(facts).raise, raised == nil {
                raised = raise.code
                XCTAssertTrue(raise.detail.contains("EXC_BAD_ACCESS"),
                              "the incident must quote what macOS said: \(raise.detail)")
            }
        }
        XCTAssertEqual(raised, .serviceWillNotStayUp)
    }

    /// Crash reports are scanned every sixth look, so the exception type has
    /// to be carried forward - held per-look it was absent from five raises
    /// out of six, which is most of the ones that had something to quote.
    func testTheExceptionTypeSurvivesLooksThatDoNotScan() {
        var judge = ObserverJudge()
        var raised: ObserverStopCode?
        var detail = ""
        for (index, uptime) in stride(from: 10.0, through: 90.0, by: 20).enumerated() {
            var facts = healthy(uptime: uptime, pid: Int32(500 + index), answered: false)
            facts.socketConnected = false
            // Seen once, early, and carried by the caller after that - which
            // is what `ObserverLoop` now does.
            facts.newestCrashReport = "mslhd: EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS"
            if let raise = judge.judge(facts).raise, raised == nil {
                raised = raise.code
                detail = raise.detail
            }
        }
        XCTAssertEqual(raised, .serviceWillNotStayUp)
        XCTAssertTrue(detail.contains("KERN_INVALID_ADDRESS"), detail)
    }

    /// Restarts that *did* serve in between are a daemon being bounced, which
    /// is what an update does to it. Not a loop.
    func testRestartsThatAnsweredInBetweenAreQuiet() {
        var judge = ObserverJudge()
        var raises: [ObserverStopCode] = []
        for (index, uptime) in stride(from: 10.0, through: 300.0, by: 10).enumerated() {
            // A new pid every other tick, each of which answers.
            let facts = healthy(uptime: uptime, pid: Int32(500 + index / 2))
            if let raise = judge.judge(facts).raise { raises.append(raise.code) }
        }
        XCTAssertEqual(raises, [])
    }

    // MARK: - A wedged daemon

    func testADaemonThatConnectsAndNeverAnswersStops() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 400) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            return facts
        }
        XCTAssertEqual(raises, [.serviceStoppedAnswering])
    }

    /// Answering `INSTANCES` reads each instance's state through the VM
    /// manager's serial queue, and that queue is held for as long as it takes
    /// to freeze a guest and write its memory to disk. A shutdown that saves
    /// four of them can legitimately leave the socket silent for minutes -
    /// and the service goes on writing its own log the whole time.
    func testASlowButTalkingServiceIsNotWedged() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1800) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            facts.daemonSpoke = true
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// But a service that has gone quiet on both - the socket and its own
    /// log - is a service nobody is going to hear from again.
    func testASilentServiceIsStillCaught() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1200) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            // It spoke while it was saving, then stopped.
            facts.daemonSpoke = uptime < 120
            return facts
        }
        XCTAssertEqual(raises, [.serviceStoppedAnswering])
    }

    /// Every MSL process writes to the same log - the per-application hosts
    /// most of all - so "MSL said something" is far too weak to mean the
    /// service is alive.
    func testOnlyTheServicesOwnLinesCountAsTheServiceTalking() {
        XCTAssertTrue(ObserverLoop.wasWritten(by: "mslhd",
            "10-22 01:40:57 mslhd idle: Imy: hibernating"))
        XCTAssertFalse(ObserverLoop.wasWritten(by: "mslhd",
            "10-22 01:40:57 mslgui x11: window mapped"))
        XCTAssertFalse(ObserverLoop.wasWritten(by: "mslhd", "  "))
        XCTAssertFalse(ObserverLoop.wasWritten(by: "mslhd", "mslhd: FATAL: something"))
    }

    /// Two minutes of silence is inside what a shutdown response is allowed -
    /// mslhd's LaunchAgent gives it 40 seconds to freeze and write out every
    /// guest, and `power-test` drives the same path while the Mac is awake.
    func testTwoMinutesOfSilenceIsQuiet() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 120) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    func testAnsweringAgainClearsTheStreak() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1200) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            // Answers once every 150 seconds, which is a slow daemon, not a
            // dead one.
            if Int(uptime) % 150 < 5 { facts.socketAnswered = true }
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// A daemon that is not running cannot be wedged. Without this, every
    /// deliberately stopped service was "not answering" forever.
    func testNoDaemonIsNotAWedgedDaemon() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 900) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.daemonPID = nil
            facts.socketConnected = false
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    // MARK: - Sleep, and gaps in watching

    /// Waking up after an hour must not look like an hour of outage. The
    /// uptime clock does not advance while the Mac sleeps and the wall clock
    /// does, and the difference is how the observer knows.
    func testWakingFromSleepDoesNotCountTheTimeAsleep() {
        var judge = ObserverJudge()
        var facts = healthy(uptime: 100, answered: false)
        facts.socketConnected = true
        _ = judge.judge(facts)
        // An hour later by the clock, five seconds later by uptime.
        var after = healthy(uptime: 105, answered: false)
        after.socketConnected = true
        after.wall = facts.wall.addingTimeInterval(3600)
        let judgement = judge.judge(after)
        XCTAssertNil(judgement.raise)
        XCTAssertTrue(judgement.notes.contains { $0.contains("gap in watching") })
        // And the streak really did start again: 170 more seconds of silence
        // is not enough.
        let raises = run(&judge, seconds: 170, from: 110) { uptime in
            var later = healthy(uptime: uptime, answered: false)
            later.socketConnected = true
            later.wall = after.wall.addingTimeInterval(uptime - 105)
            return later
        }
        XCTAssertEqual(raises, [])
    }

    func testAStalledObserverStartsCountingAgain() {
        var judge = ObserverJudge()
        var facts = healthy(uptime: 100, answered: false)
        facts.socketConnected = true
        _ = judge.judge(facts)
        // Both clocks jumped: the observer was descheduled, not asleep.
        var after = healthy(uptime: 400, answered: false)
        after.socketConnected = true
        after.wall = facts.wall.addingTimeInterval(300)
        XCTAssertNil(judge.judge(after).raise)
    }

    // MARK: - A half-finished install

    func testAMissingBinaryStopsAfterItStaysMissing() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 400) { uptime in
            var facts = healthy(uptime: uptime)
            facts.daemonBinaryUsable = false
            return facts
        }
        XCTAssertEqual(raises, [.serviceIsNotInstalled])
    }

    // MARK: - MSL's own folder

    func testAnUnwritableStateFolderStops() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 300) { uptime in
            var facts = healthy(uptime: uptime)
            facts.stateWritable = false
            return facts
        }
        XCTAssertEqual(raises, [.stateDirectoryUnusable])
    }

    func testAnUnreadableRegistryStops() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 300) { uptime in
            var facts = healthy(uptime: uptime)
            facts.registryReadable = false
            return facts
        }
        XCTAssertEqual(raises, [.stateDirectoryUnusable])
    }

    /// The state of the folder is not about the daemon, so turning the
    /// service off does not excuse it.
    func testAnUnwritableFolderStopsEvenWhenTheServiceIsOptedOut() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 300) { uptime in
            var facts = healthy(uptime: uptime)
            facts.optedOut = true
            facts.daemonPID = nil
            facts.socketConnected = false
            facts.socketAnswered = false
            facts.stateWritable = false
            return facts
        }
        XCTAssertEqual(raises, [.stateDirectoryUnusable])
    }

    // MARK: - Deferring, latching, opting out

    /// Somebody who turned the service off meant it, so it not running is not
    /// a fault - and neither is its binary being gone afterwards.
    func testOptingOutSilencesEverythingAboutTheService() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1800) { uptime in
            var facts = healthy(uptime: uptime)
            facts.optedOut = true
            facts.daemonPID = nil
            facts.daemonBinaryUsable = false
            facts.socketConnected = false
            facts.socketAnswered = false
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// MSL stopping on purpose with one of its own codes is a better
    /// explanation than anything inferred from outside, so the observer must
    /// not put a second window over it.
    func testMSLsOwnCrashScreenSilencesTheObserver() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 900) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            facts.crashNoteAge = 10
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// **The note does not stay on disk.** The window that shows one deletes
    /// it a second or two after opening, so a judge that defers only while
    /// the file is there defers for exactly one look - and then counts the
    /// restarts of a service that is stopping itself on purpose and puts a
    /// second, vaguer window over MSL's own.
    ///
    /// This is that sequence: mslhd stops itself with one of its own codes,
    /// the note appears for one look and is gone, and launchd restarts it
    /// into the same failure over and over.
    func testASeenNoteKeepsTheObserverQuietAfterTheFileIsDeleted() {
        var judge = ObserverJudge()
        var raises: [ObserverStopCode] = []
        for (index, uptime) in stride(from: 10.0, through: 110.0, by: 10).enumerated() {
            var facts = healthy(uptime: uptime, pid: Int32(500 + index), answered: false)
            facts.socketConnected = false
            // Visible on the first look only, exactly as in life.
            facts.crashNoteAge = uptime == 10 ? 1 : nil
            if let raise = judge.judge(facts).raise { raises.append(raise.code) }
        }
        XCTAssertEqual(raises, [],
                       "MSL's own crash screen already said what happened")
    }

    /// The same, through the half that cannot be missed: `MSLLog` writes a
    /// `FATAL:` line immediately before every deliberate stop, and the
    /// observer reads MSL's log by offset.
    func testAFatalLineInMSLsOwnLogSilencesTheObserver() {
        var judge = ObserverJudge()
        var raises: [ObserverStopCode] = []
        for (index, uptime) in stride(from: 10.0, through: 110.0, by: 10).enumerated() {
            var facts = healthy(uptime: uptime, pid: Int32(500 + index), answered: false)
            facts.socketConnected = false
            facts.mslSaidFatal = uptime == 10
            if let raise = judge.judge(facts).raise { raises.append(raise.code) }
        }
        XCTAssertEqual(raises, [])
    }

    /// The hold-off is a pause, not an amnesty: a service still failing two
    /// minutes after MSL last explained itself is a service nobody has
    /// explained.
    func testTheHoldOffExpires() {
        var judge = ObserverJudge()
        var facts = healthy(uptime: 10, answered: false)
        facts.socketConnected = true
        facts.crashNoteAge = 1
        _ = judge.judge(facts)
        let raises = run(&judge, seconds: 600, from: 20) { uptime in
            var later = healthy(uptime: uptime, answered: false)
            later.socketConnected = true
            return later
        }
        XCTAssertEqual(raises, [.serviceStoppedAnswering])
    }

    // MARK: - MSL being removed

    /// Deleting `~/Library/Application Support/MSL` by hand - which is how a
    /// fresh install gets tested - takes the observer's own program with it,
    /// while this process goes on running from an unlinked inode.
    /// Everything it would report then is a description of a successful
    /// uninstall.
    func testRemovingMSLIsNotAFailure() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 1800) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.observerInstalled = false
            facts.daemonBinaryUsable = false
            facts.stateWritable = false
            facts.registryReadable = false
            facts.daemonPID = nil
            facts.socketConnected = false
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// An old note is not an explanation of anything happening now.
    func testAnOldCrashNoteDoesNotSilenceTheObserver() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 400) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            facts.crashNoteAge = 7200
            return facts
        }
        XCTAssertEqual(raises, [.serviceStoppedAnswering])
    }

    func testACodeIsShownOnceAndThenOnlyNoted() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 3600) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            return facts
        }
        XCTAssertEqual(raises, [.serviceStoppedAnswering], "a crash screen must not reappear")
        XCTAssertTrue(judge.raised.contains(ObserverStopCode.serviceStoppedAnswering.number))
    }

    /// A restarted observer inherits the latch, so it does not show a screen
    /// the person has already dealt with.
    func testAnInheritedLatchStaysLatched() {
        var judge = ObserverJudge(raised: [ObserverStopCode.serviceStoppedAnswering.number])
        let raises = run(&judge, seconds: 900) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            return facts
        }
        XCTAssertEqual(raises, [])
    }

    /// The worse diagnosis wins. A folder MSL cannot write explains the
    /// daemon falling over; the daemon falling over does not explain the
    /// folder.
    func testTheUnderlyingConditionIsTheOneShown() {
        var judge = ObserverJudge()
        let raises = run(&judge, seconds: 400) { uptime in
            var facts = healthy(uptime: uptime, answered: false)
            facts.socketConnected = true
            facts.stateWritable = false
            facts.daemonBinaryUsable = false
            return facts
        }
        XCTAssertEqual(raises.first, .stateDirectoryUnusable)
    }

    // MARK: - The codes themselves

    func testEveryCodeIsUniqueAndCarriesAWayOut() {
        let numbers = ObserverStopCode.all.map(\.number)
        XCTAssertEqual(Set(numbers).count, numbers.count, "a number must mean one thing")
        for code in ObserverStopCode.all {
            XCTAssertFalse(code.next.isEmpty,
                           "\(code.name) must say what to do - the observer only raises "
                           + "conditions it understands")
            XCTAssertFalse(code.happened.isEmpty)
            XCTAssertEqual(code.name, code.name.uppercased())
            XCTAssertTrue(code.number >= 0x20,
                          "0x01-0x13 belong to MSL's own codes")
            XCTAssertEqual(ObserverStopCode.code(named: code.name), code)
        }
    }

    func testTheNumberIsPrintedTheWaySomebodyWouldSearchForIt() {
        XCTAssertEqual(ObserverStopCode.serviceWillNotStayUp.printed, "0x00000020")
        XCTAssertEqual(ObserverStopCode.stateDirectoryUnusable.printed, "0x00000023")
    }

    func testEveryCodeHasItsOwnPlaceInTheGuide() {
        for code in ObserverStopCode.all {
            let page = ObserverWiki.page(for: code)
            // The published site is one folder per chapter. A crash screen
            // that sends somebody to a 404 is worse than one that sends them
            // nowhere, so the shape of this address is tested, not assumed.
            XCTAssertTrue(
                page.hasPrefix("https://milkmanabi.github.io/MSL-Wiki/error-codes/all-codes.html#"),
                page)
            XCTAssertFalse(code.wikiAnchor.contains("_"), "an anchor is hyphenated, not underscored")
        }
    }

    /// The component that reports a failure is almost never the one that had
    /// it: everything here is reported by `mslod` and almost none of it is
    /// about `mslod`. A report that does not say which part of MSL it is
    /// about sends people looking in the wrong place.
    func testEveryCodeNamesThePartOfMSLItIsAbout() {
        for code in ObserverStopCode.all {
            XCTAssertFalse(code.subsystem.isEmpty, code.name)
            XCTAssertFalse(code.subsystem.contains("mslod"),
                           "\(code.name) is reported by the observer, not about it")
        }
    }
}
