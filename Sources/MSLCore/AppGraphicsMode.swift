import Foundation

/// Where one Linux app's OpenGL runs, chosen per app from its right-click
/// menu in the Applications tab.
///
/// The two renderers are a real trade-off, not a faster/slower dial: the
/// Mac's GPU (`virpipe` → virglrenderer → Metal) tops out at **OpenGL 4.1**,
/// while the guest's CPU (llvmpipe) is slower but offers **OpenGL 4.5**.
/// Blender wants 4.3 and says "Unsupported hardware" on the GPU; a game
/// that stays at 4.1 flies on it. One global switch in Experimental
/// Features meant flipping it back and forth per app, so each app can now
/// keep its own answer.
public enum AppGraphicsMode: String, Codable, CaseIterable, Sendable {
    /// Whatever the Experimental Features GPU switch says.
    case automatic
    case gpu
    case cpu

    public var title: String {
        switch self {
        case .automatic: return "Default"
        case .gpu: return "GPU — Mac graphics (OpenGL 4.1)"
        case .cpu: return "CPU — software (OpenGL 4.5)"
        }
    }

    public var shortLabel: String? {
        switch self {
        case .automatic: return nil
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        }
    }

    /// Whether an app in this mode renders on the Mac's GPU, given the
    /// global switch and whether a renderer is installed at all.
    public func usesGPU(globalSwitch: Bool, rendererInstalled: Bool) -> Bool {
        guard rendererInstalled else { return false }
        switch self {
        case .automatic: return globalSwitch
        case .gpu: return true
        case .cpu: return false
        }
    }
}

/// Per-app graphics choices, in one small JSON file shared by everything
/// that launches apps: MSL.app, the generated app bundles' launcher and
/// `msl gui-native`. Keyed by instance and the app's command - the launch
/// paths only ever see the command, and it is what identifies the app there.
public enum AppGraphicsStore {
    static var fileURL: URL { MSLPaths.appSupport.appendingPathComponent("app-graphics.json") }

    public static func key(instance: String, command: String) -> String {
        instance + "\u{1F}" + command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load() -> [String: AppGraphicsMode] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        // Unknown values (a newer build's modes) are dropped, not fatal.
        return raw.compactMapValues(AppGraphicsMode.init(rawValue:))
    }

    public static func mode(instance: String, command: String) -> AppGraphicsMode {
        load()[key(instance: instance, command: command)] ?? .automatic
    }

    public static func set(_ mode: AppGraphicsMode, instance: String, command: String) {
        guard MSLAPGate.allows("graphics.perApp", instance: instance) else { return }
        var all = load()
        let key = key(instance: instance, command: command)
        if mode == .automatic { all.removeValue(forKey: key) } else { all[key] = mode }
        _ = MSLPaths.ensureDirectory(MSLPaths.appSupport)
        if let data = try? JSONEncoder().encode(all.mapValues(\.rawValue)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
