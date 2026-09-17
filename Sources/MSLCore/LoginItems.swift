import Foundation

/// The optional things MSL can start when the user logs in.
///
/// Separate from the daemon's own LaunchAgent (`DaemonClient.installLaunchAgent`,
/// label `com.msl.mslhd`), which is on by default because every instance
/// lives inside it. These two are off by default: opening a terminal or the
/// app at every login is something a user asks for, not something MSL assumes.
///
/// Plain LaunchAgents rather than `SMAppService`, matching the daemon's, so
/// all three show up and behave the same way in System Settings' login items.
public enum LoginItem: String, CaseIterable, Sendable {
    /// Terminal.app, running `msl` against the default instance.
    case terminal
    /// MSL.app.
    case app

    public static let appBundleIdentifier = "com.msl.app"

    public var label: String { "com.msl.login.\(rawValue)" }

    public var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    public var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// `open`, not the binaries directly: `open -a Terminal <executable>` runs
    /// it in a new Terminal window without needing permission to script
    /// Terminal, and `open -b` finds MSL.app wherever it has been moved to.
    public var programArguments: [String] {
        switch self {
        case .terminal: return ["/usr/bin/open", "-a", "Terminal", MSLPaths.tool("msl").path]
        case .app: return ["/usr/bin/open", "-b", Self.appBundleIdentifier]
        }
    }

    public var plist: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    /// Turns the item on or off. Turning it on only writes the plist - launchd
    /// reads it at the next login. Loading it now would run it now (it's
    /// `RunAtLoad`), opening a Terminal window or the app the moment the
    /// switch is flipped.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            let directory = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            else { return false }
            return (try? data.write(to: plistURL, options: .atomic)) != nil
        }
        // Booted out too, in case it was loaded at this login.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        return (try? FileManager.default.removeItem(at: plistURL)) != nil
    }
}
