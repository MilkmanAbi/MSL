import Foundation

/// Experimental settings that apply to **one instance**, over the app-wide ones.
///
/// Installing someone's shipment must not re-configure the receiving Mac, so
/// the settings it carries land here rather than in the global file.
///
/// Stored **sparse** - only the keys that differ from the app-wide value - and
/// that is the whole point. A full snapshot would pin an instance to every
/// switch as it stood on the day the shipment was made, including the ones its
/// author never touched; a later change to an MSL default would then reach
/// every instance except the shipped ones.
///
/// Diffed as JSON rather than by reflecting over the struct: both sides encode
/// with the same `Codable` conformance, so the keys line up for free and a new
/// setting needs no change here.
public enum InstanceExperiments {
    static func url(instance: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("experiments-\(instance).json")
    }

    private static func dictionary(_ settings: MSLExperimentalSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func settings(_ dictionary: [String: Any]) -> MSLExperimentalSettings? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? JSONDecoder().decode(MSLExperimentalSettings.self, from: data)
    }

    /// The overrides recorded for `instance`, if any.
    public static func overrides(instance: String,
                                 appSupport: URL = MSLPaths.appSupport) -> [String: Any] {
        guard let data = try? Data(contentsOf: url(instance: instance, appSupport: appSupport)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// What `instance` should actually run with: the app-wide settings, with
    /// its own overrides on top. The one resolution point - anything doing
    /// work *for an instance* should ask this rather than the global store.
    public static func effective(for instance: String,
                                 appWide: MSLExperimentalSettings = MSLExperimentalSettingsStore.load(),
                                 appSupport: URL = MSLPaths.appSupport) -> MSLExperimentalSettings {
        let extra = overrides(instance: instance, appSupport: appSupport)
        guard !extra.isEmpty else { return appWide }
        var merged = dictionary(appWide)
        for (key, value) in extra { merged[key] = value }
        return settings(merged) ?? appWide
    }

    /// How one setting from a shipment was treated.
    public enum Outcome: Equatable {
        /// Written as an override for this instance.
        case applied(String)
        /// The receiving Mac already agrees, so nothing was written - which is
        /// what keeps the overlay sparse.
        case alreadyMatched(String)
        /// Cannot work here, and why.
        case skipped(String, reason: String)
    }

    /// Records `wanted` as `instance`'s overrides, keeping only what differs
    /// from `appWide` and dropping what this Mac cannot honour.
    ///
    /// Returns an account of every difference, because "best effort" is only
    /// honest if the effort is visible.
    @discardableResult
    public static func apply(_ wanted: MSLExperimentalSettings,
                             to instance: String,
                             appWide: MSLExperimentalSettings = MSLExperimentalSettingsStore.load(),
                             canUseGPU: Bool = GPUBridge.locateRenderer() != nil,
                             appSupport: URL = MSLPaths.appSupport) -> [Outcome] {
        let shipped = dictionary(wanted)
        let local = dictionary(appWide)
        var keep: [String: Any] = [:]
        var outcomes: [Outcome] = []

        for key in shipped.keys.sorted() {
            // Bookkeeping, not a setting: carrying it across would make the
            // receiving Mac think this instance had already been migrated.
            if key == "defaultsGeneration" { continue }
            let shippedValue = shipped[key]
            guard !equal(shippedValue, local[key]) else {
                outcomes.append(.alreadyMatched(key))
                continue
            }
            if key == "gpuAcceleration", (shippedValue as? Bool) == true, !canUseGPU {
                outcomes.append(.skipped(key, reason: "no GPU renderer is installed on this Mac"))
                continue
            }
            keep[key] = shippedValue
            outcomes.append(.applied(key))
        }

        if keep.isEmpty {
            try? FileManager.default.removeItem(at: url(instance: instance, appSupport: appSupport))
        } else if let data = try? JSONSerialization.data(withJSONObject: keep, options: [.sortedKeys]) {
            try? data.write(to: url(instance: instance, appSupport: appSupport))
        }
        return outcomes
    }

    public static func forget(instance: String, appSupport: URL = MSLPaths.appSupport) {
        try? FileManager.default.removeItem(at: url(instance: instance, appSupport: appSupport))
    }

    /// `Any` comparison limited to what `Codable` actually produces here:
    /// booleans, numbers and strings.
    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case let (x as Bool, y as Bool): return x == y
        case let (x as Int, y as Int): return x == y
        case let (x as String, y as String): return x == y
        case let (x as Double, y as Double): return x == y
        case (nil, nil): return true
        default: return false
        }
    }
}
