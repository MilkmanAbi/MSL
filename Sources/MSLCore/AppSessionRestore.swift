// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import AppKit
import Foundation

/// Linux apps across a hibernate: closed politely before the guest is
/// saved, opened again after it comes back.
///
/// **Why they cannot simply be reconnected**, the way a shell can. A
/// hibernate saves the guest's whole RAM, so the app process survives - but
/// the X *server* it was talking to is `mslgd`, which lives on the Mac and
/// dies with every resource it owned: windows, pixmaps, GCs, colormaps.
/// Every XID the app holds is now a dangling reference into a server that
/// no longer exists. Handing it a fresh server would mean checkpointing and
/// restoring X server state, which is a larger project than MSL and would
/// break whenever mslgd's internals changed. A shell keeps its pty, which
/// lives in the guest; a window does not.
///
/// **Closing and relaunching are one feature, not two.** Recording without
/// closing looks like a cheap first step and is broken: on resume the app
/// is still alive in restored RAM with a dead X connection, holding its
/// singleton lock, so a relaunch on top of it just exits - which is exactly
/// what Chromium did ("Opening in existing browser session", 2026-10-02).
public enum AppSessionRestore {

    /// One app that was open when an instance was hibernated.
    public struct Entry: Codable, Equatable, Sendable {
        /// What the host process called itself, which is the app's display
        /// name (`x11tunnel --announce`, see `X11AppIdentity`).
        public var name: String
        /// The guest command to start it again, resolved from the catalog
        /// at hibernate time. Nil means MSL knew the name but not how to
        /// start it, and the app is reported rather than silently dropped.
        public var command: String?

        public init(name: String, command: String?) {
            self.name = name
            self.command = command
        }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var instance: String
        public var saved: Date
        public var apps: [Entry]

        public init(instance: String, saved: Date = Date(), apps: [Entry]) {
            self.instance = instance
            self.saved = saved
            self.apps = apps
        }
    }

    // MARK: - Storage

    static func url(instance: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("reopen-\(instance).json")
    }

    public static func manifest(for instance: String,
                                appSupport: URL = MSLPaths.appSupport) -> Manifest? {
        guard let data = try? Data(contentsOf: url(instance: instance, appSupport: appSupport))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    @discardableResult
    public static func save(_ manifest: Manifest, appSupport: URL = MSLPaths.appSupport) -> Bool {
        guard !manifest.apps.isEmpty else {
            forget(instance: manifest.instance, appSupport: appSupport)
            return true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return false }
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (try? data.write(to: url(instance: manifest.instance, appSupport: appSupport),
                                options: .atomic)) != nil
    }

    /// Dropped when the instance is removed, like every other per-instance
    /// file - or a new instance reusing the name would reopen somebody
    /// else's apps.
    public static func forget(instance: String, appSupport: URL = MSLPaths.appSupport) {
        try? FileManager.default.removeItem(at: url(instance: instance, appSupport: appSupport))
    }

    // MARK: - Finding the hosts

    /// The running per-app host processes.
    ///
    /// Found by executable path rather than by a list MSL keeps: each host
    /// is a copy of the shim binary under `X11AppRouter.shimDirectory`,
    /// named after its app, and a list could go stale when one exits on its
    /// own (`exitIfIdle`). The processes themselves are the truth.
    public static func runningHosts() -> [NSRunningApplication] {
        let shims = X11AppRouter.shimDirectory
        return NSWorkspace.shared.runningApplications.filter {
            guard let path = $0.executableURL?.resolvingSymlinksInPath().path else { return false }
            return path.hasPrefix(shims)
        }
    }

    /// What is open right now, as a manifest - resolving each host's name
    /// to a command through the instance's own app catalog.
    /// Whether `name` lowercased looks like something a guest could run.
    ///
    /// Only the shape is decided here; whether the command *exists* is
    /// answered by the caller, which has a direct line to the guest. This
    /// deliberately does **not** reach the guest itself: the only caller is
    /// `mslhd`, mid-way through handling a hibernate, and going out through
    /// `LinuxAppLauncher` would route a request back into the daemon that is
    /// already busy serving one - re-entrant, and it hung the close long
    /// enough that every app was called stubborn.
    public static func candidateCommand(for name: String) -> String? {
        let candidate = name.lowercased()
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        return candidate
    }

    public static func snapshot(instance: String,
                                hosts: [NSRunningApplication]? = nil,
                                catalog: [LinuxApp]? = nil,
                                resolve: ((String) -> String?)? = nil) -> Manifest {
        let live = hosts ?? runningHosts()
        let apps = catalog ?? LinuxAppCatalog.cached(instance: instance)
        var seen = Set<String>()
        var entries: [Entry] = []
        for host in live {
            guard let name = host.localizedName, !name.isEmpty else { continue }
            // One entry per app, not per process. A multi-process app
            // announces more than one name under `setproctitle` - Chromium's
            // GPU process is the known case - and relaunching a helper on
            // its own is meaningless.
            guard seen.insert(name).inserted else { continue }
            let match = apps.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            entries.append(Entry(name: name, command: match?.command ?? resolve?(name)))
        }
        return Manifest(instance: instance, apps: entries.sorted { $0.name < $1.name })
    }

    // MARK: - Closing

    /// What to do about an app that will not close.
    public enum Refusal: Sendable {
        /// The person asked for this hibernate: stop, and name the app.
        case abort
        /// The idle timer: an automatic hibernate must never take somebody's
        /// unsaved work, so it simply does not happen.
        case skip
        /// A power event. macOS cannot be vetoed, so the guest is saved with
        /// the app still open - it will come back without its windows, which
        /// is the least-bad option available.
        case force
    }

    public struct CloseResult: Sendable {
        /// Apps that were open, recorded whether or not they closed.
        public var manifest: Manifest
        /// Apps still running when the grace ran out.
        public var stubborn: [String]
        public var allClosed: Bool { stubborn.isEmpty }
    }

    /// Asks every Linux app to close, and waits.
    ///
    /// `NSRunningApplication.terminate()` runs AppKit's ordinary quit path,
    /// which reaches `X11Connection.windowShouldClose`, which already checks
    /// `WM_PROTOCOLS` and sends `WM_DELETE_WINDOW`. So the polite close -
    /// the thing that makes an app show its save prompt, and the only thing
    /// protecting unsaved work - costs no new protocol and no mslgd control
    /// surface at all.
    @discardableResult
    public static func closeApps(instance: String,
                                 within grace: TimeInterval = 20,
                                 interval: TimeInterval = 0.25,
                                 hosts: [NSRunningApplication]? = nil,
                                 resolve: ((String) -> String?)? = nil,
                                 appSupport: URL = MSLPaths.appSupport) -> CloseResult {
        let live = hosts ?? runningHosts()
        // Resolved **now**, while the guest is still running. After the
        // hibernate there is nothing to ask.
        let manifest = snapshot(instance: instance, hosts: live, resolve: resolve)
        guard !live.isEmpty else {
            forget(instance: instance, appSupport: appSupport)
            return CloseResult(manifest: manifest, stubborn: [])
        }

        // Recorded *before* anything is asked to close. A close that goes
        // wrong half way through must still leave MSL knowing what was open.
        save(manifest, appSupport: appSupport)

        for host in live { _ = host.terminate() }

        // A wait, not a sample: an app showing a save dialog is still
        // terminating, and asking once immediately would call every one of
        // them stubborn.
        //
        // Liveness by **sysctl**, which is the only check here that is
        // neither notification-backed nor fooled by a zombie. Three others
        // were tried and all three reported an app as running after it had
        // demonstrably quit - refusing every hibernate with "X wouldn't
        // close" while X was gone from the guest:
        //
        //   NSRunningApplication.isTerminated   KVO-backed
        //   NSWorkspace.runningApplications     notification-backed
        //   kill(pid, 0)                        true for a zombie
        //
        // The first two share one root cause: both are maintained by the
        // run loop, and **mslhd is a daemon that does not pump one**, so
        // each serves a frozen answer. The third is wrong because mslhd
        // `posix_spawn`s the per-app hosts and never reaps them, so an
        // exited host answers signal 0 forever.
        let pids = live.map(\.processIdentifier)
        func stillRunning() -> [pid_t] { pids.filter { processIsAlive($0) } }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if stillRunning().isEmpty { break }
            Thread.sleep(forTimeInterval: interval)
        }
        let remaining = Set(stillRunning())
        let stubborn = live.filter { remaining.contains($0.processIdentifier) }
            .compactMap(\.localizedName).sorted()
        return CloseResult(manifest: manifest, stubborn: stubborn)
    }

    /// The last resort, for a power event that cannot be vetoed.
    public static func forceClose(hosts: [NSRunningApplication]? = nil) {
        for host in hosts ?? runningHosts() { _ = host.forceTerminate() }
    }

    /// Whether `pid` is a process that is actually still running.
    ///
    /// `sysctl` rather than `kill(pid, 0)`: a **zombie** answers signal 0,
    /// and these hosts become zombies because `mslhd` spawns them and never
    /// reaps them. And `sysctl` rather than anything from AppKit, because
    /// every AppKit answer here is maintained by a run loop that a daemon
    /// does not pump.
    public static func processIsAlive(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    // MARK: - Reopening into state, where the app can

    /// Extra arguments that make an app come back **where it was** rather
    /// than at a blank window.
    ///
    /// This is the honest limit of what a hibernate can do for a GUI app.
    /// The app's own process is killed - it has to be, because the X server
    /// it was drawing into lives on the Mac and dies with it - so MSL cannot
    /// hand back its windows. What it *can* do is ask the app to restore the
    /// session it saved on its way out, which for a browser is the whole
    /// point: a search typed before a hibernate is still there afterwards.
    /// Verified with Chromium: without this it reopens on a blank tab, with
    /// it the search comes back.
    ///
    /// Only arguments that are safe to pass twice, since a relaunch may
    /// already carry them.
    static let restoreArguments: [(match: String, argument: String)] = [
        ("chromium", "--restore-last-session"),
        ("chrome", "--restore-last-session"),
        ("brave", "--restore-last-session"),
        ("microsoft-edge", "--restore-last-session"),
        ("vivaldi", "--restore-last-session"),
        // Firefox restores its own session by default and has no equivalent
        // flag worth forcing, so it is deliberately absent rather than
        // guessed at.
    ]

    /// `command`, with whatever makes it reopen where it was.
    public static func restoring(_ command: String) -> String {
        // The executable only: an argument that happens to contain "chrome"
        // must not make an unrelated program get a browser's flag.
        let executable = (command.split(separator: " ").first.map(String.init) ?? command)
            .split(separator: "/").last.map(String.init) ?? command
        guard let match = restoreArguments.first(where: {
            executable.lowercased() == $0.match || executable.lowercased().hasPrefix($0.match + "-")
        }) else { return command }
        guard !command.contains(match.argument) else { return command }
        return command + " " + match.argument
    }

    // MARK: - Reopening

    public struct ReopenResult: Sendable {
        public var opened: [String]
        /// Recorded as open, but MSL has no command for them - the catalog
        /// never knew the app, or it was started by hand from a shell.
        public var unknown: [String]
    }

    /// Opens again whatever `closeApps` recorded, and forgets the manifest.
    ///
    /// The manifest is cleared **first**. A relaunch that crashes must not
    /// leave a manifest that tries the same thing on every future resume.
    @discardableResult
    /// `launch` is last on purpose: it is what callers actually pass, and
    /// with `log` after it a trailing closure bound to the logger instead -
    /// silently launching nothing, which a test caught.
    public static func reopen(instance: String, distro: GuestDistro,
                              appSupport: URL = MSLPaths.appSupport,
                              log: ((String) -> Void)? = nil,
                              launch: (String) -> Void = { _ in }) -> ReopenResult {
        guard let manifest = manifest(for: instance, appSupport: appSupport) else {
            return ReopenResult(opened: [], unknown: [])
        }
        forget(instance: instance, appSupport: appSupport)

        var opened: [String] = []
        var unknown: [String] = []
        for app in manifest.apps {
            guard let command = app.command else {
                unknown.append(app.name)
                continue
            }
            log?("reopening \(app.name)")
            launch(restoring(command))
            opened.append(app.name)
        }
        return ReopenResult(opened: opened, unknown: unknown)
    }

    /// The live launcher, separated so `reopen` is testable without a guest.
    public static func launcher(instance: String, distro: GuestDistro) -> (String) -> Void {
        { command in
            // Detached and best effort: one app failing to start must not
            // stop the rest from coming back, and nobody is waiting on the
            // exit code of a window reopening.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? LinuxAppLauncher.run(instance: instance, distro: distro, command: command)
            }
        }
    }
}
