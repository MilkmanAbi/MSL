import Foundation

/// Turns `waitpid`'s status word into the exit code a person expects to see.
///
/// SwiftTerm's `processTerminated` passes the raw status straight through, so
/// the Terminal tab showed `msl` exiting 127 ("no such user") as
/// "Session ended (exit 32,512)" - 127 shifted left eight bits.
public enum ProcessExitStatus {
    /// An exit code for a process that exited; 128 + the signal for one that
    /// was killed, the shell's own convention. A stopped process isn't an end
    /// state, so its status passes through unchanged.
    public static func code(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        if low != 0x7f { return 128 + low }
        return status
    }
}
