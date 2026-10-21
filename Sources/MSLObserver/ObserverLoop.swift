// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Darwin
import Foundation

/// The observer, as a loop: look, write down, decide, go back to sleep.
///
/// A plain `while true` with a `sleep` in it, on purpose. No run loop, no
/// timers, no notifications, no concurrency - the one thing this process has
/// to be is boring, and every mechanism that could make it cleverer is also a
/// mechanism that could make it stop. If this loop is not running, nothing
/// here is true, so it is kept short enough to read in one sitting.
public final class ObserverLoop {
    /// How often it looks. Deliberately slow: every threshold in
    /// `ObserverThresholds` is minutes, so looking more often buys nothing
    /// and costs somebody's battery.
    public let interval: TimeInterval

    private let session: ObserverSession
    private var judge: ObserverJudge

    /// Which processes MSL is, by the short name the kernel reports. The app
    /// hosts are not in here - they are named after the Linux applications
    /// they run, and are found by listing MSL's own shim directory.
    static let knownNames = ["mslhd", "mslgui", "MSLApp", "MSLFiles", "msl",
                             "msl-usbd", "mslod", "MSL Peripherals"]

    private var knownProcesses: [Int32: String] = [:]
    /// Processes that share a name with one of MSL's app hosts and turned out
    /// not to be one. Remembered so their command line is read once rather
    /// than every tick.
    private var notOurs: Set<Int32> = []
    private var hostNames: Set<String> = []
    private var lastInstanceReply: String?
    private var ticks = 0

    /// Facts that are not worth re-measuring every tick, carried forward
    /// between the ticks that do measure them.
    private var stateWritable = true
    private var registryReadable = true
    /// The newest crash report macOS has written for the background service.
    ///
    /// **Carried forward**, because reports are only scanned every sixth
    /// tick. Held per-tick, it was nil on five raises out of six - so the
    /// exception type, which is the one genuine error code in the whole
    /// business, was missing from most incidents that had one to quote.
    private var newestDaemonReport: String?
    /// Whether MSL's own log said `FATAL:` since the last look - the
    /// reliable half of "MSL has already explained itself", since the window
    /// that shows a crash note deletes it a second after opening.
    private var sawFatal = false
    /// Whether the background service itself wrote anything since the last
    /// look - the difference between busy and wedged.
    private var daemonSpoke = false

    private let bootDate: Date
    /// What the observer's own program looked like when this process
    /// started, so it can tell when it has been replaced.
    private let ownBinaryStamp: Date?

    public init(session: ObserverSession, interval: TimeInterval = 5,
                thresholds: ObserverThresholds = ObserverThresholds()) {
        self.session = session
        self.interval = interval
        self.judge = ObserverJudge(thresholds: thresholds, raised: session.raised)
        self.bootDate = Date(timeIntervalSinceNow: -Self.uptime())
        self.ownBinaryStamp = Self.stamp(of: ObserverAgent.binary)
    }

    static func stamp(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Whether a newer observer has been installed over this one.
    ///
    /// **This is how a new observer actually takes over.** Installing MSL
    /// replaces the program on disk, but launchd goes on running the copy it
    /// already started - and nothing in the install can simply restart the
    /// job, because the binary is written by the app at launch, *after* any
    /// script that might have done it. Measured 2026-10-22: after a full
    /// rebuild and install the running observer was still the previous
    /// build, quietly, with no sign of it anywhere.
    ///
    /// So the one process that can reliably notice is this one. It exits,
    /// and its job brings the new copy up.
    static func replaced(since stamp: Date?, binary: URL = ObserverAgent.binary) -> Bool {
        guard let stamp, let now = Self.stamp(of: binary) else { return false }
        return now != stamp
    }

    /// Seconds since this Mac booted, not counting time asleep.
    ///
    /// `CLOCK_UPTIME_RAW` rather than the wall clock, and recorded alongside
    /// it: the *difference* between how much each advanced across a tick is
    /// how the observer knows it was asleep rather than ignored.
    static func uptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    public func run() -> Never {
        session.write("watching: socket \(ObserverPaths.socket.path), "
                      + "service \(ObserverPaths.daemonBinary.path)")
        while true {
            tick()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// One look at MSL. Everything in here is best-effort; nothing throws.
    public func tick() {
        ticks += 1
        let processes = ObserverProbe.processes()
        recordProcessChanges(processes)

        // Every third tick, so a probe every 15 seconds against thresholds
        // measured in minutes.
        var socket: ObserverProbe.SocketResult?
        if ticks % 3 == 1 {
            let result = ObserverProbe.probeDaemon()
            socket = result
            recordInstanceList(result)
        }

        if ticks % 12 == 1 { stateWritable = ObserverProbe.stateWritable() }
        if ticks % 6 == 1 { registryReadable = ObserverProbe.registryReadable() }
        if ticks % 6 == 1 { recordCrashReports() }

        // MSL's own words, quoted into the record beside what was seen from
        // outside - and read every tick, by offset, so a `FATAL:` line
        // cannot be missed between scans.
        let mirrored = mirrorMSLsOwnLogs()
        sawFatal = sawFatal || mirrored.fatal
        daemonSpoke = daemonSpoke || mirrored.daemonSpoke

        var facts = ObserverFacts(
            wall: Date(), uptime: Self.uptime(),
            daemonPID: ObserverProbe.pid(named: ObserverPaths.daemonProcessName, in: processes),
            daemonBinaryUsable: ObserverProbe.daemonBinaryUsable(),
            optedOut: Self.optedOut(),
            socketConnected: socket?.connected,
            socketAnswered: socket.map { $0.answered ?? false },
            stateWritable: stateWritable,
            registryReadable: registryReadable,
            crashNoteAge: ObserverProbe.crashNoteAge(),
            newestCrashReport: newestDaemonReport,
            mslSaidFatal: sawFatal,
            observerInstalled: FileManager.default
                .isExecutableFile(atPath: ObserverAgent.binary.path),
            daemonSpoke: daemonSpoke)
        // A note the observer itself wrote is not MSL explaining itself, so
        // it must not silence the observer - it would latch itself quiet for
        // two minutes after every incident it raised.
        if isOwnCrashNote() { facts.crashNoteAge = nil }

        if Self.replaced(since: ownBinaryStamp) {
            session.write("a newer observer has been installed - handing over to it")
            session.saveState(force: true)
            // Cleanly: its job has `KeepAlive true`, so any exit brings the
            // new copy up. The record and the latch are keyed on this boot,
            // not on this process, so nothing is lost in the handover.
            exit(0)
        }

        let judgement = judge.judge(facts)
        sawFatal = false
        daemonSpoke = false
        for note in judgement.notes { session.write(note) }
        if let raise = judgement.raise {
            session.write("STOP \(raise.code.printed) \(raise.code.name): \(raise.detail)")
            session.remember(raised: judge.raised)
            let shown = ObserverAlarm.raise(raise.code, detail: raise.detail, session: session)
            session.write("told the person: \(shown)")
        }
        session.saveState()
    }

    // MARK: - What it writes down

    /// MSL's processes starting and stopping - which is most of "everything
    /// MSL does", seen from outside rather than taken from MSL's own word
    /// for it.
    private func recordProcessChanges(_ processes: [ObserverProbe.Process]) {
        // Refreshed occasionally rather than every tick: a Linux app's first
        // launch creates its shim, so the set does change, but not fast.
        if ticks % 12 == 1 || hostNames.isEmpty { hostNames = ObserverProbe.appHostNames() }

        var current: [Int32: String] = [:]
        var newcomers: [(pid: Int32, name: String, line: String?)] = []
        for process in processes where !process.isZombie {
            let named = Self.knownNames.contains {
                $0.prefix(ObserverProbe.commLimit) == process.name
            }
            let looksLikeHost = !named && hostNames.contains(process.name)
            guard named || looksLikeHost else { continue }
            guard !notOurs.contains(process.pid) else { continue }
            if knownProcesses[process.pid] == nil {
                // The command line, once, when a process is first seen - and
                // only for one that already looks like MSL's.
                let line = ObserverProbe.commandLine(pid: process.pid)
                // A name is not proof for an app host: somebody else's
                // `Python3` is not MSL's. The shim path in its arguments is.
                if looksLikeHost, !(line.map(ObserverProbe.isAppHost) ?? false) {
                    notOurs.insert(process.pid)
                    continue
                }
                newcomers.append((process.pid, process.name, line))
            }
            current[process.pid] = process.name
        }
        for newcomer in newcomers {
            let instance = newcomer.line.flatMap(ObserverProbe.instance(inCommandLine:))
            session.write("started: \(newcomer.name) (pid \(newcomer.pid))"
                          + (instance.map { " for '\($0)'" } ?? ""))
        }
        for (pid, name) in knownProcesses where current[pid] == nil {
            session.write("ended: \(name) (pid \(pid))")
        }
        knownProcesses = current
        // Pids are reused, so a rejection cannot be remembered forever.
        let live = Set(processes.map(\.pid))
        notOurs.formIntersection(live)
    }

    /// The instance list, whenever it changes. This is how an instance
    /// starting, hibernating or disappearing gets into the record without the
    /// observer having to be told.
    private func recordInstanceList(_ result: ObserverProbe.SocketResult) {
        guard result.answered == true, let reply = result.reply else { return }
        guard reply != lastInstanceReply else { return }
        lastInstanceReply = reply
        session.write("instances: \(reply.hasPrefix("OK ") ? String(reply.dropFirst(3)) : reply)")
    }

    /// New crash reports from macOS, each recorded once.
    ///
    /// Every MSL process is recorded; only the **background service's** is
    /// kept as evidence. A Linux app host crashing says nothing about why
    /// mslhd will not stay up, and quoting it under a code about mslhd would
    /// be worse than quoting nothing at all.
    private func recordCrashReports() {
        let watched = Set(Self.knownNames).union(hostNames)
        let reports = ObserverProbe.crashReports(since: bootDate, processes: watched)
        for report in reports where session.noticing(report: report.name) {
            let summary = report.summary.isEmpty ? "macOS wrote a crash report" : report.summary
            session.write("macOS crash report for \(report.process): \(summary) [\(report.name)]")
        }
        newestDaemonReport = Self.evidence(from: reports,
                                           daemon: ObserverPaths.daemonProcessName,
                                           carrying: newestDaemonReport)
    }

    /// Which crash report an incident should quote, given what this scan
    /// found and what the last one did.
    ///
    /// Pure, and separate from the scan, because both halves of it were
    /// wrong when they were inline. **Carried forward**: reports are scanned
    /// every sixth look, so evidence held per-look was absent from five
    /// raises in six. **The service's own**: a Linux app host crashing says
    /// nothing about why mslhd will not stay up, and quoting it under a code
    /// about mslhd is worse than quoting nothing.
    static func evidence(from reports: [ObserverProbe.CrashReport],
                         daemon: String, carrying previous: String?) -> String? {
        guard let newest = reports.last(where: { $0.process == daemon }) else { return previous }
        let summary = newest.summary.isEmpty ? "macOS wrote a crash report" : newest.summary
        return "\(newest.process): \(summary)"
    }

    /// Quotes MSL's own new log lines into the record, and answers whether
    /// any of them was MSL announcing it was about to stop.
    ///
    /// `MSLLog.line` writes `FATAL: ...` immediately before every
    /// `CrashScreen.stop`, so this is how the observer knows MSL has
    /// explained itself - a fact it cannot get from the crash note, because
    /// the window that shows one deletes it within a second or two.
    private func mirrorMSLsOwnLogs() -> (fatal: Bool, daemonSpoke: Bool) {
        var fatal = false
        var spoke = false
        // **The same line lands in both files.** `MSLLog` writes every line
        // to `msl.log` *and* to stderr, and the service's LaunchAgent points
        // its stderr at `mslhd.log` - so mirroring both faithfully doubles
        // every line the service writes, which is most of them. The record
        // is for reading; it carries each line once, labelled with the first
        // file it was found in.
        var alreadyQuoted: Set<String> = []
        for url in ObserverPaths.mirroredLogs {
            let source = url.deletingPathExtension().lastPathComponent
            let (lines, offset) = ObserverProbe.newLines(in: url,
                                                         from: session.offset(for: url.path))
            session.setOffset(offset, for: url.path)
            for line in lines {
                if line.contains("FATAL:") { fatal = true }
                if Self.wasWritten(by: ObserverPaths.daemonProcessName, line) { spoke = true }
                guard alreadyQuoted.insert(line).inserted else { continue }
                session.quote(source, line)
            }
        }
        return (fatal, spoke)
    }

    /// Whether one mirrored log line came from a given MSL process.
    ///
    /// Every MSL process writes to the same file - the per-application hosts
    /// most of all - so "MSL said something" is far too weak to mean "the
    /// service is alive". `MSLLog` stamps each line
    /// `MM-DD HH:MM:SS <process> <subsystem>: ...`, and the process field is
    /// the part that answers the question actually being asked.
    static func wasWritten(by process: String, _ line: String) -> Bool {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return false }
        return fields[2] == process
    }

    // MARK: - Reading MSL's own settings, without MSL

    /// Whether the person turned off "start MSL's service automatically".
    ///
    /// Read out of the app's own preferences file rather than through
    /// `UserDefaults`: this process is not MSL.app and does not share its
    /// domain, and a watchdog is not a reason to add a second place that
    /// setting is stored.
    static func optedOut() -> Bool {
        let plist = URL(fileURLWithPath: NSHomeDirectory()
                        + "/Library/Preferences/com.msl.app.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return false }
        return values["MSLLaunchAgentOptOut"] as? Bool ?? false
    }

    /// Whether the crash note on disk is the observer's own. Written by MSL
    /// itself it means "leave this one alone"; written here it means nothing
    /// new at all.
    private func isOwnCrashNote() -> Bool {
        guard let text = try? String(contentsOf: ObserverPaths.crashNote, encoding: .utf8)
        else { return false }
        return text.hasPrefix(ObserverAlarm.component + "\t")
    }
}
