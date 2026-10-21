// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Darwin
import Foundation

/// The observer's record, and the one rule about how long it lives: **this
/// boot's only.**
///
/// The log is deleted and begun again when the Mac has booted since it was
/// written, and never otherwise. Keying it on the *boot* rather than on the
/// observer starting is the whole of the design:
///
/// - the observer's own LaunchAgent brings it back if it dies, and truncating
///   on start would mean a watchdog that destroys its evidence the one time
///   it fell over;
/// - every reinstall, and every `launchctl kickstart`, restarts it;
/// - what a person means by "this MSL session" is this time they turned the
///   Mac on, not an implementation detail of a daemon they never see.
///
/// So: one file per boot, no rotation, no archive, nothing to clean up by
/// hand. What survives a boot is the *incident report*, which is evidence
/// behind a screen that may not have been read yet - not a log.
public final class ObserverSession {
    /// `kern.boottime`, in whole seconds. The session's identity.
    public static func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var name = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, UInt32(name.count), &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }

    /// What has to outlive the observer process but not the boot.
    struct State: Codable {
        var bootTime: Int
        /// Stop codes already shown, so a restarted observer does not put the
        /// same screen up twice.
        var raised: [UInt32] = []
        /// How far the observer has read each of MSL's own logs, by path.
        var offsets: [String: UInt64] = [:]
        /// The newest crash report already recorded, so each is noted once.
        var seenReports: [String] = []
    }

    /// Lines kept in memory for an incident report. The log on disk can be
    /// large and the interesting part is always the end of it, so the report
    /// carries the tail rather than a pointer to a file somebody then has to
    /// find.
    private var ring: [String] = []
    private let ringLimit = 300

    /// A log that grows without limit is a bug of its own on a Mac left on
    /// for weeks. At the cap the oldest half goes and the file says so.
    private let sizeCap: UInt64 = 8 * 1024 * 1024

    private var state: State
    private var handle: FileHandle?
    private var stateDirty = false
    private var stateWrittenAt: Date = .distantPast

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    public init() {
        let boot = Self.bootTime()
        let fresh = !Self.logBelongs(toBoot: boot)
        if fresh { Self.clearStaleLogs() }
        state = (fresh ? nil : Self.loadState()).map {
            // Belt and braces: a state file from another boot is no more use
            // than a log from one.
            $0.bootTime == boot ? $0 : State(bootTime: boot)
        } ?? State(bootTime: boot)
        try? FileManager.default.createDirectory(at: ObserverPaths.logs,
                                                 withIntermediateDirectories: true)
        // O_APPEND for the same reason `MSLLog` uses it: the kernel seeks to
        // the end as part of every write, so anything that truncates the file
        // underneath simply becomes the new end, rather than leaving the next
        // write at a remembered offset with a megabyte of NULs before it.
        let fd = open(ObserverPaths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false) }
        if fresh {
            // The header is written **unstamped**, as the file's first line,
            // because it is what `logBelongs(toBoot:)` reads to decide
            // whether this log is this boot's. Stamping it like a log line
            // put the date in front of `#session` and the check never
            // matched - so every start looked like a new boot and wiped the
            // record it was meant to continue.
            writeRaw("#session boot=\(boot) version=\(ObserverVersion.display) "
                     + "started=\(ISO8601DateFormatter().string(from: Date()))\n")
            writeRaw("# MSL's observer. One file per boot of this Mac; "
                     + "the previous one is gone.\n")
            saveState(force: true)
        } else {
            write("the observer restarted - same boot (\(boot)), so this record continues")
        }
    }

    // MARK: - The session's identity on disk

    /// Whether the log on disk was written during this boot. The header is
    /// read rather than the file's dates: a file's timestamps survive being
    /// copied, restored from a backup, or rewritten by something else, and
    /// what matters is which boot wrote the lines inside it.
    static func logBelongs(toBoot boot: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: ObserverPaths.log),
              let head = try? handle.read(upToCount: 512),
              let text = String(data: head, encoding: .utf8) else { return false }
        try? handle.close()
        guard let line = text.split(separator: "\n").first,
              line.hasPrefix("#session ") else { return false }
        for field in line.split(separator: " ") where field.hasPrefix("boot=") {
            return Int(field.dropFirst(5)) == boot
        }
        return false
    }

    /// Everything left behind by a previous boot. The names are deliberately
    /// narrow - `observer.log`, `observer-session.json`, and anything else
    /// called `observer-*.log` - so nothing else in `~/Library/Logs/MSL` is
    /// ever at risk from the observer tidying up after itself. `mslhd.log`
    /// and `msl.log` are MSL's and are not the observer's to delete.
    ///
    /// **`observer-launchd.log` is truncated, never unlinked.** That one is
    /// opened by launchd, not by this process - it is where the observer's
    /// own stderr goes, which is the only place a crash of the watchdog
    /// itself would show up. Deleting a file launchd holds open leaves it
    /// writing to an inode with no name for the rest of the boot, so the one
    /// log that would explain a broken observer would be the one guaranteed
    /// to be lost.
    static func clearStaleLogs() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: ObserverPaths.logs.path)) ?? []
        for name in contents {
            let url = ObserverPaths.logs.appendingPathComponent(name)
            switch disposal(of: name) {
            case .leave: continue
            case .remove: try? fm.removeItem(at: url)
            case .truncate: close(open(url.path, O_WRONLY | O_TRUNC))
            }
        }
    }

    enum Disposal: Equatable { case leave, remove, truncate }

    static func disposal(of name: String) -> Disposal {
        if name == "observer.log" || name == "observer-session.json" { return .remove }
        if name.hasPrefix("observer-"), name.hasSuffix(".log") { return .truncate }
        return .leave
    }

    private static func loadState() -> State? {
        guard let data = try? Data(contentsOf: ObserverPaths.sessionState) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    // MARK: - Writing

    /// Exactly these bytes, no stamp. For the file's header only.
    private func writeRaw(_ text: String) {
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// One line, stamped, in the same shape as MSL's own so the two read
    /// together: `10-22 14:12:08 observer: ...`.
    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) observer: \(message)\n"
        ring.append(line)
        if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
        try? handle?.write(contentsOf: Data(line.utf8))
        capIfNeeded()
    }

    /// A line taken from one of MSL's own logs, marked as quoted rather than
    /// observed. Which side a line came from matters when reading the file
    /// afterwards: the observer's own lines are the independent record, and
    /// these are what MSL said about itself.
    public func quote(_ source: String, _ line: String) {
        let text = "  \(source)| \(line)\n"
        ring.append(text)
        if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
        try? handle?.write(contentsOf: Data(text.utf8))
        capIfNeeded()
    }

    private func capIfNeeded() {
        guard let handle, let size = try? handle.offset(), size > sizeCap else { return }
        // Keep the newest half. Read it, rewrite the file from a header, and
        // say what happened - a log that silently loses its middle is worse
        // than one that admits it.
        guard let existing = try? Data(contentsOf: ObserverPaths.log) else { return }
        let keep = existing.suffix(Int(sizeCap / 2))
        var rebuilt = Data("#session boot=\(state.bootTime) version=\(ObserverVersion.display)\n".utf8)
        let trimmed = "# trimmed at \(ISO8601DateFormatter().string(from: Date())) "
            + "- the first \(existing.count - keep.count) bytes of this boot are gone\n"
        rebuilt += Data(trimmed.utf8)
        rebuilt += keep
        try? rebuilt.write(to: ObserverPaths.log, options: .atomic)
    }

    // MARK: - What the observer remembers

    public var raised: Set<UInt32> { Set(state.raised) }

    public func remember(raised: Set<UInt32>) {
        guard Set(state.raised) != raised else { return }
        state.raised = raised.sorted()
        saveState(force: true)
    }

    public func offset(for path: String) -> UInt64? { state.offsets[path] }

    public func setOffset(_ offset: UInt64, for path: String) {
        state.offsets[path] = offset
        stateDirty = true
    }

    /// Whether a crash report has already been recorded, marking it seen.
    public func noticing(report name: String) -> Bool {
        guard !state.seenReports.contains(name) else { return false }
        state.seenReports.append(name)
        // Bounded: a Mac that crashes a lot must not grow this forever.
        if state.seenReports.count > 200 { state.seenReports.removeFirst(100) }
        stateDirty = true
        return true
    }

    /// Writes the remembered state out, at most every few seconds unless the
    /// caller insists. The latch insists; read offsets do not, because
    /// losing a few seconds of them only means a handful of MSL's own lines
    /// get quoted twice after an observer restart.
    public func saveState(force: Bool = false) {
        guard force || (stateDirty && Date().timeIntervalSince(stateWrittenAt) > 10) else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: ObserverPaths.sessionState, options: .atomic)
        stateDirty = false
        stateWrittenAt = Date()
    }

    // MARK: - Incidents

    /// Writes the report that outlives the log: the code, the detail, the
    /// version, and the tail of everything the observer saw leading up to it.
    ///
    /// This is what the crash screen offers and what somebody pastes into an
    /// issue. It is written **before** the screen is asked for, so that even
    /// if nothing can draw a window the evidence is already on disk.
    public func writeIncident(code: ObserverStopCode, detail: String) {
        // `key: value` lines, then a blank line, then the record. Written to
        // be read **both ways**: the crash screen parses the head of it to
        // fill in a report somebody can act on, and the whole file is plain
        // enough to paste into an issue without explaining what it is.
        let fields: [(String, String)] = [
            ("code", code.printed),
            ("name", code.name),
            ("subsystem", code.subsystem),
            ("reported-by", "mslod - MSL's observer"),
            ("recorded", ISO8601DateFormatter().string(from: Date())),
            ("uptime-at-boot", "\(state.bootTime)"),
            ("version", ObserverVersion.display),
            ("observed", detail),
            ("reference", ObserverWiki.page(for: code)),
        ]
        var report = fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        report += """


        \(code.happened)

        \(code.next)

        --- the last \(ring.count) lines MSL's observer recorded ---

        """
        report += ring.joined()
        try? FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                 withIntermediateDirectories: true)
        try? Data(report.utf8).write(to: ObserverPaths.incident, options: .atomic)
    }
}

/// The observer's own version, kept here rather than imported so this target
/// stays a leaf. `ObserverVersionTests` fails if it drifts from `MSLVersion`.
public enum ObserverVersion {
    public static let marketing = "2.0.0"
    public static var display: String { "MSL-\(marketing)" }
}

/// Where the guide lives, and the page that explains a stop code.
///
/// The crash screen's one piece of advice that always applies is "read this",
/// so the address is a constant rather than a string typed into a view.
///
/// **One folder per chapter**, which is how the site is actually laid out -
/// `MSL-Wiki/error-codes/stop-codes.html`, not a page at the root. Written
/// here from the published site rather than guessed, because a crash screen
/// that sends somebody to a 404 is worse than one that sends them nowhere.
public enum ObserverWiki {
    public static let base = "https://milkmanabi.github.io/MSL-Wiki/"
    /// The full reference: every code, what raised it, what to do, and the
    /// threshold each observer code is detected on.
    public static let stopCodes = base + "error-codes/all-codes.html"
    /// How to read the report panel, and what the observer is - for anybody
    /// who wants to know why a window appeared.
    public static let observer = base + "error-codes/reading-a-report.html"

    public static func page(for code: ObserverStopCode) -> String {
        stopCodes + "#" + code.wikiAnchor
    }
}

/// Reading back an incident report, for the window that has to show it.
///
/// The report is written by a process that is watching MSL and read by a
/// process that MSL just spawned, so it is a file and a format rather than a
/// call - and a format that survives one of them being older than the other.
/// An unknown field is kept; a missing one is simply absent. Nothing here
/// fails: a report that cannot be parsed still shows whatever was in it.
public struct ObserverIncident: Equatable, Sendable {
    public var fields: [String: String] = [:]
    /// Everything after the fields: the prose and the observer's own tail.
    public var body: String = ""

    public var code: String? { fields["code"] }
    public var name: String? { fields["name"] }
    public var subsystem: String? { fields["subsystem"] }
    public var reportedBy: String? { fields["reported-by"] }
    public var observed: String? { fields["observed"] }
    public var reference: String? { fields["reference"] }
    public var version: String? { fields["version"] }

    /// When it was recorded, as a date rather than as the string it was
    /// written in - a crash screen says "at 01:20" in the person's own
    /// formatting, not in ISO 8601.
    public var recorded: Date? {
        fields["recorded"].flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public static func read(at url: URL = ObserverPaths.incident) -> ObserverIncident? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> ObserverIncident? {
        var incident = ObserverIncident()
        var lines = text.components(separatedBy: "\n")
        while let line = lines.first {
            lines.removeFirst()
            // The blank line ends the fields. Everything after it is the
            // report as a person reads it.
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            incident.fields[key] = value
        }
        incident.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return incident.fields.isEmpty && incident.body.isEmpty ? nil : incident
    }
}
