import Foundation

/// A replacement launch command for one Linux app, chosen from its
/// right-click menu in the Applications tab.
///
/// Some apps simply do not start from their own `.desktop` entry without
/// help: a game that needs a different LÖVE build, a binary that wants an
/// environment variable set, an app whose packaged entry points at the
/// wrong path. Those are one-line fixes if you can edit the command, and
/// otherwise they are "this app doesn't work on MSL".
///
/// Stored exactly like `AppGraphicsStore` - one small JSON file, keyed by
/// instance and the app's ORIGINAL command - so every launch route picks it
/// up: MSL.app, the generated app bundles, and `msl gui-native`. The
/// original command stays the key even after an override is set, or
/// changing the command would orphan the app's other per-app settings.
public enum AppCustomCommandStore {
    static var fileURL: URL { MSLPaths.appSupport.appendingPathComponent("app-commands.json") }

    public static func key(instance: String, command: String) -> String {
        instance + "\u{1F}" + command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw
    }

    /// The override for this app, or nil if it runs its own command.
    public static func command(instance: String, command: String) -> String? {
        let custom = load()[key(instance: instance, command: command)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false) ? custom : nil
    }

    /// Passing nil or an empty string clears the override.
    public static func set(_ custom: String?, instance: String, command: String) {
        // Clearing an override is always allowed: it returns the app to
        // its own command, which is the safe direction, and a policy that
        // blocked it would trap an override set before the policy arrived.
        let isClearing = (custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        guard isClearing || editingAllowed(instance: instance) else { return }
        var all = load()
        let key = key(instance: instance, command: command)
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { all.removeValue(forKey: key) } else { all[key] = trimmed }
        _ = MSLPaths.ensureDirectory(MSLPaths.appSupport)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Whether MSLAP permits editing this app's launch command.
    ///
    /// Checked in the STORE rather than only in the menu, because the menu
    /// is not the only way in - anything that can write this file could
    /// otherwise set a command the policy forbids. Hiding a control is not
    /// refusing an action.
    public static func editingAllowed(instance: String) -> Bool {
        let policy: MSLAPPolicy?
        switch MSLAPPolicyStore.cached() {
        case .managed(let loaded): policy = loaded.policy
        case .broken(_, let fallback): policy = fallback
        case .unmanaged: policy = nil
        }
        guard let policy else { return true }
        return policy.allows(MSLAPCapability("apps.customCommand"), instance: instance)
    }

    /// What should actually be run for this app.
    public static func effectiveCommand(instance: String, command: String) -> String {
        // `Self.` because the parameter shadows the function's own name.
        Self.command(instance: instance, command: command) ?? command
    }
}
