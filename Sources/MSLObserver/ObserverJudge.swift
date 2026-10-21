// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// One tick's worth of what the observer could see from outside MSL.
///
/// Deliberately all facts and no opinions: everything that decides whether a
/// crash screen appears is in `ObserverJudge`, which is pure, so the decision
/// can be tested against a minute of invented history instead of against a
/// Mac somebody has to break first.
public struct ObserverFacts: Equatable, Sendable {
    /// Wall clock, which can jump (sleep, a clock correction, a time zone).
    public var wall: Date
    /// Seconds since this Mac booted, which cannot go backwards. Both are
    /// recorded because the *difference* between them across a tick is how
    /// the observer notices it was not running for a while.
    public var uptime: Double

    /// `mslhd`'s pid, or nil if there is no such process.
    public var daemonPID: Int32?
    /// Whether the installed `mslhd` is on disk and executable.
    public var daemonBinaryUsable: Bool
    /// Whether the person turned off "start MSL's service automatically". If
    /// they did, a daemon that is not running is not a fault.
    public var optedOut: Bool

    /// Whether a `connect` to the control socket succeeded. nil when this
    /// tick did not probe.
    public var socketConnected: Bool?
    /// Whether the daemon **replied** to a real request. nil when this tick
    /// did not probe.
    ///
    /// The distinction is the whole of code 0x21: a Unix socket's listen
    /// backlog accepts connections on the kernel's behalf, so `connect`
    /// succeeds against a daemon whose accept loop is wedged and proves
    /// nothing at all.
    public var socketAnswered: Bool?

    public var stateWritable: Bool
    public var registryReadable: Bool

    /// How long ago MSL itself wrote a crash note, if it has. MSL stopping
    /// *on purpose*, with one of its own codes, is a better explanation than
    /// anything the observer can infer - so when this is recent the observer
    /// stays quiet and lets that screen stand.
    public var crashNoteAge: TimeInterval?

    /// What macOS's newest crash report **for the background service** says,
    /// in one line. This is the only genuine error code in the business - an
    /// exception type and a signal - and it goes into the incident detail.
    ///
    /// The service's own, not any MSL process's: a Linux app host crashing
    /// says nothing about why mslhd will not stay up, and quoting it under a
    /// code about mslhd would be worse than quoting nothing.
    public var newestCrashReport: String?

    /// Whether the background service wrote anything to MSL's log since the
    /// last look.
    ///
    /// **A service that is still talking is busy, not wedged.** Answering
    /// `INSTANCES` reads each instance's state through `vmQueue.sync`, and
    /// that queue is held for as long as it takes to freeze a guest and
    /// write its RAM to disk - so a shutdown that saves four instances can
    /// legitimately leave the socket silent for minutes. The log is the
    /// difference between that and a daemon nobody is going to hear from
    /// again.
    public var daemonSpoke: Bool

    /// Whether MSL said `FATAL:` in its own log since the last look.
    ///
    /// The *reliable* half of "MSL has already explained itself".
    /// `MSLLog.line` writes one of these immediately before every
    /// `CrashScreen.stop`, and the observer reads MSL's log by offset, so it
    /// cannot miss one - unlike the crash note, which the window that shows
    /// it deletes within a second or two of opening.
    public var mslSaidFatal: Bool

    /// Whether the observer's own program is still installed.
    ///
    /// False means **MSL was removed**, not that MSL is broken: this process
    /// goes on running from an unlinked inode after its binary is deleted.
    /// Reporting a failure in that state would be reporting that somebody's
    /// uninstall worked.
    public var observerInstalled: Bool

    public init(wall: Date, uptime: Double, daemonPID: Int32?, daemonBinaryUsable: Bool,
                optedOut: Bool, socketConnected: Bool?, socketAnswered: Bool?,
                stateWritable: Bool, registryReadable: Bool,
                crashNoteAge: TimeInterval? = nil, newestCrashReport: String? = nil,
                mslSaidFatal: Bool = false, observerInstalled: Bool = true,
                daemonSpoke: Bool = false) {
        self.wall = wall
        self.uptime = uptime
        self.daemonPID = daemonPID
        self.daemonBinaryUsable = daemonBinaryUsable
        self.optedOut = optedOut
        self.socketConnected = socketConnected
        self.socketAnswered = socketAnswered
        self.stateWritable = stateWritable
        self.registryReadable = registryReadable
        self.crashNoteAge = crashNoteAge
        self.newestCrashReport = newestCrashReport
        self.mslSaidFatal = mslSaidFatal
        self.observerInstalled = observerInstalled
        self.daemonSpoke = daemonSpoke
    }
}

/// How long something has to be wrong before it counts.
///
/// **Every number here is a false-positive budget, not a reaction time.** A
/// crash screen for a healthy MSL is worse than no observer at all, and the
/// legitimate outages are long: `mslhd`'s LaunchAgent allows it 40 seconds to
/// freeze and write out every guest's RAM on shutdown, the installer boots it
/// out on purpose during an upgrade, and `HostToolInstaller` unlinks its
/// binary before copying the new one in. So the thresholds sit well above all
/// of those, and the observer would rather be a minute late than wrong.
public struct ObserverThresholds: Equatable, Sendable {
    /// Restarts that have to pile up, with nothing served in between.
    public var restartLoopCount = 4
    public var restartLoopWindow: Double = 300
    /// A daemon that connects and never replies, and says nothing in its own
    /// log either. Five minutes rather than three: saving several guests'
    /// memory on a shutdown holds the queue a status question waits on, and
    /// the cost of being late here is a report somebody reads a minute
    /// later, where the cost of being early is a false crash screen.
    public var unansweredLimit: Double = 300
    /// A missing installed binary. Longer than any install takes.
    public var binaryGoneLimit: Double = 180
    public var stateBadLimit: Double = 120
    /// How recent MSL's own crash note has to be for the observer to defer
    /// to it rather than add a second window.
    public var deferToOwnNote: Double = 120
    /// A tick gap bigger than this means the observer was not watching -
    /// asleep, descheduled, or just restarted - so every streak it was
    /// counting is worthless and starts again.
    public var tickGapLimit: Double = 60

    public init() {}
}

/// What one tick came to.
public struct ObserverJudgement: Equatable, Sendable {
    /// Things worth having in the record. Never shown to anybody.
    public var notes: [String] = []
    /// The one thing worth stopping somebody for.
    public var raise: Raise?

    public struct Raise: Equatable, Sendable {
        public let code: ObserverStopCode
        public let detail: String
    }
}

/// Decides, from a sequence of `ObserverFacts`, whether MSL is merely having a
/// bad time or is in a state it cannot get out of.
///
/// Pure and `struct`: no clock, no files, no processes. The loop in `mslod`
/// gathers facts and this decides, which is what makes the decision testable
/// without a broken Mac - and the decision is the part that must not be wrong.
public struct ObserverJudge {
    public var thresholds: ObserverThresholds

    /// Codes already shown this session. A condition is announced once; after
    /// that it is a note. A crash screen that reappears every three minutes
    /// is its own bug, and it buries whatever the person was doing about the
    /// first one.
    public private(set) var raised: Set<UInt32>

    private var lastUptime: Double?
    private var lastWall: Date?
    private var lastDaemonPID: Int32?
    /// Whether the daemon currently running has ever answered. A crash is
    /// forgivable; a crash loop that never serves anything is not, and this
    /// is the difference between the two.
    private var servedCurrentPID = false
    private var restartsWithoutService: [Double] = []
    private var unansweredSince: Double?
    private var binaryGoneSince: Double?
    private var stateBadSince: Double?
    /// When MSL was last seen explaining itself - a crash note on disk, or a
    /// `FATAL:` line in its own log.
    ///
    /// **Remembered, not re-read.** The first version deferred only while the
    /// note was still on disk, and the window that shows it deletes it within
    /// a second or two of opening - so a service stopping itself repeatedly
    /// with its own code was deferred to for exactly one look, and the
    /// observer then counted the restarts and put a second, vaguer window
    /// over the first. Which is the thing this rule exists to prevent.
    private var ownNoteSeenAt: Double?

    public init(thresholds: ObserverThresholds = ObserverThresholds(), raised: Set<UInt32> = []) {
        self.thresholds = thresholds
        self.raised = raised
    }

    /// Everything the judge wants to keep across its own process restarting -
    /// which is only the latch. The streaks are deliberately *not* carried
    /// over: an observer that just started was not watching a moment ago, and
    /// counting a streak through a gap it did not observe is how a watchdog
    /// invents an outage.
    public var latch: [UInt32] { raised.sorted() }

    public mutating func judge(_ facts: ObserverFacts) -> ObserverJudgement {
        var judgement = ObserverJudgement()

        // **Was the observer even watching?** A tick that arrives a long time
        // after the last one means it was asleep with the Mac, descheduled,
        // or has only just started. Whatever was being counted spans time
        // nobody looked at, so it is dropped rather than believed.
        if let lastUptime, let lastWall {
            let ticked = facts.uptime - lastUptime
            let elapsed = facts.wall.timeIntervalSince(lastWall)
            if ticked < 0 || ticked > thresholds.tickGapLimit
                || elapsed - ticked > thresholds.tickGapLimit {
                judgement.notes.append(
                    "a gap in watching (\(Int(ticked))s of uptime, \(Int(elapsed))s of clock) "
                    + "- counting again from here")
                forgetStreaks()
            }
        }
        lastUptime = facts.uptime
        lastWall = facts.wall

        // The service changing identity: gone, back, or replaced.
        if facts.daemonPID != lastDaemonPID {
            switch (lastDaemonPID, facts.daemonPID) {
            case (nil, .some(let now)):
                judgement.notes.append("mslhd is running as pid \(now)")
            case (.some(let was), nil):
                judgement.notes.append("mslhd (pid \(was)) is gone")
            case (.some(let was), .some(let now)):
                judgement.notes.append("mslhd was replaced: pid \(was) -> \(now)")
            case (nil, nil):
                break
            }
            // A *new* daemon, where the last one never answered anything, is
            // one turn of a loop. One turn is launchd doing its job; it only
            // becomes a fault by repeating.
            if lastDaemonPID != nil, facts.daemonPID != nil, !servedCurrentPID {
                restartsWithoutService.append(facts.uptime)
            }
            if facts.daemonPID != nil { servedCurrentPID = false }
            unansweredSince = nil
            lastDaemonPID = facts.daemonPID
        }
        restartsWithoutService.removeAll { facts.uptime - $0 > thresholds.restartLoopWindow }

        // Whether the daemon answered, which is a stronger fact than whether
        // it exists.
        if facts.socketAnswered == true {
            if unansweredSince != nil { judgement.notes.append("mslhd is answering again") }
            unansweredSince = nil
            servedCurrentPID = true
            // It works. Whatever happened before it started working is
            // history, not a pattern.
            restartsWithoutService.removeAll()
        } else if facts.socketAnswered == false, facts.daemonPID != nil {
            if unansweredSince == nil {
                unansweredSince = facts.uptime
                judgement.notes.append("mslhd is not answering"
                    + (facts.socketConnected == true ? " (the socket accepted the connection)" : ""))
            }
        }
        // Still writing to its own log, so it is working - slowly, or on
        // something that holds the queue a status question has to wait for.
        // The clock on "not answering" starts again from here.
        if facts.daemonSpoke, unansweredSince != nil {
            judgement.notes.append("mslhd is slow but still working - "
                                   + "waiting again before calling it wedged")
            unansweredSince = facts.uptime
        }

        binaryGoneSince = track(binaryGoneSince, bad: !facts.daemonBinaryUsable, at: facts.uptime)
        if binaryGoneSince == facts.uptime {
            judgement.notes.append("the installed mslhd is missing or not executable")
        }
        let stateBad = !facts.stateWritable || !facts.registryReadable
        stateBadSince = track(stateBadSince, bad: stateBad, at: facts.uptime)
        if stateBadSince == facts.uptime {
            judgement.notes.append(facts.stateWritable
                ? "the instance registry cannot be read"
                : "MSL's own folder cannot be written")
        }

        // **MSL explaining itself beats the observer inferring.** When MSL has
        // just stopped with one of its own codes, that screen names the real
        // condition; a second window from out here would only talk over it.
        let explainedNow = facts.mslSaidFatal
            || (facts.crashNoteAge.map { $0 < thresholds.deferToOwnNote } ?? false)
        if explainedNow {
            if ownNoteSeenAt == nil {
                judgement.notes.append("MSL has put up its own crash screen "
                                       + "- leaving it to say what happened")
            }
            ownNoteSeenAt = facts.uptime
        }
        if let seen = ownNoteSeenAt, facts.uptime - seen < thresholds.deferToOwnNote {
            return judgement
        }
        ownNoteSeenAt = nil

        // MSL being *removed* is not MSL failing. This process keeps running
        // from an unlinked inode once its own program is deleted, and
        // everything below would then be describing a successful uninstall.
        guard facts.observerInstalled else {
            judgement.notes.append("the observer's own program is gone "
                                   + "- MSL is being removed, so nothing here is a fault")
            forgetStreaks()
            return judgement
        }

        // Nothing is expected to be running, so nothing is wrong with it not
        // being. Someone who turned the service off meant it.
        let daemonExpected = !facts.optedOut || facts.daemonPID != nil

        for candidate in [
            reached(stateBadSince, facts.uptime, thresholds.stateBadLimit)
                ? (ObserverStopCode.stateDirectoryUnusable, stateDetail(facts)) : nil,
            daemonExpected && reached(binaryGoneSince, facts.uptime, thresholds.binaryGoneLimit)
                ? (ObserverStopCode.serviceIsNotInstalled,
                   "\(ObserverPaths.daemonBinary.path) has been missing for "
                   + "\(Int(facts.uptime - (binaryGoneSince ?? facts.uptime)))s") : nil,
            daemonExpected && restartsWithoutService.count >= thresholds.restartLoopCount
                ? (ObserverStopCode.serviceWillNotStayUp, restartDetail(facts)) : nil,
            daemonExpected && reached(unansweredSince, facts.uptime, thresholds.unansweredLimit)
                ? (ObserverStopCode.serviceStoppedAnswering, unansweredDetail(facts)) : nil,
        ].compactMap({ $0 }) {
            guard !raised.contains(candidate.0.number) else {
                judgement.notes.append("\(candidate.0.printed) \(candidate.0.name) again, "
                                       + "already shown this session: \(candidate.1)")
                continue
            }
            raised.insert(candidate.0.number)
            judgement.raise = .init(code: candidate.0, detail: candidate.1)
            return judgement
        }
        return judgement
    }

    // MARK: - Details
    //
    // What goes under the code on screen and into the incident report. Each
    // one is written to be quotable in an issue: counts, seconds, pids, and
    // whatever macOS itself said.

    private func restartDetail(_ facts: ObserverFacts) -> String {
        var detail = "\(restartsWithoutService.count) restarts of mslhd within "
            + "\(Int(thresholds.restartLoopWindow))s, none of which answered a request"
        if let report = facts.newestCrashReport { detail += "; macOS reported \(report)" }
        return detail
    }

    private func unansweredDetail(_ facts: ObserverFacts) -> String {
        let seconds = Int(facts.uptime - (unansweredSince ?? facts.uptime))
        var detail = "mslhd (pid \(facts.daemonPID.map(String.init) ?? "?")) has not answered "
            + "INSTANCES for \(seconds)s"
        if facts.socketConnected == true { detail += "; the socket still accepts connections" }
        if let report = facts.newestCrashReport { detail += "; macOS reported \(report)" }
        return detail
    }

    private func stateDetail(_ facts: ObserverFacts) -> String {
        let seconds = Int(facts.uptime - (stateBadSince ?? facts.uptime))
        return (facts.stateWritable
                ? "the instance registry has been unreadable"
                : "\(ObserverPaths.appSupport.path) has not been writable")
            + " for \(seconds)s"
    }

    // MARK: - Streaks

    /// When something bad started, or nil while it is fine. Returns the
    /// current tick's uptime on the tick a streak *begins*, which is what the
    /// caller uses to log the transition exactly once.
    private func track(_ since: Double?, bad: Bool, at uptime: Double) -> Double? {
        guard bad else { return nil }
        return since ?? uptime
    }

    private func reached(_ since: Double?, _ uptime: Double, _ limit: Double) -> Bool {
        guard let since else { return false }
        return uptime - since >= limit
    }

    private mutating func forgetStreaks() {
        restartsWithoutService.removeAll()
        ownNoteSeenAt = nil
        unansweredSince = nil
        binaryGoneSince = nil
        stateBadSince = nil
        servedCurrentPID = false
    }
}
