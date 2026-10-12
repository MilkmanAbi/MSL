import Foundation
import MSLCore

/// Per-app choices made from an app's right-click menu that live in MSL
/// itself rather than in a generated bundle: where its OpenGL runs, and
/// whether it's pinned to the top of the Applications tab.
extension AppModel {
    func graphicsMode(for app: LinuxApp, in instance: Instance) -> AppGraphicsMode {
        graphicsModes[AppGraphicsStore.key(instance: instance.name, command: app.command)] ?? .automatic
    }

    /// The app's own command unless someone replaced it from the context
    /// menu. Kept keyed by the ORIGINAL command, so an override does not
    /// orphan the app's graphics choice.
    func customCommand(for app: LinuxApp, in instance: Instance) -> String? {
        customCommands[AppCustomCommandStore.key(instance: instance.name, command: app.command)]
    }

    func setCustomCommand(_ custom: String?, for app: LinuxApp, in instance: Instance) {
        // A launch command runs whatever it says in the guest, so this is
        // one of the few host-side settings an administrator may want to
        // take away. Enforced here rather than only by hiding the menu
        // item: hiding is not refusing.
        guard allows("apps.customCommand", in: instance) else { return }
        AppCustomCommandStore.set(custom, instance: instance.name, command: app.command)
        customCommands = AppCustomCommandStore.load()
    }

    /// Whether MSLAP permits a host-side capability for this instance.
    ///
    /// Tier 2: the daemon never sees these, so the app is the only place
    /// they can be refused. Nil policy means unmanaged, which allows
    /// everything - MSL must keep working normally for everyone who never
    /// installs a policy.
    func allows(_ capability: String, in instance: Instance?) -> Bool {
        guard let policy = adminPolicy else { return true }
        return policy.allows(MSLAPCapability(capability), instance: instance?.name)
    }

    /// Why a control is disabled, for the tooltip. Shown rather than
    /// hidden: a managed Mac that will not say why it refused is the thing
    /// people hate most about managed machines.
    func adminReason(_ capability: String, in instance: Instance?) -> String? {
        guard let policy = adminPolicy else { return nil }
        let decision = policy.decision(for: MSLAPCapability(capability),
                                       instance: instance?.name)
        guard !decision.allowed else { return nil }
        var text = "Not allowed by the MSL Admin Portal"
        if let reason = decision.deniedBy?.reason { text += ": \(reason)" }
        if let issuer = policy.issuer { text += " (set by \(issuer))" }
        return text
    }

    /// The policy in force, including the fallback when the installed one
    /// has been tampered with - editing the file must never be a way to
    /// re-enable something.
    var adminPolicy: MSLAPPolicy? {
        switch MSLAPPolicyStore.cached() {
        case .managed(let loaded): return loaded.policy
        case .broken(_, let fallback): return fallback
        case .unmanaged: return nil
        }
    }

    func setGraphicsMode(_ mode: AppGraphicsMode, for app: LinuxApp, in instance: Instance) {
        AppGraphicsStore.set(mode, instance: instance.name, command: app.command)
        graphicsModes = AppGraphicsStore.load()
    }

    /// The GPU needs `virgl_test_server` on the Mac; without it the choice
    /// would silently do nothing, so the menu says so instead.
    /// Both read from disk, so they're not recomputed on every redraw of
    /// every tile - the context menu is built once per tile per refresh.
    var gpuRendererInstalled: Bool { Self.rendererCache.value }
    var gpuIsDefault: Bool { MSLExperimentalSettingsStore.load().gpuAcceleration }

    private static let rendererCache = RendererCache()

    func isPinnedToTop(_ app: LinuxApp, in instance: Instance) -> Bool {
        topPins[instance.name, default: []].contains(app.desktopPath)
    }

    func togglePinToTop(_ app: LinuxApp, in instance: Instance) {
        var pins = topPins[instance.name, default: []]
        if !pins.insert(app.desktopPath).inserted { pins.remove(app.desktopPath) }
        topPins[instance.name] = pins
        UserDefaults.standard.set(topPins.mapValues { Array($0).sorted() }, forKey: Self.topPinsKey)
    }

    static let topPinsKey = "apps.pinnedToTop"

    static func loadTopPins() -> [String: Set<String>] {
        let raw = UserDefaults.standard.dictionary(forKey: topPinsKey) as? [String: [String]] ?? [:]
        return raw.mapValues(Set.init)
    }
}

/// `locateRenderer` stats three paths; once a second is plenty.
private final class RendererCache {
    private var checked = Date.distantPast
    private var cached = false
    var value: Bool {
        if Date().timeIntervalSince(checked) > 1 {
            cached = GPUBridge.locateRenderer() != nil
            checked = Date()
        }
        return cached
    }
}
