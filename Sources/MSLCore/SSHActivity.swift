import Foundation

/// Whether someone is using an instance over SSH right now.
///
/// SSH reaches a guest over its own network address, straight past mslhd, so
/// the daemon's idle tracking - which only sees `msl` sessions - thinks an
/// instance with a live `ssh msl-<name>` is idle. Pausing or hibernating it
/// then freezes that session mid-command (found 2026-09-14: paused five
/// seconds into `ssh msl-debian 'sleep 15; echo ALIVE'`, which never printed).
/// The guest's own socket table, read through trafficd, is the only place that
/// knows.
public enum SSHActivity {
    public static let sshPort: UInt16 = 22
    /// `/proc/net/tcp`'s ESTABLISHED.
    static let established: UInt8 = 0x01

    /// True when any TCP connection to the guest's SSH port is established.
    /// A listening sshd on its own is not activity.
    public static func hasLiveSessions(_ connections: [TrafficProtocol.Connection]) -> Bool {
        connections.contains {
            $0.proto == .tcp && $0.localPort == sshPort && $0.stateCode == established
        }
    }
}
