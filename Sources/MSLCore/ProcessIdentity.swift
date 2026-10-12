import Darwin
import Foundation

/// Reading a running process's command line, to check a pid is still what
/// wrote it down.
///
/// In MSLCore rather than beside its first caller because two places send
/// signals to pids read off disk - `PublicMSL.TunnelReaper` and the
/// uninstaller - and a pid is only meaningful alongside a check of what it
/// currently points at. Pids are reused, so a stale file plus an unchecked
/// `kill` is a signal sent to whatever happens to hold that number now.
public enum ProcessIdentity {

    /// The executable path and arguments, space-separated, or nil if the
    /// process is gone or unreadable.
    public static func commandLine(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        // KERN_PROCARGS2 is a 32-bit argc, then the executable path, then
        // the arguments, all NUL-separated.
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        guard bytes.count > 4 else { return nil }
        return String(decoding: bytes[4...], as: UTF8.self).replacingOccurrences(of: "\0", with: " ")
    }

    /// Whether a pid is an `ssh` holding a remote forward - a tunnel MSL
    /// opened, rather than somebody's own session.
    ///
    /// Both halves matter: plain `ssh` to a host is the user's own and must
    /// never be signalled, and `-R` is what makes it a tunnel.
    public static func isSSHTunnel(pid: Int32) -> Bool {
        guard let line = commandLine(pid: pid) else { return false }
        return line.contains("/ssh") && line.contains("-R")
    }

    /// Ends an SSH tunnel by pid, and only if it still is one.
    @discardableResult
    public static func terminateSSHTunnel(pid: Int32, waitingUpTo seconds: Double = 2) -> Bool {
        guard pid > 1, kill(pid, 0) == 0, isSSHTunnel(pid: pid) else { return false }
        kill(pid, SIGTERM)
        let steps = Int(seconds / 0.1)
        for _ in 0..<steps {
            usleep(100_000)
            if kill(pid, 0) != 0 { return true }
        }
        // A tunnel that will not go keeps an instance reachable, so this
        // does not give up politely.
        kill(pid, SIGKILL)
        return true
    }
}
