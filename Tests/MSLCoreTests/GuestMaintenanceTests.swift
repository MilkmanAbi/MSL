import XCTest
@testable import MSLCore

final class GuestMaintenanceTests: XCTestCase {
    // MARK: - Utility results

    func testParsesEachStatus() {
        for (line, status) in [("MSL-RESULT ok all good", GuestUtilityResult.Status.ok),
                               ("MSL-RESULT fail it broke", .fail),
                               ("MSL-RESULT skip not applicable", .skip)] {
            let result = GuestUtilityResult.parse(exitCode: 0, output: "noise\n\(line)\n")
            XCTAssertEqual(result.status, status)
        }
    }

    func testSummaryAndPrecedingOutputAreSeparated() {
        let result = GuestUtilityResult.parse(
            exitCode: 0, output: "Reading package lists...\nDone\nMSL-RESULT ok apt reports no remaining problems\n")
        XCTAssertEqual(result.summary, "apt reports no remaining problems")
        XCTAssertEqual(result.output, "Reading package lists...\nDone")
    }

    /// Only the last result line counts, so earlier output that happens to
    /// look like one can't impersonate the verdict.
    func testTheLastResultLineWins() {
        let result = GuestUtilityResult.parse(
            exitCode: 1, output: "MSL-RESULT ok forged by a package\nMSL-RESULT fail the real answer\n")
        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.summary, "the real answer")
    }

    func testCRLFIsHandled() {
        let result = GuestUtilityResult.parse(exitCode: 0, output: "x\r\nMSL-RESULT ok fine\r\n")
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.summary, "fine")
    }

    /// An image built before the script existed says so, rather than
    /// reporting a generic failure.
    func testMissingScriptIsRecognised() {
        XCTAssertEqual(GuestUtilityResult.parse(exitCode: 127, output: "").status, .toolsMissing)
        XCTAssertEqual(GuestUtilityResult.parse(
            exitCode: 2, output: "sh: /usr/sbin/msl-maintenance: not found").status, .toolsMissing)
        XCTAssertEqual(GuestUtilityResult.parse(
            exitCode: 126, output: "bash: /usr/sbin/msl-maintenance: No such file or directory").status, .toolsMissing)
    }

    func testNoResultLineIsAFailureNotASuccess() {
        let result = GuestUtilityResult.parse(exitCode: 0, output: "it printed things but never concluded")
        XCTAssertEqual(result.status, .fail)
    }

    func testUnknownStatusWordIsAFailure() {
        XCTAssertEqual(GuestUtilityResult.parse(exitCode: 0, output: "MSL-RESULT maybe hmm").status, .fail)
    }

    // MARK: - Commands

    /// Every command is generated here, and none may contain anything a
    /// shell would act on. This is what keeps an enumeration from quietly
    /// becoming arbitrary execution.
    func testCommandsContainNoShellMetacharacters() {
        let forbidden = CharacterSet(charactersIn: ";|&$`<>(){}*?\\\"'\n")
        for utility in GuestUtility.allCases {
            let command = utility.guestCommand(now: Date())
            // Clock sync is plain `date` so it works on old images; every
            // other utility goes through the maintenance script.
            let expectedPrefix = utility == .clockSync ? "date -u -s @" : MaintenanceTools.guestScriptPath + " "
            XCTAssertTrue(command.hasPrefix(expectedPrefix), command)
            XCTAssertNil(command.rangeOfCharacter(from: forbidden), "metacharacter in: \(command)")
        }
    }

    func testClockCarriesTheMacsTime() {
        let now = Date(timeIntervalSince1970: 1_757_600_000)
        XCTAssertEqual(GuestUtility.clockSync.guestCommand(now: now), "date -u -s @1757600000")
    }

    /// The Mac's clock is the only thing that varies - two different times
    /// produce commands differing in nothing but the digits.
    func testTheClockCommandVariesOnlyInItsDigits() {
        let a = GuestUtility.clockSync.guestCommand(now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = GuestUtility.clockSync.guestCommand(now: Date(timeIntervalSince1970: 1_800_000_123))
        XCTAssertEqual(a.filter { !$0.isNumber }, b.filter { !$0.isNumber })
    }

    // MARK: - Clock drift

    func testDriftWording() {
        XCTAssertEqual(ClockDrift.describe(nil), "Clock set to the Mac's time.")
        for jitter in [0, 1, -1] {
            XCTAssertEqual(ClockDrift.describe(jitter), "The clock was already in sync.", "\(jitter)s")
        }
        XCTAssertEqual(ClockDrift.describe(3_600 * 3 + 120 + 17), "Clock set to the Mac's time — it was 3h 2m behind.")
        XCTAssertEqual(ClockDrift.describe(-45), "Clock set to the Mac's time — it was 45s ahead.")
    }

    /// Two units at most: a hibernated guest can be days behind, and
    /// "2d 4h 13m 9s" is precision nobody asked for.
    func testDriftUsesTheTwoLargestUnits() {
        XCTAssertEqual(ClockDrift.format(seconds: 2 * 86_400 + 4 * 3_600 + 13 * 60 + 9), "2d 4h")
        XCTAssertEqual(ClockDrift.format(seconds: 5 * 60 + 3), "5m 3s")
        XCTAssertEqual(ClockDrift.format(seconds: 42), "42s")
        XCTAssertEqual(ClockDrift.format(seconds: 3_600), "1h")
        XCTAssertEqual(ClockDrift.format(seconds: 86_400 + 5), "1d", "the seconds are below the second-largest unit")
        XCTAssertEqual(ClockDrift.format(seconds: 0), "0s")
    }

    // MARK: - Maintenance boot command line

    func testMaintenanceCommandLineForcesReadOnlyAndSwapsInit() {
        let base = "console=hvc0 root=/dev/vda rootfstype=ext4 rw"
        let words = MaintenanceBootAction.fsckRepair.kernelCommandLine(base: base).split(separator: " ").map(String.init)
        XCTAssertTrue(words.contains("ro"))
        XCTAssertFalse(words.contains("rw"), "rw left in beside ro - which one wins is up to the parser")
        XCTAssertTrue(words.contains("init=/usr/sbin/msl-maintenance"))
        XCTAssertTrue(words.contains("msl.action=fsck-repair"))
        XCTAssertTrue(words.contains("root=/dev/vda"), "dropped the root device")
        XCTAssertTrue(words.contains("console=hvc0"), "dropped the console the report comes back on")
        // Without it, an image lacking the script waits in a recovery shell
        // for the whole timeout.
        XCTAssertTrue(words.contains("panic=10"), "no panic= - a missing init would hang the boot")
    }

    func testAnExistingPanicIsReplacedNotDuplicated() {
        let words = MaintenanceBootAction.fsckCheck.kernelCommandLine(base: "root=/dev/vda panic=0 rw")
            .split(separator: " ").map(String.init)
        XCTAssertEqual(words.filter { $0.hasPrefix("panic=") }, ["panic=10"])
    }

    func testAnExistingInitIsReplacedNotDuplicated() {
        let line = MaintenanceBootAction.fsckCheck.kernelCommandLine(base: "root=/dev/vda init=/sbin/other rw")
        XCTAssertEqual(line.components(separatedBy: "init=").count - 1, 1)
        XCTAssertTrue(line.contains("init=/usr/sbin/msl-maintenance"))
    }

    // MARK: - Maintenance boot report

    func testFinishedRepairReport() {
        let transcript = """
        [    0.1] Booting Linux
        MSL-MAINTENANCE-BEGIN fsck-repair
        Pass 1: Checking inodes, blocks, and sizes
        Inode 12 ref count is 7, should be 1.  Fix? yes
        MSL-MAINTENANCE-DONE 1
        """
        let report = MaintenanceBootReport.parse(transcript: transcript, action: .fsckRepair)
        XCTAssertEqual(report.outcome, .finished(.from(exitCode: 1, mode: .repair)))
        XCTAssertTrue(report.log.contains("ref count is 7"))
        XCTAssertFalse(report.log.contains("Booting Linux"), "boot noise leaked into the report")
        XCTAssertFalse(report.log.contains("MSL-MAINTENANCE"), "markers leaked into the report")
    }

    /// The guest reports e2fsck's raw status; the verdict comes from the one
    /// tested table, so a check-mode 4 reads exactly as it does host-side.
    func testGuestReportUsesTheSharedVerdictTable() {
        let report = MaintenanceBootReport.parse(
            transcript: "MSL-MAINTENANCE-BEGIN fsck-check\nMSL-MAINTENANCE-DONE 4\n", action: .fsckCheck)
        guard case .finished(let verdict) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertEqual(verdict.outcome, .problemsRemain)
        XCTAssertEqual(verdict.title, "Problems found")
    }

    func testAnOperationalFailureInTheGuestIsNotClean() {
        let report = MaintenanceBootReport.parse(
            transcript: "MSL-MAINTENANCE-BEGIN fsck-repair\nroot is mounted read-write\nMSL-MAINTENANCE-DONE 8\r\n",
            action: .fsckRepair)
        guard case .finished(let verdict) = report.outcome, case .didNotRun = verdict.outcome else {
            return XCTFail("a refused repair must not read as a result")
        }
    }

    /// The exact console an image without the script produces - Alpine's
    /// initramfs checks init= first. The earliest marker list missed this
    /// entirely, which would have hung the boot for its full timeout.
    func testTheRealMissingScriptMessageIsRecognised() {
        let transcript = """
        [    1.20] EXT4-fs (vda): mounted filesystem with ordered data mode.
        /usr/sbin/msl-maintenance not found in new root
        Launching initramfs emergency recovery shell.
        Type exit to continue boot.
        """
        let report = MaintenanceBootReport.parse(transcript: transcript, action: .fsckCheck)
        XCTAssertEqual(report.outcome, .toolsMissing)
        XCTAssertTrue(report.log.contains("not found in new root"), "the console tail should be kept for diagnosis")
    }

    /// A root that won't mount also lands in the recovery shell, but that's
    /// a damaged disk, not a missing script - and calls for different advice.
    func testAMountFailureIsABootFailureNotMissingTools() {
        let transcript = """
        mount: mounting /dev/vda on /sysroot failed: Invalid argument
        Launching initramfs emergency recovery shell.
        """
        XCTAssertEqual(MaintenanceBootReport.parse(transcript: transcript, action: .fsckRepair).outcome, .bootFailed)
    }

    func testAPanicOnItsOwnIsABootFailure() {
        XCTAssertEqual(MaintenanceBootReport.parse(
            transcript: "Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000\n",
            action: .fsckCheck).outcome, .bootFailed)
    }

    /// What an image without the script produces: the kernel can't run it.
    func testMissingScriptIsDetectedFromTheConsole() {
        for line in ["Kernel panic - not syncing: No working init found.",
                     "Failed to execute /usr/sbin/msl-maintenance (error -2)",
                     "switch_root: can't execute '/usr/sbin/msl-maintenance': No such file or directory"] {
            XCTAssertEqual(MaintenanceBootReport.parse(transcript: "boot\n\(line)\n", action: .fsckCheck).outcome,
                           .toolsMissing, line)
        }
    }

    func testSilenceIsNoResult() {
        XCTAssertEqual(MaintenanceBootReport.parse(transcript: "booting...\nstill booting\n", action: .fsckCheck).outcome,
                       .noResult)
    }

    func testEveryTerminalMarkerIsWaitedFor() {
        XCTAssertTrue(MaintenanceBootReport.terminalMarkers.contains(MaintenanceBootReport.doneMarker))
        for marker in MaintenanceBootReport.toolsMissingMarkers + MaintenanceBootReport.bootFailedMarkers {
            XCTAssertTrue(MaintenanceBootReport.terminalMarkers.contains(marker), marker)
        }
    }

    // MARK: - Probe

    func testDebugfsAnswersAreInterpreted() {
        XCTAssertEqual(MaintenanceTools.interpretDebugfsStat(
            "/usr/sbin/msl-maintenance: File not found by ext2_lookup"), false)
        XCTAssertEqual(MaintenanceTools.interpretDebugfsStat(
            "Inode: 1234   Type: regular    Mode:  0755   Flags: 0x80000"), true)
        XCTAssertNil(MaintenanceTools.interpretDebugfsStat("debugfs: Bad magic number in super-block"))
    }

    // MARK: - Settings

    func testCheckAtStartIsOffByDefault() {
        XCTAssertFalse(MaintenanceSettings.defaults.checkFilesystemAtStart)
        let instance = "maint-default-\(UUID().uuidString)"
        XCTAssertFalse(MaintenanceSettingsStore.load(instance: instance).checkFilesystemAtStart)
    }

    func testSettingsRoundTrip() {
        let instance = "maint-roundtrip-\(UUID().uuidString)"
        defer { MaintenanceSettingsStore.forget(instance: instance) }
        XCTAssertTrue(MaintenanceSettingsStore.save(.init(checkFilesystemAtStart: true), instance: instance))
        XCTAssertTrue(MaintenanceSettingsStore.load(instance: instance).checkFilesystemAtStart)
    }
}
