import Foundation

/// "Ask for Touch ID before starting this instance."
///
/// The check lives in the **background service**, not in the app. The app
/// asking would be theatre: anything that can talk to `mslhd` can start an
/// instance, and `msl work` is one word. `DaemonServer` runs this on every
/// request that would start something, which is the one place all of them
/// meet (`ControlRequest.startsInstance`).
///
/// What it protects, precisely: starting a stopped instance on this Mac. It
/// is not disk encryption. The image is still an ordinary file that anything
/// running as this user can read, and MSL says so in the UI rather than
/// letting people assume otherwise.
public struct InstanceLockSettings: Codable, Equatable, Sendable {
    /// Instances that need authentication before they start.
    public var locked: Set<String>

    public init(locked: Set<String> = []) {
        self.locked = locked
    }

    public func isLocked(_ instance: String) -> Bool { locked.contains(instance) }

    public mutating func setLocked(_ isLocked: Bool, for instance: String) {
        if isLocked { locked.insert(instance) } else { locked.remove(instance) }
    }
}

public enum InstanceLockStore {
    public static var file: URL {
        MSLPaths.appSupport.appendingPathComponent("locks.json")
    }

    public static func load(from url: URL = file) -> InstanceLockSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(InstanceLockSettings.self, from: data)
        else { return InstanceLockSettings() }
        return settings
    }

    @discardableResult
    public static func save(_ settings: InstanceLockSettings, to url: URL = file) -> Bool {
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    @discardableResult
    public static func setLocked(_ isLocked: Bool, for instance: String, in url: URL = file) -> Bool {
        // UNLOCKING is the restricted direction: a policy that locks an
        // instance means it to stay locked. Locking one is always allowed,
        // by the same rule as everywhere else - an operation that reduces
        // what can be done is never refused.
        if !isLocked, !MSLAPGate.allows("instance.lock", instance: instance) { return false }
        var settings = load(from: url)
        settings.setLocked(isLocked, for: instance)
        return save(settings, to: url)
    }
}

/// When to ask, kept separate from how to ask so the rule can be tested.
public enum InstanceLockPolicy {
    /// Authentication is for *starting*. An instance that is already running
    /// has been authorised once already, and asking again every time a Linux
    /// app reconnects would make the feature unusable: resuming a suspended
    /// instance happens whenever you open a window.
    public static func requiresAuthentication(instance: String,
                                              isRunningOrPaused: Bool,
                                              settings: InstanceLockSettings) -> Bool {
        guard settings.isLocked(instance) else { return false }
        return !isRunningOrPaused
    }

    /// What the system prompt says. Shown in the Touch ID sheet, so it has to
    /// name the instance and read as a sentence.
    public static func reason(for instance: String) -> String {
        "start \(instance)"
    }
}
