// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Darwin
import Foundation

/// How the observer finds things out, from outside, without asking MSL
/// anything it has to be trusted about.
///
/// Three rules hold everywhere in here:
///
/// - **`sysctl` and sockets only, per tick.** Never a `Process`. A watchdog
///   that forks `launchctl` every two seconds is a worse citizen than the
///   thing it is watching, and on a busy Mac it is the one that gets blamed.
/// - **Nobody else's business.** Command lines are read only for processes
///   that are already known to be MSL's - never for every process on the Mac
///   just to see what it is. The set of app hosts is found by listing MSL's
///   own shim directory, not by inspecting strangers.
/// - **A refusal is an answer.** Every function here returns what it saw,
///   including "could not tell", and nothing throws. The judge decides what
///   a run of "could not tell" means.
public enum ObserverProbe {

    // MARK: - Processes

    public struct Process: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let name: String
        /// A process that has exited and not yet been reaped. **Not
        /// running**, however much it still looks like a process - MSL's app
        /// hosts leave zombies behind when their parent is busy, and
        /// counting one as alive means a host that never stops.
        public let isZombie: Bool
    }

    /// Every process belonging to this user, with its pid, parent and short
    /// name. One `sysctl`, no forks.
    ///
    /// `p_comm` is capped by the kernel at 16 characters, which is why every
    /// comparison against it is done on a truncated copy of the name being
    /// looked for rather than the name itself.
    public static func processes() -> [Process] {
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading, so ask for room and
        // trust the second call's `size`, not the first's.
        size += 16 * MemoryLayout<kinfo_proc>.stride
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map { entry in
            var process = entry
            let comm = withUnsafeBytes(of: &process.kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            return Process(pid: process.kp_proc.p_pid, ppid: process.kp_eproc.e_ppid,
                           name: comm, isZombie: process.kp_proc.p_stat == SZOMB)
        }
    }

    /// The kernel's cap on `p_comm`, which every name has to be compared
    /// against in truncated form.
    ///
    /// 16, from `MAXCOMLEN` in `<sys/param.h>`, and measured rather than
    /// taken on trust: the longest name any process on this Mac reports is
    /// "Microsoft Edge H". (Linux's `/proc/<pid>/comm` is 15, which is a
    /// different number for a different thing - see the Qt wedge list, which
    /// is keyed on that one.)
    public static let commLimit = 16

    public static func pid(named wanted: String, in processes: [Process]) -> Int32? {
        let short = String(wanted.prefix(commLimit))
        return processes.first { $0.name == short && !$0.isZombie }?.pid
    }

    /// Whether a process really is one of MSL's per-application hosts, or
    /// merely shares a name with one.
    ///
    /// Every host is a copy of `mslgui` under
    /// `~/Library/Caches/MSL/AppShims/<application>`, so the directory gives
    /// the observer a set of *names* to look for - but a name is not proof.
    /// A Mac-side `Python3` is not MSL's `Python3`, and recording it as one
    /// would put somebody else's processes in MSL's record. The path in its
    /// arguments is the proof.
    public static func isAppHost(_ line: String) -> Bool {
        line.contains("/Library/Caches/MSL/AppShims/")
    }

    /// A process's arguments, space-separated, or nil if it has gone.
    ///
    /// Only ever called for a process already identified as MSL's - see the
    /// rule about other people's business at the top of this file.
    public static func commandLine(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        guard bytes.count > 4 else { return nil }
        return String(decoding: bytes[4...], as: UTF8.self).replacingOccurrences(of: "\0", with: " ")
    }

    /// The instance in an `mslgui` host's arguments, which is the only thing
    /// that tells two instances' app hosts apart - every host is a copy of
    /// the same binary in the same directory. (The same reading that
    /// `AppSessionRestore` needs for exactly that reason.)
    public static func instance(inCommandLine line: String) -> String? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let flag = tokens.firstIndex(of: "--instance"), flag + 1 < tokens.count else { return nil }
        return tokens[flag + 1]
    }

    /// The names MSL's per-app host processes are running under right now,
    /// read from MSL's own shim directory rather than guessed.
    ///
    /// Each Linux application gets its own copy of `mslgui`, named after the
    /// application, so that macOS gives it its own Dock tile - which means a
    /// host's process name is "Krita" or "chromium", and there is no pattern
    /// to match. Listing the directory is how the observer knows which
    /// process names are MSL's without looking at anything that is not.
    public static func appHostNames() -> Set<String> {
        let shims = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/MSL/AppShims")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: shims.path)) ?? []
        return Set(names.map { String($0.prefix(commLimit)) })
    }

    // MARK: - The daemon's socket

    public struct SocketResult: Equatable, Sendable {
        public let connected: Bool
        /// nil when the connection never happened, so there was nothing to
        /// answer; otherwise whether a reply arrived in time.
        public let answered: Bool?
        public let reply: String?
    }

    /// Asks `mslhd` the one question that costs it nothing and proves it is
    /// alive: `INSTANCES`.
    ///
    /// Chosen rather than written for the purpose, and checked three ways in
    /// `DaemonServer` before being relied on:
    ///
    /// - it reads the registry and `peekManager`, so it **never registers or
    ///   starts** an instance;
    /// - it is excluded from `monitorSummary`, so the observer's probe does
    ///   not scroll MSL's own activity monitor past everything real;
    /// - `startsInstance` is nil for it, so it is **not activity** - a probe
    ///   that counted would stop every instance ever going idle, which is a
    ///   watchdog quietly changing the behaviour of the thing it watches.
    ///
    /// And it is answered, which a `connect` is not: a Unix socket's listen
    /// backlog is serviced by the kernel, so connecting succeeds against a
    /// daemon whose accept loop has wedged. That difference is code 0x21.
    public static func probeDaemon(timeout: TimeInterval = 10) -> SocketResult {
        let path = ObserverPaths.socket.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return SocketResult(connected: false, answered: nil, reply: nil) }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { characters in
                path.withCString { strncpy(characters, $0, 103) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
        guard connected else { return SocketResult(connected: false, answered: nil, reply: nil) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = Data("INSTANCES\n".utf8)
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else {
            return SocketResult(connected: true, answered: false, reply: nil)
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = Darwin.read(fd, &buffer, buffer.count)
        guard read > 0 else { return SocketResult(connected: true, answered: false, reply: nil) }
        let reply = String(decoding: buffer[0..<read], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "OK ..." or "ERROR ..." - either is an answer. A daemon that says
        // no is working; one that says nothing is not.
        return SocketResult(connected: true,
                            answered: reply.hasPrefix("OK ") || reply.hasPrefix("ERROR "),
                            reply: reply)
    }

    // MARK: - MSL's own state, as files

    public static func daemonBinaryUsable() -> Bool {
        FileManager.default.isExecutableFile(atPath: ObserverPaths.daemonBinary.path)
    }

    /// Whether MSL's folder can actually be written, tested by writing - the
    /// POSIX bits lie on a volume mounted read-only, and `isWritableFile`
    /// trusts them.
    public static func stateWritable() -> Bool {
        let probe = ObserverPaths.appSupport.appendingPathComponent(".observer-write-probe")
        guard FileManager.default.fileExists(atPath: ObserverPaths.appSupport.path) else { return false }
        guard (try? Data().write(to: probe, options: .atomic)) != nil else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Whether the file listing the instances can be read and parsed. A
    /// missing file is fine - that is a Mac with no instances yet - but one
    /// that exists and cannot be read is instances apparently vanishing.
    public static func registryReadable() -> Bool {
        let registry = ObserverPaths.appSupport.appendingPathComponent("instances.json")
        guard FileManager.default.fileExists(atPath: registry.path) else { return true }
        guard let data = try? Data(contentsOf: registry) else { return false }
        if data.isEmpty { return true }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// How long ago MSL wrote its own crash note, if it has one.
    public static func crashNoteAge() -> TimeInterval? {
        guard let modified = (try? FileManager.default
            .attributesOfItem(atPath: ObserverPaths.crashNote.path))?[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    // MARK: - What macOS says

    public struct CrashReport: Equatable, Sendable {
        public let name: String
        public let process: String
        public let summary: String
        public let modified: Date
    }

    /// macOS's own crash reports for MSL's processes, newest last.
    ///
    /// **This is where the real error codes are.** Everything else in MSL's
    /// stop codes is MSL naming its own condition; an `.ips` carries the
    /// exception type and signal the kernel actually delivered
    /// (`EXC_BAD_ACCESS (SIGSEGV)` and a `KERN_` reason), and that is what
    /// makes a crash fixable. An incident raised about a crashing daemon
    /// quotes it.
    ///
    /// Parsed defensively: an `.ips` is a JSON header line followed by a JSON
    /// body, and Apple has changed both. Anything unrecognised yields a
    /// report with an empty summary rather than nothing at all, because
    /// "mslhd crashed and the observer could not read why" is still worth
    /// recording.
    public static func crashReports(since: Date, processes: Set<String>) -> [CrashReport] {
        let directory = ObserverPaths.diagnosticReports
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var found: [CrashReport] = []
        for name in names where name.hasSuffix(".ips") {
            // `mslhd-2026-10-22-141208.ips`, or the app's own name. Matched
            // on the part before the first dash so a Linux app's host - named
            // after the app - is not mistaken for MSL's.
            let leading = name.split(separator: "-").first.map(String.init) ?? name
            guard processes.contains(leading) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? FileManager.default
                .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified > since else { continue }
            found.append(CrashReport(name: name, process: leading,
                                      summary: summary(ofReportAt: url), modified: modified))
        }
        return found.sorted { $0.modified < $1.modified }
    }

    static func summary(ofReportAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 96 * 1024) else { return "" }
        try? handle.close()
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2,
              let body = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        else { return "" }
        var parts: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String
            let signal = exception["signal"] as? String
            let subtype = exception["subtype"] as? String
            parts.append([type, signal.map { "(\($0))" }, subtype]
                .compactMap { $0 }.joined(separator: " "))
        }
        if let termination = body["termination"] as? [String: Any],
           let indicator = termination["indicator"] as? String {
            parts.append(indicator)
        }
        // An uncaught Swift or Objective-C error says more than the signal
        // it turned into.
        if let last = body["asi"] as? [String: [String]],
           let reason = last.values.first?.first {
            parts.append(reason)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " - ")
    }

    // MARK: - Quoting MSL's own logs

    /// New lines appended to one of MSL's logs since the observer last
    /// looked, with the offset to remember next time.
    ///
    /// **A shrinking file means it was truncated, not that time went
    /// backwards.** The MSL panel's "Clear" truncates these logs in place -
    /// it has to, because unlinking a file the daemon holds open would send
    /// its output to an inode with no name - so a remembered offset past the
    /// new end has to go back to the start rather than read rubbish.
    ///
    /// Guest kernel console output is the bulk of `mslhd.log` and carries its
    /// own `[ 0.1234]` stamps; it is skipped. What is kept is MSL's own
    /// stamped lines - which is what "everything MSL does" means here.
    public static func newLines(in url: URL, from offset: UInt64?,
                                limit: Int = 64 * 1024) -> (lines: [String], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset ?? 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset ?? size   // first sight of a file starts at its end
        if start > size { start = 0 }
        guard start < size else { return ([], size) }
        // Only the newest `limit` bytes of a big catch-up, so an observer
        // that has been away does not read a megabyte in one tick.
        if size - start > UInt64(limit) { start = size - UInt64(limit) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return ([], size)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(isMSLOwnLine)
        return (lines, size)
    }

    /// Whether a log line is MSL talking, rather than a guest's kernel.
    static func isMSLOwnLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // `[    0.123456] ...` - the guest kernel's own stamp.
        if trimmed.hasPrefix("[") { return false }
        // `MM-DD HH:MM:SS name subsystem: ...` - MSLLog's shape.
        let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if fields.count == 3, fields[0].count == 5, fields[1].count == 8,
           fields[0].contains("-"), fields[1].contains(":") {
            return true
        }
        // Anything that named itself a failure is worth keeping whatever
        // shape it is in.
        let lowered = trimmed.lowercased()
        return ["fatal", "error", "panic", "refused", "failed"].contains { lowered.contains($0) }
    }
}
