// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Darwin
import Foundation
import MSLCore

/// Finds and ends tunnels left behind by a previous `mslhd`.
///
/// ## The leak this exists for
///
/// Restarting the daemon does not take its `ssh` children with it. Measured
/// during development: after two rebuilds, three tunnel processes were
/// running at once, one of them from a build two versions old, each holding
/// its own relay session and each still forwarding to the guest.
///
/// That is worse than untidy. An orphaned tunnel **keeps an instance
/// published at an address nothing is tracking**: `msl public status` knows
/// nothing about it, `msl public revoke` cannot close it, and the app shows
/// the instance as private. The user would have to find a stray `ssh`
/// process to stop being on the internet.
///
/// Closing stdin is not enough on its own, which is the obvious thing to
/// try: with an active remote forward, `ssh` keeps the connection up after
/// its session channel sees EOF. So the pid is written down and reaped
/// deliberately.
public enum TunnelReaper {

    static var directory: URL { MSLPaths.appSupport.appendingPathComponent("public") }

    static func pidFile(instance: String) -> URL {
        directory.appendingPathComponent("\(instance).tunnel.pid")
    }

    public static func record(pid: Int32, instance: String) {
        _ = MSLPaths.ensureDirectory(directory)
        try? String(pid).write(to: pidFile(instance: instance), atomically: true, encoding: .utf8)
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: pidFile(instance: instance))
    }

    /// Ends the tunnel recorded for this instance, if one is still running.
    ///
    /// Called before publishing and at daemon start. Returns whether
    /// anything was actually killed, for the log - a silent reap would
    /// leave no trace of a leak having happened.
    @discardableResult
    public static func reap(instance: String) -> Bool {
        guard let text = try? String(contentsOf: pidFile(instance: instance), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            return false
        }
        defer { forget(instance: instance) }
        // Alive at all?
        guard kill(pid, 0) == 0 else { return false }
        // **And still the process we think it is.** Pids are reused, and
        // this code sends a signal to a number read off disk - without
        // checking what it points at now, a stale file could kill something
        // else entirely.
        return ProcessIdentity.terminateSSHTunnel(pid: pid)
    }

    /// Whether a pid is an `ssh` process holding a remote forward.
    ///
    /// Reads it from the process rather than trusting the file, for the
    /// pid-reuse reason above. Shared with the uninstaller, which signals
    /// pids off the same disk.
    static func isOurTunnel(pid: Int32) -> Bool { ProcessIdentity.isSSHTunnel(pid: pid) }

    static func commandLine(pid: Int32) -> String? { ProcessIdentity.commandLine(pid: pid) }

    /// Reaps every recorded tunnel. Run once at daemon start, before
    /// anything is published again.
    public static func reapAll(log: (String) -> Void = { _ in }) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".tunnel.pid") {
            let instance = String(name.dropLast(".tunnel.pid".count))
            if reap(instance: instance) {
                log("closed a tunnel for \(instance) left over from a previous run")
            }
        }
    }
}
