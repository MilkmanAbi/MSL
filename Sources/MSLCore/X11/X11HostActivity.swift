import Foundation

/// Keeps a per-app host awake while a Linux app is actually connected to it.
///
/// Each Linux app runs in its own macOS host process, and that process holds
/// the live X11 socket the guest app draws through. macOS treats a process
/// with no visible window as a candidate for **App Nap** - "not visible, not
/// audible, has not explicitly disabled automatic termination, and has not
/// taken any power management assertions" - and a napped host stops servicing
/// the socket. The guest app then blocks on its next write with nothing on
/// the Mac side to explain it: the app simply freezes, and un-minimising it
/// is what appears to fix it. Automatic and sudden termination are the same
/// hazard by a different route - the host is killed with a client attached,
/// and the guest sees its display vanish.
///
/// `beginActivity` is the documented way to say "this process is doing
/// something for the person, do not throttle it".
///
/// **The option set matters.** `.userInitiated` includes
/// `idleSystemSleepDisabled`, which would stop the Mac ever idle-sleeping
/// while any Linux app was open - that fights MSL's own power handling
/// (`SystemResilienceMonitor`), which exists precisely so sleep works
/// properly. `.userInitiatedAllowingIdleSystemSleep` is the same promise
/// without that clause: no napping, no automatic or sudden termination, and
/// the Mac still sleeps when the person leaves it alone. Sleep is then
/// handled deliberately, by pausing the guest, rather than by a host being
/// frozen underneath it.
///
/// Held only while at least one client is connected, so an idle host with no
/// app in it is free to be napped like anything else.
public enum X11HostActivity {
    private static let lock = NSLock()
    private static var token: NSObjectProtocol?

    /// Called whenever the number of connected X11 clients changes.
    public static func connectionCountChanged(to count: Int) {
        lock.lock(); defer { lock.unlock() }
        if count > 0, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "A Linux app is connected to this display server")
        } else if count == 0, let held = token {
            ProcessInfo.processInfo.endActivity(held)
            token = nil
        }
    }

    /// Whether the activity is currently held - for tests, which otherwise
    /// have no way to see a token that only the system holds.
    public static var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return token != nil
    }
}
