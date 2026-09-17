import Foundation

// MARK: - Settings

/// Per-instance maintenance preferences.
public struct MaintenanceSettings: Codable, Equatable, Sendable {
    /// Run a read-only filesystem check before every start, and refuse to
    /// boot on a damaged disk. **Off by default**: it needs e2fsprogs on the
    /// Mac, and it adds the time of a full check to every start.
    public var checkFilesystemAtStart: Bool

    public init(checkFilesystemAtStart: Bool = false) {
        self.checkFilesystemAtStart = checkFilesystemAtStart
    }

    public static let defaults = MaintenanceSettings()
}

/// Same shape as `SandboxPolicyStore` and `ResourcePolicyStore`.
public enum MaintenanceSettingsStore {
    public static func file(for instance: String) -> URL {
        MSLPaths.appSupport
            .appendingPathComponent("maintenance", isDirectory: true)
            .appendingPathComponent("\(instance).json")
    }

    public static func load(instance: String) -> MaintenanceSettings {
        guard let data = try? Data(contentsOf: file(for: instance)),
              let settings = try? JSONDecoder().decode(MaintenanceSettings.self, from: data)
        else { return .defaults }
        return settings
    }

    @discardableResult
    public static func save(_ settings: MaintenanceSettings, instance: String) -> Bool {
        let url = file(for: instance)
        guard MSLPaths.ensureDirectory(url.deletingLastPathComponent()) else { return false }
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: file(for: instance))
    }
}

// MARK: - The guest script

public enum MaintenanceTools {
    /// Where the image build installs `Guest/init/msl-maintenance.sh`.
    public static let guestScriptPath = "/usr/sbin/msl-maintenance"

    /// Whether a stopped instance's image contains the guest script.
    ///
    /// Uses `debugfs`, which ships beside `e2fsck` in e2fsprogs and reads the
    /// ext4 image directly - read-only by default, so it is safe on a stopped
    /// disk. `nil` means the Mac cannot look inside the image (no e2fsprogs),
    /// which is exactly the case the maintenance boot exists for, so the UI
    /// then lets it be tried rather than claiming it won't work.
    public static func imageContainsScript(imagePath: String, e2fsck: String?) -> Bool? {
        guard let e2fsck else { return nil }
        let debugfs = ((e2fsck as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("debugfs")
        guard FileManager.default.isExecutableFile(atPath: debugfs) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: debugfs)
        process.arguments = ["-R", "stat \(guestScriptPath)", imagePath]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return interpretDebugfsStat(output)
    }

    /// Pure, so the two answers debugfs gives can be tested without it.
    public static func interpretDebugfsStat(_ output: String) -> Bool? {
        if output.contains("File not found") { return false }
        if output.range(of: #"Inode:\s*\d+"#, options: .regularExpression) != nil { return true }
        return nil
    }
}

// MARK: - Utilities in a running guest

/// What can be run inside a running guest.
///
/// An enumeration and not a command string, deliberately. These travel from
/// the app through the daemon to a root shell in the guest; a generic "run
/// this" would turn a maintenance feature into remote code execution for
/// anything that can reach the daemon socket. Every argument is generated
/// here - the only one is the Mac's own clock.
public enum GuestUtility: String, CaseIterable, Sendable {
    case clockSync = "clock"
    case fixPackages = "fix-packages"
    case freeSpace = "free-space"
    case diskErrors = "disk-errors"

    public var title: String {
        switch self {
        case .clockSync: return "Sync clock with the Mac"
        case .fixPackages: return "Repair package manager"
        case .freeSpace: return "Clear caches inside Linux"
        case .diskErrors: return "Check for disk errors"
        }
    }

    public var detail: String {
        switch self {
        case .clockSync:
            return "A guest resumed from hibernation keeps the time it was saved at. This sets it to the Mac's clock — and works on every image, since it needs nothing installed in Linux."
        case .fixPackages:
            return "Finishes interrupted installs and clears a stale lock left by a crash, using this distro's own package manager."
        case .freeSpace:
            return "Clears package caches and trims the system journal. Frees space inside the guest — the disk image on your Mac doesn't shrink."
        case .diskErrors:
            return "Reads the kernel log for filesystem and I/O errors. Read-only — if it finds any, run a filesystem check."
        }
    }

    public var symbol: String {
        switch self {
        case .clockSync: return "clock.arrow.circlepath"
        case .fixPackages: return "shippingbox.and.arrow.backward"
        case .freeSpace: return "sparkles"
        case .diskErrors: return "stethoscope"
        }
    }

    /// Package repairs can download; the rest are quick.
    public var timeout: TimeInterval {
        switch self {
        case .fixPackages, .freeSpace: return 900
        case .clockSync, .diskErrors: return 60
        }
    }

    public func guestCommand(now: Date) -> String {
        switch self {
        case .clockSync:
            // Plain `date`, understood by busybox (Alpine) and coreutils
            // alike - which is what lets clock sync work on images built
            // before the maintenance script existed.
            return "date -u -s @\(Int(now.timeIntervalSince1970))"
        case .fixPackages, .freeSpace, .diskErrors:
            return "\(MaintenanceTools.guestScriptPath) \(rawValue)"
        }
    }
}

public struct GuestUtilityResult: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case ok, fail, skip
        /// The image was built before the script existed.
        case toolsMissing
    }

    public let status: Status
    public let summary: String
    /// Everything the script printed before its result line.
    public let output: String

    /// The script ends with `MSL-RESULT <status> <summary>`. The *last* such
    /// line wins, so a package manager that happened to print something
    /// similar earlier cannot impersonate the verdict.
    public static func parse(exitCode: Int32, output: String) -> GuestUtilityResult {
        // Terminal escapes out first. The command runs on a pty, and pacman
        // hides and re-shows the cursor (ESC[?25l ... ESC[?25h) - the show
        // landed at the start of the result line, so it no longer began with
        // "MSL-RESULT" and Arch's repair read as "didn't report a result"
        // (2026-09-14). Arch's systemd also brackets output in OSC 3008.
        let output = Self.strippingTerminalEscapes(output)
        let lines = output.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if let index = lines.lastIndex(where: { $0.hasPrefix("MSL-RESULT ") }) {
            let fields = lines[index].dropFirst("MSL-RESULT ".count)
                .split(separator: " ", maxSplits: 1).map(String.init)
            let status = Status(rawValue: fields.first ?? "") ?? .fail
            let summary = (fields.count > 1 ? fields[1] : "").trimmingCharacters(in: .whitespaces)
            let before = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return GuestUtilityResult(status: status, summary: summary, output: before)
        }

        // 127 is the shell's "command not found". The text check covers
        // shells that report it differently.
        let text = output.lowercased()
        if exitCode == 127 || text.contains("msl-maintenance: not found")
            || (text.contains("msl-maintenance") && text.contains("no such file")) {
            return GuestUtilityResult(
                status: .toolsMissing,
                summary: "This instance's image was built before MSL's maintenance tools existed.",
                output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return GuestUtilityResult(
            status: .fail,
            summary: "The guest didn't report a result (exit \(exitCode)).",
            output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes CSI sequences (`ESC [ ... letter`) and OSC sequences
    /// (`ESC ] ... BEL` or `ESC ] ... ESC \`).
    static func strippingTerminalEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

extension VMManager {
    /// Runs one utility inside the running guest.
    ///
    /// Needs a running guest by definition - these act on a live system - and
    /// never starts one: if a utility is worth running, the user has already
    /// started the instance.
    public func runGuestUtility(_ utility: GuestUtility) async throws -> GuestUtilityResult {
        guard isRunning else { throw VMManagerError.notRunning }
        if utility == .clockSync { return await syncGuestClock() }
        let result = await runInternalCommand(utility.guestCommand(now: Date()), timeout: utility.timeout)
        return GuestUtilityResult.parse(exitCode: result.exitCode, output: result.output)
    }

    /// Sets the guest's clock to the Mac's, and says how far off it was.
    ///
    /// Two round trips on purpose: reading the guest's time first lets the
    /// Mac work out the drift itself, instead of doing arithmetic inside a
    /// shell command. Also what runs automatically after the Mac wakes - see
    /// `resyncGuestClock`.
    public func syncGuestClock() async -> GuestUtilityResult {
        let read = await runInternalCommand("date -u +%s", timeout: 10)
        let guestEpoch = Int(read.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let now = Date()
        let set = await runInternalCommand(GuestUtility.clockSync.guestCommand(now: now), timeout: 10)
        guard set.exitCode == 0 else {
            return GuestUtilityResult(status: .fail, summary: "The guest refused the new time.",
                                      output: set.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let drift = guestEpoch.map { Int(now.timeIntervalSince1970) - $0 }
        return GuestUtilityResult(status: .ok, summary: ClockDrift.describe(drift), output: "")
    }
}

/// Words for how far a guest's clock had drifted.
public enum ClockDrift {
    /// `drift` is Mac time minus guest time, in seconds - positive means the
    /// guest had fallen behind. `nil` when the guest's time couldn't be read.
    public static func describe(_ drift: Int?) -> String {
        guard let drift else { return "Clock set to the Mac's time." }
        // Two seconds covers the round trip itself; anything inside it is
        // noise, and "it was 1s behind" would read like a real problem.
        if abs(drift) < 2 { return "The clock was already in sync." }
        let amount = format(seconds: abs(drift))
        return drift > 0
            ? "Clock set to the Mac's time — it was \(amount) behind."
            : "Clock set to the Mac's time — it was \(amount) ahead."
    }

    /// The largest unit, and the one directly below it when that isn't zero:
    /// "3h 2m", not "3h 2m 17s".
    ///
    /// Directly below, not the next non-zero one. A day and five seconds is
    /// "1d": skipping past the empty hours and minutes to reach "1d 5s" reads
    /// as a precision no one asking "how far behind was the clock?" wants.
    public static func format(seconds: Int) -> String {
        let units: [(size: Int, label: String)] = [(86_400, "d"), (3_600, "h"), (60, "m"), (1, "s")]
        var values: [Int] = []
        var remaining = max(seconds, 0)
        for unit in units {
            values.append(remaining / unit.size)
            remaining %= unit.size
        }
        guard let first = values.firstIndex(where: { $0 > 0 }) else { return "0s" }
        var text = "\(values[first])\(units[first].label)"
        if first + 1 < units.count, values[first + 1] > 0 {
            text += " \(values[first + 1])\(units[first + 1].label)"
        }
        return text
    }
}

// MARK: - Maintenance boot

/// What a maintenance boot does.
public enum MaintenanceBootAction: String, CaseIterable, Sendable {
    case fsckCheck = "fsck-check"
    case fsckRepair = "fsck-repair"

    public var mode: FsckMode {
        switch self {
        case .fsckCheck: return .check
        case .fsckRepair: return .repair
        }
    }

    /// The normal command line with root forced read-only and the guest
    /// script put in place of init.
    ///
    /// `ro` matters less than it looks - the initramfs mounts root read-only
    /// regardless (`-o "${KOPT_rootflags:-ro}"`) - but it is stated so
    /// nothing downstream mistakes this for a normal boot. `rw` is removed
    /// rather than contradicted: with both present, which one wins is up to
    /// whoever parses the line last.
    ///
    /// `panic=10` is load-bearing. Alpine's initramfs checks that `init=`
    /// exists before switching root, and when it doesn't - any image built
    /// before the script existed - it drops to a recovery shell that waits
    /// for a keyboard forever, printing nothing more. Without `panic=` a
    /// maintenance boot on such an image would sit silent for its whole
    /// timeout with the instance locked. With it, that shell exits at once,
    /// the kernel panics, and the failure is on the console within seconds.
    public func kernelCommandLine(base: String) -> String {
        let kept = base.split(separator: " ").filter {
            $0 != "rw" && $0 != "ro" && !$0.hasPrefix("init=") && !$0.hasPrefix("panic=")
        }
        return (kept.map(String.init)
                + ["ro", "panic=10", "init=\(MaintenanceTools.guestScriptPath)", "msl.action=\(rawValue)"])
            .joined(separator: " ")
    }
}

public struct MaintenanceBootReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The script ran and e2fsck finished; the verdict comes from the
        /// same `FsckVerdict` table the host-side check uses.
        case finished(FsckVerdict)
        /// The guest has no maintenance script, or couldn't execute it.
        case toolsMissing
        /// Linux stopped before handing over to the script, for some other
        /// reason - most often a root filesystem too damaged to mount.
        case bootFailed
        /// Neither a result nor a recognisable failure before the timeout.
        case noResult
    }

    public let outcome: Outcome
    /// The console between BEGIN and DONE - e2fsck's own report.
    public let log: String

    public static let beginMarker = "MSL-MAINTENANCE-BEGIN"
    public static let doneMarker = "MSL-MAINTENANCE-DONE"

    /// Console text meaning the script itself couldn't be run as init.
    ///
    /// The first is what an image without the script really produces -
    /// Alpine's initramfs checks `init=` before switching root and prints it.
    /// It was missing from the first version of this list, which would have
    /// let a maintenance boot on today's images wait out its entire timeout.
    public static let toolsMissingMarkers = [
        "not found in new root",
        "No working init found",
        "Failed to execute",
        "can't execute",
    ]

    /// Console text meaning the boot stopped before the script could run,
    /// for a reason other than the script being missing.
    ///
    /// The recovery shell is the one that matters: without `panic=` it waits
    /// on the console forever. `panic=` is set as well (see
    /// `MaintenanceBootAction.kernelCommandLine`), so either defence alone
    /// is enough.
    public static let bootFailedMarkers = [
        "Launching initramfs emergency recovery shell",
        "Attempted to kill init",
        "Kernel panic",
    ]

    /// Everything worth waiting for: a result, or proof there won't be one.
    public static var terminalMarkers: [String] { [doneMarker] + toolsMissingMarkers + bootFailedMarkers }

    public static func parse(transcript: String, action: MaintenanceBootAction) -> MaintenanceBootReport {
        let lines = transcript.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if let done = lines.lastIndex(where: { $0.contains(doneMarker) }) {
            let tail = lines[done].components(separatedBy: doneMarker).last ?? ""
            let code = Int32(tail.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? -1
            let begin = lines[..<done].lastIndex(where: { $0.contains(beginMarker) })
            let body = begin.map { lines[($0 + 1)..<done] } ?? lines[..<done]
            return MaintenanceBootReport(
                outcome: .finished(.from(exitCode: code, mode: action.mode)),
                log: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Failures keep the end of the console, which is the only record of
        // why the boot stopped. Checked in this order because a panic that
        // follows a missing init mentions both, and "the tools are missing"
        // is the more useful thing to tell someone.
        let tail = lines.suffix(40).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        func sawAny(_ markers: [String]) -> Bool {
            lines.contains { line in markers.contains { line.contains($0) } }
        }
        if sawAny(toolsMissingMarkers) { return MaintenanceBootReport(outcome: .toolsMissing, log: tail) }
        if sawAny(bootFailedMarkers) { return MaintenanceBootReport(outcome: .bootFailed, log: tail) }
        return MaintenanceBootReport(outcome: .noResult, log: tail)
    }
}
