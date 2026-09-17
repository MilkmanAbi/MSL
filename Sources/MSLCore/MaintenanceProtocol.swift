import Foundation

/// The one daemon command that carries every maintenance action.
///
/// A closed set of words, validated when the request line is parsed. There
/// is no "run this" - the app can only ask for things on this list, and the
/// guest only ever receives commands `GuestUtility` generated itself.
public enum MaintenanceCommand: String, CaseIterable, Sendable {
    case status
    case fsckCheck = "fsck-check"
    case fsckRepair = "fsck-repair"
    case backupDiscard = "backup-discard"
    case backupRestore = "backup-restore"
    case checkAtStartOn = "check-at-start-on"
    case checkAtStartOff = "check-at-start-off"
    case bootFsckCheck = "boot-fsck-check"
    case bootFsckRepair = "boot-fsck-repair"
    case utilClock = "util-clock"
    case utilFixPackages = "util-fix-packages"
    case utilFreeSpace = "util-free-space"
    case utilDiskErrors = "util-disk-errors"

    public var fsckMode: FsckMode? {
        switch self {
        case .fsckCheck: return .check
        case .fsckRepair: return .repair
        default: return nil
        }
    }

    public var bootAction: MaintenanceBootAction? {
        switch self {
        case .bootFsckCheck: return .fsckCheck
        case .bootFsckRepair: return .fsckRepair
        default: return nil
        }
    }

    public var utility: GuestUtility? {
        switch self {
        case .utilClock: return .clockSync
        case .utilFixPackages: return .fixPackages
        case .utilFreeSpace: return .freeSpace
        case .utilDiskErrors: return .diskErrors
        default: return nil
        }
    }

    public static func command(for utility: GuestUtility) -> MaintenanceCommand {
        switch utility {
        case .clockSync: return .utilClock
        case .fixPackages: return .utilFixPackages
        case .freeSpace: return .utilFreeSpace
        case .diskErrors: return .utilDiskErrors
        }
    }

    /// Reads or writes the disk image from the Mac's side. Needs the
    /// instance off, and no *other* instance on the same disk running.
    public var touchesDisk: Bool {
        switch self {
        case .fsckCheck, .fsckRepair, .bootFsckCheck, .bootFsckRepair, .backupRestore, .backupDiscard:
            return true
        default:
            return false
        }
    }

    /// Runs a VM, so it counts against the concurrency cap as well.
    public var bootsVirtualMachine: Bool { bootAction != nil }

    /// How long the app waits for an answer. Longer than the work itself can
    /// take, so the daemon's own timeout is always the one that decides.
    public var clientTimeout: TimeInterval {
        if bootAction != nil { return 2000 }                 // boot + a full e2fsck
        if fsckMode != nil { return 1800 }                   // a large disk takes a while
        if let utility { return utility.timeout + 60 }
        return 30
    }
}

// MARK: - Status

/// What the Maintenance card needs to decide which buttons make sense.
public struct MaintenanceStatus: Equatable, Sendable {
    public var e2fsckAvailable: Bool
    public var running: Bool
    public var inProgress: Bool
    public var hasSavedSession: Bool
    public var hasRepairBackup: Bool
    public var checkAtStart: Bool
    /// Whether the image contains the guest maintenance script. `nil` when
    /// the Mac can't look inside it - no e2fsprogs, or the disk is in use.
    public var scriptInImage: Bool?

    public init(e2fsckAvailable: Bool, running: Bool, inProgress: Bool, hasSavedSession: Bool,
                hasRepairBackup: Bool, checkAtStart: Bool, scriptInImage: Bool?) {
        self.e2fsckAvailable = e2fsckAvailable
        self.running = running
        self.inProgress = inProgress
        self.hasSavedSession = hasSavedSession
        self.hasRepairBackup = hasRepairBackup
        self.checkAtStart = checkAtStart
        self.scriptInImage = scriptInImage
    }

    public var wireLine: String {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        let script = scriptInImage.map { $0 ? "1" : "0" } ?? "unknown"
        return "e2fsck=\(flag(e2fsckAvailable)) running=\(flag(running)) busy=\(flag(inProgress)) "
             + "saved=\(flag(hasSavedSession)) backup=\(flag(hasRepairBackup)) "
             + "checkatstart=\(flag(checkAtStart)) script=\(script)"
    }

    /// `nil` for a line that isn't a status at all, so a reply from some
    /// other command can't be mistaken for "everything false".
    public static func fromWireLine(_ line: String) -> MaintenanceStatus? {
        var fields: [String: String] = [:]
        for word in line.split(separator: " ") {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard fields["e2fsck"] != nil, fields["running"] != nil else { return nil }
        func flag(_ key: String) -> Bool { fields[key] == "1" }
        let script: Bool? = {
            switch fields["script"] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }()
        return MaintenanceStatus(
            e2fsckAvailable: flag("e2fsck"), running: flag("running"), inProgress: flag("busy"),
            hasSavedSession: flag("saved"), hasRepairBackup: flag("backup"),
            checkAtStart: flag("checkatstart"), scriptInImage: script)
    }
}

// MARK: - Outcome

/// The one shape every maintenance action answers with: a tone, a sentence,
/// and the tool's own output for anyone who wants it.
///
/// Free text is base64'd on the wire. The daemon protocol is one line of
/// `key=value` words, and e2fsck's report is many lines of arbitrary text -
/// escaping that by hand is where the bugs would live, and base64 has no
/// spaces, newlines or `=` in the middle to collide with.
public struct MaintenanceOutcome: Equatable, Sendable {
    public enum Tone: String, Sendable {
        /// Healthy, or done.
        case good
        /// Something wants the user's attention, but nothing is broken yet.
        case attention
        /// It didn't work, or the disk is in a bad way.
        case bad
        /// Not applicable here - for example, an image too old for the tools.
        case info
    }

    public var tone: Tone
    public var title: String
    public var detail: String
    public var log: String

    public init(tone: Tone, title: String, detail: String, log: String = "") {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.log = log
    }

    public static func failure(_ message: String) -> MaintenanceOutcome {
        MaintenanceOutcome(tone: .bad, title: "Couldn't do that", detail: message)
    }

    static func tone(for verdict: FsckVerdict) -> Tone {
        switch verdict.outcome {
        case .clean, .repaired, .repairedNeedsRestart: return .good
        case .problemsRemain: return verdict.mode == .check ? .attention : .bad
        case .didNotRun: return .bad
        }
    }

    public init(fsck run: FsckRun) {
        self.init(tone: Self.tone(for: run.verdict), title: run.verdict.title,
                  detail: run.verdict.detail, log: run.output)
    }

    public init(report: MaintenanceBootReport) {
        switch report.outcome {
        case .finished(let verdict):
            self.init(tone: Self.tone(for: verdict), title: verdict.title,
                      detail: verdict.detail + " (Checked from inside Linux, during a maintenance boot.)",
                      log: report.log)
        case .toolsMissing:
            self.init(tone: .info, title: "Needs a rebuilt image",
                      detail: "This instance's image doesn't include MSL's maintenance tools yet, so the maintenance boot couldn't run. It has been shut down again; nothing was changed.",
                      log: report.log)
        case .bootFailed:
            self.init(tone: .bad, title: "Maintenance boot couldn't start",
                      detail: "Linux stopped before the maintenance tools could run — often because the disk is too damaged to mount. It has been shut down again. If e2fsprogs is installed on your Mac, Check Disk examines the disk without booting it.",
                      log: report.log)
        case .noResult:
            self.init(tone: .bad, title: "No result from the maintenance boot",
                      detail: "It didn't report back before the time limit and has been stopped. If this was a repair, run a check before relying on the disk.",
                      log: report.log)
        }
    }

    public init(utility: GuestUtility, result: GuestUtilityResult) {
        let tone: Tone
        switch result.status {
        case .ok: tone = .good
        case .fail: tone = .attention
        case .skip, .toolsMissing: tone = .info
        }
        let title = result.status == .toolsMissing ? "Needs a rebuilt image" : utility.title
        self.init(tone: tone, title: title, detail: result.summary, log: result.output)
    }

    public var wireLine: String {
        func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        return "tone=\(tone.rawValue) title=\(encode(title)) detail=\(encode(detail)) log=\(encode(log))"
    }

    public static func fromWireLine(_ line: String) -> MaintenanceOutcome? {
        var fields: [String: String] = [:]
        for word in line.split(separator: " ") {
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let toneWord = fields["tone"], let tone = Tone(rawValue: toneWord) else { return nil }
        func decode(_ key: String) -> String? {
            guard let value = fields[key] else { return nil }
            if value.isEmpty { return "" }
            return Data(base64Encoded: value).map { String(decoding: $0, as: UTF8.self) }
        }
        guard let title = decode("title"), let detail = decode("detail") else { return nil }
        return MaintenanceOutcome(tone: tone, title: title, detail: detail, log: decode("log") ?? "")
    }
}
