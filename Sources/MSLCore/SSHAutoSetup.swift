import Foundation

/// Decides when MSL should set an instance up for SSH without being asked.
///
/// Pure and separate from the app because the trigger is the dangerous part.
/// It hangs off a poll loop that rebuilds the instance list every few
/// seconds, and every false fire is a full guest shell round trip that
/// installs a key and starts a service. The rules below are all there to
/// stop that happening, and they are the only part of the automatic path
/// that can be tested without a guest.
public enum SSHAutoSetup {

    /// Whether `instance` just became eligible for automatic setup.
    ///
    /// - `previous`: the instance's state in the last poll, or nil if it was
    ///   not in the list at all (a fresh app launch, or a daemon restart).
    /// - `current`: its state now.
    /// - `inFlight`: a setup is already running for it.
    /// - `hasRecord`: MSL has configured this instance before.
    public static func shouldConfigure(previous: VMManager.InstanceState?,
                                       current: VMManager.InstanceState,
                                       enabled: Bool,
                                       inFlight: Bool,
                                       hasRecord: Bool) -> Bool {
        guard enabled, !inFlight, current == .running else { return false }

        // No previous state means this is the first time the app has seen
        // this instance - app launch, daemon restart, or a poll that failed
        // to parse. Everything looks like a transition then, so an instance
        // that has been running for hours would get reconfigured every time
        // the app opened. An instance MSL has never configured is worth one
        // attempt; one it already knows is not.
        guard let previous else { return !hasRecord }

        // `paused -> running` is a resume. The guest kept its address and
        // its authorized_keys across it, so there is nothing to redo.
        guard previous != .paused, previous != .running else { return false }

        return true
    }

    /// How long a successful configuration is trusted before the automatic
    /// path will spend a guest round trip on it again.
    ///
    /// A DHCP lease can move across a cold boot, so this is not "never" -
    /// but the reachability probe in `verifyExisting` is the real guard, and
    /// it costs a TCP connect rather than a shell session.
    public static let recheckAfter: TimeInterval = 60 * 60 * 12

    public static func recordIsStale(_ record: SSHSetup.Record, now: Date = Date()) -> Bool {
        now.timeIntervalSince(record.lastConfigured) > recheckAfter
    }
}
