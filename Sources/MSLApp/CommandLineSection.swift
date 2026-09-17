import AppKit
import MSLCore
import SwiftUI

/// Whether `msl` works in Terminal.app, and the button that makes it work.
///
/// Only the installer package can put `msl` on PATH by itself; an app copied
/// in any other way, or a package install that went wrong, leaves Terminal
/// saying "command not found". This asks for an administrator password once
/// and links `/usr/local/bin/msl` to the copy MSL keeps current in
/// Application Support.
struct CommandLineSection: View {
    @State private var status = CommandLineLink.status()
    @State private var inShellProfiles = ShellPathSetup.isInstalled()
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Command line").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Label(statusText, systemImage: statusSymbol)
                    .foregroundStyle(isReady || inShellProfiles ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !isReady, !inShellProfiles, status != .occupied {
                    Button(working ? "Installing…" : (status == .missing ? "Install msl Command…" : "Repair…")) { install() }
                        .disabled(working)
                }
            }
            Text("Lets you type msl in Terminal.app - msl install debian, msl debian, msl resources. Asks for your password once, because /usr/local/bin belongs to the system.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            status = CommandLineLink.status()
            inShellProfiles = ShellPathSetup.isInstalled()
        }
    }

    private var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private var statusText: String {
        if !isReady, inShellProfiles {
            return "msl is ready in Terminal - MSL added it to your shell profiles (~/.zprofile, ~/.zshrc and bash's)"
        }
        switch status {
        case .ready: return "msl is ready in Terminal"
        case .broken(let target): return "msl is broken: it points at \(target), which isn't there"
        case .occupied: return "Something else is already at /usr/local/bin/msl - MSL has left it alone"
        case .missing: return "msl isn't set up for Terminal yet"
        }
    }

    private var statusSymbol: String {
        isReady || inShellProfiles ? "checkmark.circle" : "exclamationmark.circle"
    }

    /// `do shell script … with administrator privileges` raises the standard
    /// macOS password prompt. Run in-process, so it needs no permission to
    /// script another app.
    private func install() {
        guard FileManager.default.isExecutableFile(atPath: CommandLineLink.preferredTarget) else {
            error = "MSL hasn't finished setting up its tools yet - try again in a moment."
            return
        }
        working = true
        error = nil
        let command = CommandLineLink.installCommand()
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var info: NSDictionary?
        script?.executeAndReturnError(&info)
        working = false
        if let info, (info[NSAppleScript.errorNumber] as? Int) != -128 {
            error = (info[NSAppleScript.errorMessage] as? String) ?? "Couldn't create the link."
        }
        status = CommandLineLink.status()
    }
}
