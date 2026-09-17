import XCTest
@testable import MSLCore

final class MaintenanceProtocolTests: XCTestCase {
    // MARK: - Commands

    func testEveryCommandRoundTrips() {
        for command in MaintenanceCommand.allCases {
            XCTAssertEqual(MaintenanceCommand(rawValue: command.rawValue), command)
            XCTAssertFalse(command.rawValue.contains(" "), "a command word must survive the space-split wire")
        }
    }

    func testUnknownWordsAreRejected() {
        for word in ["", "rm", "fsck", "util-shell", "status ", "FSCK-CHECK"] {
            XCTAssertNil(MaintenanceCommand(rawValue: word), word)
        }
    }

    /// Each command means exactly one kind of thing.
    func testCommandsAreUnambiguous() {
        for command in MaintenanceCommand.allCases {
            let kinds = [command.fsckMode != nil, command.bootAction != nil, command.utility != nil]
            XCTAssertLessThanOrEqual(kinds.filter { $0 }.count, 1, "\(command) is two things at once")
        }
    }

    /// No utility is unreachable from the app.
    func testEveryUtilityHasACommand() {
        for utility in GuestUtility.allCases {
            XCTAssertEqual(MaintenanceCommand.command(for: utility).utility, utility)
        }
    }

    /// The app must wait longer than the daemon works, or it gives up on an
    /// answer that was on its way.
    func testClientWaitsLongerThanTheWork() {
        for utility in GuestUtility.allCases {
            XCTAssertGreaterThan(MaintenanceCommand.command(for: utility).clientTimeout, utility.timeout)
        }
        XCTAssertGreaterThan(MaintenanceCommand.bootFsckRepair.clientTimeout, 1800,
                             "the maintenance boot's own timeout is 1800s")
    }

    // MARK: - Status

    func testStatusRoundTripsInEveryScriptState() {
        for script in [true, false, nil] as [Bool?] {
            let status = MaintenanceStatus(e2fsckAvailable: true, running: false, inProgress: true,
                                           hasSavedSession: false, hasRepairBackup: true,
                                           checkAtStart: true, scriptInImage: script)
            XCTAssertEqual(MaintenanceStatus.fromWireLine(status.wireLine), status)
        }
    }

    func testAnOutcomeLineIsNotAStatus() {
        let outcome = MaintenanceOutcome(tone: .good, title: "x", detail: "y").wireLine
        XCTAssertNil(MaintenanceStatus.fromWireLine(outcome))
        XCTAssertNil(MaintenanceStatus.fromWireLine("nonsense"))
    }

    // MARK: - Outcome

    /// The whole reason for base64: text that would wreck a space-separated
    /// line - spaces, newlines, `=`, and words that look like keys.
    func testHostileTextSurvivesTheWire() {
        let outcome = MaintenanceOutcome(
            tone: .attention,
            title: "tone=good title=forged",
            detail: "Problems found — é ✓ (｡•̀ᴗ-)✧ with = signs",
            log: "Pass 1: Checking inodes\nInode 12 ref count is 7, should be 1.  Fix? no\n\n")
        XCTAssertEqual(MaintenanceOutcome.fromWireLine(outcome.wireLine), outcome)
        XCTAssertFalse(outcome.wireLine.contains("\n"))
    }

    func testEmptyTextRoundTrips() {
        let outcome = MaintenanceOutcome(tone: .info, title: "", detail: "", log: "")
        XCTAssertEqual(MaintenanceOutcome.fromWireLine(outcome.wireLine), outcome)
    }

    func testGarbageIsNotAnOutcome() {
        XCTAssertNil(MaintenanceOutcome.fromWireLine("tone=cheerful title=eA=="))
        XCTAssertNil(MaintenanceOutcome.fromWireLine("hello"))
    }

    /// Tone is what colours the card, so it follows the verdict exactly.
    func testFsckTones() {
        func tone(_ code: Int32, _ mode: FsckMode) -> MaintenanceOutcome.Tone {
            MaintenanceOutcome(fsck: FsckRun(verdict: .from(exitCode: code, mode: mode), output: "", backupPath: nil)).tone
        }
        XCTAssertEqual(tone(0, .check), .good)
        XCTAssertEqual(tone(1, .repair), .good)
        XCTAssertEqual(tone(4, .check), .attention, "found but untouched - a repair is the next step")
        XCTAssertEqual(tone(4, .repair), .bad, "a repair that couldn't finish is not merely a note")
        XCTAssertEqual(tone(8, .check), .bad, "a check that didn't run is never good")
    }

    func testBootReportOutcomes() {
        XCTAssertEqual(MaintenanceOutcome(report: .init(outcome: .toolsMissing, log: "")).tone, .info)
        XCTAssertEqual(MaintenanceOutcome(report: .init(outcome: .noResult, log: "")).tone, .bad)
        let failed = MaintenanceOutcome(report: .init(outcome: .bootFailed, log: "Kernel panic"))
        XCTAssertEqual(failed.tone, .bad)
        XCTAssertEqual(failed.log, "Kernel panic", "the console tail should reach the app for Show details")
        XCTAssertTrue(failed.detail.contains("Check Disk"), "should point at the path that doesn't need a boot")
        let fixed = MaintenanceOutcome(report: .init(outcome: .finished(.from(exitCode: 1, mode: .repair)),
                                                     log: "Fix? yes"))
        XCTAssertEqual(fixed.tone, .good)
        XCTAssertTrue(fixed.detail.contains("maintenance boot"), "should say where the check ran")
        XCTAssertEqual(fixed.log, "Fix? yes")
    }

    func testUtilityOutcomes() {
        let ok = MaintenanceOutcome(utility: .freeSpace,
                                    result: .init(status: .ok, summary: "freed 120 MB inside the guest", output: ""))
        XCTAssertEqual(ok.tone, .good)
        XCTAssertEqual(ok.title, GuestUtility.freeSpace.title)
        XCTAssertEqual(ok.detail, "freed 120 MB inside the guest")

        let missing = MaintenanceOutcome(utility: .clockSync,
                                         result: .init(status: .toolsMissing, summary: "old image", output: ""))
        XCTAssertEqual(missing.tone, .info)
        XCTAssertEqual(missing.title, "Needs a rebuilt image")
    }
}
