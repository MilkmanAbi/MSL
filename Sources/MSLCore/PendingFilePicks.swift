import Foundation

/// The file picks `mslhd` is holding while MSL Files shows the dialog.
///
/// A Linux app asking for a file is a **three-party** conversation: the guest
/// app waits on its D-Bus reply, `mslhd` holds that connection open, and MSL
/// Files - a separate process, and the only one of the three that owns
/// windows - actually shows the picker. This is where the request waits in
/// between, keyed by a token that travels to MSL Files in a URL and comes
/// back with the answer.
///
/// See `READMES/24-FILE-PICKER.md` for why MSL Files is the presenter and
/// not `mslhd` itself.
public final class PendingFilePicks: @unchecked Sendable {
    public static let shared = PendingFilePicks()

    /// How a pick ended.
    public enum Outcome: Equatable, Sendable {
        /// Paths the guest can open. Never empty.
        case picked([String])
        /// The person closed the picker. **Not** the same as `unavailable`:
        /// a cancel is a decision, and the app must not then be shown a
        /// second dialog of its own.
        case cancelled
        /// MSL Files never answered - it could not start, or it was quit
        /// with the picker open. The app falls back to its own dialog,
        /// which is the right outcome for "MSL could not do this".
        case unavailable
    }

    private struct Entry {
        let request: HostFilePickRequest
        let instance: String
        let ready = DispatchSemaphore(value: 0)
        var outcome: Outcome?
        /// Set once MSL Files has asked for the details, which is proof it
        /// is alive and showing something. Until then the wait is short.
        var claimed = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// How long MSL Files has to *claim* a pick before it is given up on.
    /// Only covers it noticing and showing the window - never the person.
    ///
    /// Short on purpose. The app that asked is blocked on its reply for this
    /// whole time, and Firefox does not survive a long wait: its IPC to its
    /// child processes times out and it quits. MSL Files is kept running by
    /// `MSLFilesPrewarm` precisely so this never needs to be generous - a
    /// warm app claims in well under a second, and if it is not there at all
    /// the app should hear "no" quickly and open its own dialog.
    public static let claimDeadline: TimeInterval = 6

    public init() {}

    /// Parks a request and returns the token that names it.
    public func register(_ request: HostFilePickRequest, instance: String) -> String {
        let token = UUID().uuidString
        lock.lock()
        entries[token] = Entry(request: request, instance: instance)
        lock.unlock()
        return token
    }

    /// MSL Files asking what to show. Claiming it also says "I am alive",
    /// which is what lets the wait below stop being impatient.
    public func claim(token: String) -> (request: HostFilePickRequest, instance: String)? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[token] else { return nil }
        entry.claimed = true
        entries[token] = entry
        return (entry.request, entry.instance)
    }

    /// MSL Files reporting what happened.
    public func complete(token: String, outcome: Outcome) {
        lock.lock()
        guard let entry = entries[token], entry.outcome == nil else { return lock.unlock() }
        var updated = entry
        updated.outcome = outcome
        entries[token] = updated
        lock.unlock()
        entry.ready.signal()
    }

    /// Blocks the calling thread until the pick is answered.
    ///
    /// **Two deadlines, deliberately.** Getting MSL Files on screen is
    /// bounded (`claimDeadline`) because if it is not coming, the app should
    /// stop waiting and open its own dialog. Once it *has* claimed the pick,
    /// there is **no deadline at all** - a person may browse for minutes,
    /// and cutting that short would hand the app an answer they never gave.
    public func wait(token: String) -> Outcome {
        let claimed = waitForClaim(token: token)
        lock.lock()
        let entry = entries[token]
        lock.unlock()
        guard let entry else { return .unavailable }
        if !claimed, entry.outcome == nil {
            forget(token: token)
            return .unavailable
        }
        entry.ready.wait()
        lock.lock()
        let outcome = entries[token]?.outcome
        entries.removeValue(forKey: token)
        lock.unlock()
        return outcome ?? .unavailable
    }

    /// Polls for the claim rather than blocking on it: the claim and the
    /// answer arrive on the same semaphore, and a picker that is claimed
    /// then abandoned must not be mistaken for one that never started.
    private func waitForClaim(token: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.claimDeadline)
        while Date() < deadline {
            lock.lock()
            let entry = entries[token]
            lock.unlock()
            guard let entry else { return false }
            if entry.claimed || entry.outcome != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func forget(token: String) {
        lock.lock(); entries.removeValue(forKey: token); lock.unlock()
    }

    /// Everything still waiting gives up. For a daemon shutting down, so no
    /// guest app is left hanging on an answer that can no longer come.
    public func abandonAll() {
        lock.lock()
        let pending = entries
        entries.removeAll()
        lock.unlock()
        for (_, entry) in pending where entry.outcome == nil { entry.ready.signal() }
    }

    /// For tests and for the daemon's own status.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
