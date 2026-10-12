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
    /// Terminal.app, running `msl run` against the instance you used last.
    case terminal
    /// MSL.app.
    case app

    public static let appBundleIdentifier = "com.msl.app"

    public var label: String { "com.msl.login.\(rawValue)" }

    public var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    public var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// A one-line script rather than the `msl` tool itself.
    ///
    /// `open -a Terminal <file>` runs that file in a new Terminal window
    /// without needing permission to script Terminal - but it takes a file
    /// and no arguments, and plain `msl` prints an overview now rather than
    /// opening a shell (`CLIOverview`). The script is what supplies the
    /// `run`. Written by `setEnabled`, beside nothing else, so it can be
    /// replaced when the tool moves.
    public var loginScriptURL: URL {
        MSLPaths.appSupport.appendingPathComponent("open-at-login.command")
    }

    /// `open`, not the binaries directly: `open -a Terminal <file>` runs it
    /// in a new Terminal window without needing permission to script
    /// Terminal, and `open -b` finds MSL.app wherever it has been moved to.
    public var programArguments: [String] {
        switch self {
        case .terminal: return ["/usr/bin/open", "-a", "Terminal", loginScriptURL.path]
        case .app: return ["/usr/bin/open", "-b", Self.appBundleIdentifier]
        }
    }

    /// The script `.terminal` points at: a shell on the instance you used
    /// last, which is what this login item has always meant.
    var loginScript: String {
        """
        #!/bin/sh
        # Written by MSL when "Open a Terminal at login" is switched on.
        exec \(Self.shellQuoted(MSLPaths.tool("msl").path)) run
        """
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
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
        // Turning startup ON is the restricted direction - a policy that
        // wants MSL running at login means it to stay that way, and
        // turning it off is the safe direction.
        if enabled, !MSLAPGate.allows("system.startup", instance: nil) { return false }
        if enabled {
            let directory = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if self == .terminal {
                try? FileManager.default.createDirectory(
                    at: loginScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? loginScript.write(to: loginScriptURL, atomically: true, encoding: .utf8)) != nil
                else { return false }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: loginScriptURL.path)
            }
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
