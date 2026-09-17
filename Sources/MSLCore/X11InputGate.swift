import Foundation

/// Drops host input before it is encoded for the guest.
///
/// The awkward part this exists to solve: input does not enter the guest
/// from one place. `mslhd` owns the connections for windows it hosts
/// itself, but every Linux app also gets its **own `mslgui` process** (see
/// `X11AppRouter`), and that process holds its own descriptor to the guest
/// and writes input straight down it. A flag inside `mslhd` would leave
/// every already-running app perfectly able to type.
///
/// So the gate is backed by the policy file rather than by memory: any
/// process, started at any time, sees the same answer within `refreshAfter`
/// of the toggle. That is also why this is a singleton keyed by instance
/// rather than an object someone has to be handed - the call site is deep
/// inside event handling, and threading a reference down to it would be a
/// much larger change than the feature is worth.
///
/// Cost is one `stat` per instance per 250 ms, not one per event: the
/// decoded value is cached and only re-read when the file's modification
/// date moves.
public final class X11InputGate: @unchecked Sendable {
    public static let shared = X11InputGate()

    private let lock = NSLock()
    private var cache: [String: (frozen: Bool, checked: Date, stamp: Date?)] = [:]
    private let refreshAfter: TimeInterval = 0.25

    private init() {}

    /// Whether input for `instance` should be dropped right now.
    ///
    /// `nil` instance means "this process was never told which instance it
    /// serves", which is the honest answer for an `mslgui` started before
    /// this argument existed. It fails **open** on purpose: a stale app
    /// host that still accepts typing is a visible, explainable gap, while
    /// silently freezing every app whose provenance we are unsure of would
    /// look exactly like the input system being broken.
    public func isFrozen(instance: String?) -> Bool {
        guard let instance else { return false }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let entry = cache[instance], now.timeIntervalSince(entry.checked) < refreshAfter {
            return entry.frozen
        }

        let url = SandboxPolicyStore.file(for: instance)
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        // Unchanged file: refresh the timestamp, skip the decode.
        if let entry = cache[instance], entry.stamp == stamp {
            cache[instance] = (entry.frozen, now, stamp)
            return entry.frozen
        }

        let frozen = SandboxPolicyStore.load(instance: instance).inputFrozen
        cache[instance] = (frozen, now, stamp)
        return frozen
    }

    /// Called by `VMManager` when the policy changes, so the process that
    /// made the change does not wait out its own cache.
    public func setFrozen(_ frozen: Bool, instance: String) {
        lock.lock()
        cache[instance] = (frozen, Date(), nil)
        lock.unlock()
    }

    /// Testing seam - drops everything cached.
    public func invalidate() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}
