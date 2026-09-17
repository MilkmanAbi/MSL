// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Talks to `mslhd` over its control socket, and - unlike every other
/// client in this project - can *start* it if it isn't there.
///
/// "Check whether MSL is already open, open it if not, then run the app" is
/// the whole contract a generated `.app` bundle has with the rest of the
/// system, and `ShellClient`/`msl` both assume a daemon that already
/// exists. This is that missing half.
public enum DaemonClient {
    public enum StartError: Error, CustomStringConvertible {
        case noDaemonBinary(String)
        case didNotComeUp(TimeInterval)

        public var description: String {
            switch self {
            case .noDaemonBinary(let path): return "mslhd isn't installed at \(path)"
            case .didNotComeUp(let seconds): return "mslhd didn't start within \(Int(seconds))s"
            }
        }
    }

    /// Sends one control request and returns the daemon's reply line, or
    /// `nil` if the daemon isn't reachable at all. Never starts anything -
    /// callers that need the daemon up call `ensureRunning()` first, so
    /// that "is it running?" stays answerable without side effects.
    public static func send(_ request: DaemonProtocol.ControlRequest, timeout: TimeInterval = 120) -> String? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        _ = request.encode().withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
        }
        let text = String(decoding: response, as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// Whether the daemon is up *right now*. A live `connect()`, not a
    /// check for the socket file: `mslhd` unlinks and re-binds its socket
    /// on start but a killed daemon leaves the file behind, so the file
    /// existing proves nothing.
    public static func isRunning() -> Bool {
        guard let fd = connect() else { return false }
        close(fd)
        return true
    }

    /// Ensures the daemon is up, starting it via its LaunchAgent if not,
    /// and waits for it to accept connections. A no-op when it's already
    /// running, which is the overwhelmingly common case.
    public static func ensureRunning(timeout: TimeInterval = 25, log: ((String) -> Void)? = nil) throws {
        // A refused connect doesn't always mean "not running": a daemon busy
        // starting several VMs can leave its listen backlog full for a moment.
        // Give it a couple of seconds before deciding.
        for attempt in 0..<10 {
            if isRunning() { return }
            if attempt < 9 { usleep(200_000) }
        }

        let daemon = MSLPaths.tool("mslhd")
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else {
            throw StartError.noDaemonBinary(daemon.path)
        }

        log?("mslhd isn't running - starting it")
        installLaunchAgent()
        // `kickstart` rather than `load`: idempotent, and it starts the job
        // immediately instead of waiting for the next RunAtLoad.
        //
        // Never `kickstart -k`. `-k` kills the job if it is running, and a
        // running-but-busy daemon is exactly the case that reaches here - it
        // took every instance down with it. Found on 2026-09-14: mslhd
        // restarted repeatedly under concurrent `msl` commands, each restart
        // killing the VMs other commands were using. Plain `kickstart` starts
        // the job only when it isn't running, and the wait below does the rest.
        //
        // A `bootout` removes the job from launchd *entirely* - `launchctl
        // print` can't find it afterwards and `kickstart` fails with 113,
        // "Could not find service" (measured, 2026-09-16). That is the state
        // the installer's postinstall deliberately leaves behind after an
        // upgrade, and the state anyone who ran `launchctl bootout` by hand is
        // in - and `installLaunchAgent` above returns early without
        // bootstrapping when the plist itself hasn't changed, which after an
        // upgrade it hasn't. So: kickstart, and if the job is unknown,
        // bootstrap it back and kickstart that. Bootstrapping an
        // already-loaded job fails harmlessly, so only the first status matters.
        let domain = "gui/\(getuid())"
        if runLaunchctl(["kickstart", "\(domain)/\(MSLPaths.launchAgentLabel)"]) != 0 {
            runLaunchctl(["bootstrap", domain, MSLPaths.launchAgentPlist.path])
            runLaunchctl(["kickstart", "\(domain)/\(MSLPaths.launchAgentLabel)"])
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() {
                log?("mslhd is up")
                return
            }
            usleep(200_000)
        }
        throw StartError.didNotComeUp(timeout)
    }

    /// Writes (and loads) the per-user LaunchAgent that keeps `mslhd`
    /// alive.
    ///
    /// A LaunchAgent rather than a plain `posix_spawn` because of how
    /// `mslhd` starts VMs: `Virtualization.framework` bootstraps a helper
    /// process over XPC, and that has been observed to hang forever when
    /// `mslhd` is spawned from a context without a proper Aqua-session
    /// bootstrap namespace (a background tool shell), while working
    /// normally from a real login session. `LimitLoadToSessionType: Aqua`
    /// asks launchd for exactly the right kind of session, rather than
    /// inheriting whatever the spawning process happened to have.
    ///
    /// `KeepAlive` is deliberately `SuccessfulExit: false` and not plain
    /// `true`: a clean exit is the daemon being *asked* to stop, which
    /// should stay stopped; a crash should come back.
    @discardableResult
    public static func installLaunchAgent() -> Bool {
        let daemon = MSLPaths.tool("mslhd")
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else { return false }
        MSLPaths.ensureDirectory(MSLPaths.launchAgentPlist.deletingLastPathComponent())
        MSLPaths.ensureDirectory(MSLPaths.logsDirectory)

        let plist: [String: Any] = [
            "Label": MSLPaths.launchAgentLabel,
            "ProgramArguments": [daemon.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            // launchd's default is 20 seconds from SIGTERM to SIGKILL. The
            // resilience monitor can legitimately need most of that -
            // pausing every guest, then writing each one's RAM to disk - and
            // being SIGKILLed part-way through leaves guests that were never
            // frozen. Give it room, comfortably above the monitor's own
            // deadlines so those are what bound the work, not this.
            "ExitTimeOut": 40,
            "StandardOutPath": MSLPaths.logsDirectory.appendingPathComponent("mslhd.log").path,
            "StandardErrorPath": MSLPaths.logsDirectory.appendingPathComponent("mslhd.log").path,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        // Rewriting an identical plist would still need a bootout/bootstrap
        // cycle to take effect, so skip when nothing changed.
        let existing = try? Data(contentsOf: MSLPaths.launchAgentPlist)
        guard existing != data else { return true }
        guard (try? data.write(to: MSLPaths.launchAgentPlist, options: .atomic)) != nil else { return false }
        let domain = "gui/\(getuid())"
        runLaunchctl(["bootout", "\(domain)/\(MSLPaths.launchAgentLabel)"])
        runLaunchctl(["bootstrap", domain, MSLPaths.launchAgentPlist.path])
        return true
    }

    /// Removes the LaunchAgent, so `mslhd` stops coming back at login.
    public static func removeLaunchAgent() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(MSLPaths.launchAgentLabel)"])
        try? FileManager.default.removeItem(at: MSLPaths.launchAgentPlist)
    }

    public static func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: MSLPaths.launchAgentPlist.path)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func connect() -> Int32? {
        let path = DaemonProtocol.defaultSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                path.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
