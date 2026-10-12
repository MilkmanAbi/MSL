import AppKit
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

/// The native macOS surfaces a Finder right-click carries and this browser
/// wants too: the apps that can open a file, the terminals installed on the
/// Mac, and the system share/services for a selection. All AppKit under the
/// hood, kept out of the view so the menu stays declarative.
///
/// It works on ordinary file URLs, which is why it works on a guest file at
/// all: the row's path is the WebDAV-mount path, an actual file the system's
/// own app- and service-lookup can reason about, so "open this Linux file in a
/// Mac app" is just `NSWorkspace` opening a file like any other.
@MainActor
enum FileServices {
    // MARK: Open With

    struct App: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: URL { url }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
        var isDefault = false
    }

    /// The apps that can open this file, default first, de-duplicated by
    /// bundle. Empty for a folder (Finder shows no Open With there either).
    ///
    /// **Cached by file extension**, because the SwiftUI context menu is built
    /// eagerly for every visible row (the codebase relies on this - it's why a
    /// shortcut inside one registers per row), so without the cache a single
    /// redraw of a big folder would fire a LaunchServices query per row. The
    /// app list is a property of the type, not the individual file, so one
    /// entry per extension covers the whole directory.
    static func applications(forOpening url: URL) -> [App] {
        let ext = url.pathExtension.lowercased()
        if let cached = appsByExtension[ext] { return cached }
        let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<URL>()
        let apps: [App] = all.compactMap { appURL in
            guard seen.insert(appURL.standardizedFileURL).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            return App(url: appURL, name: name,
                       isDefault: appURL.standardizedFileURL == defaultURL?.standardizedFileURL)
        }
        // Only cache when there's a real extension to key on; an extensionless
        // file's default app can differ file to file, so it isn't cacheable.
        if !ext.isEmpty { appsByExtension[ext] = apps }
        return apps
    }
    private static var appsByExtension: [String: [App]] = [:]

    /// Opens the given files with a specific app.
    static func open(_ paths: [String], withApp appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(paths.map { URL(fileURLWithPath: $0) },
                                withApplicationAt: appURL, configuration: config)
    }

    /// Finder's "Other…": pick any app from a panel and open with it.
    static func openWithOther(_ paths: [String]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an application to open the selection."
        if panel.runModal() == .OK, let appURL = panel.url {
            open(paths, withApp: appURL)
        }
    }

    // MARK: Terminals

    struct Terminal: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let url: URL
        var id: String { bundleID }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    /// The terminal emulators installed on this Mac, Terminal.app first. Only
    /// the ones actually present are returned, so the submenu never offers a
    /// terminal that isn't there.
    ///
    /// **Computed once and cached** for the same reason `applications` is: the
    /// context menu is built per visible row, and eight LaunchServices bundle
    /// lookups per row per redraw would be exactly the lag this session is
    /// meant to remove. Installing a terminal mid-session and wanting it here
    /// without relaunching is not worth a per-row cost.
    static func installedTerminals() -> [Terminal] {
        if let cached = terminalCache { return cached }
        let result = computeInstalledTerminals()
        terminalCache = result
        return result
    }
    private static var terminalCache: [Terminal]?

    private static func computeInstalledTerminals() -> [Terminal] {
        // Bundle id -> display name, in the order they should appear.
        let known: [(String, String)] = [
            ("com.apple.Terminal", "Terminal"),
            ("com.googlecode.iterm2", "iTerm"),
            ("com.mitchellh.ghostty", "Ghostty"),
            ("dev.warp.Warp-Stable", "Warp"),
            ("com.github.wez.wezterm", "WezTerm"),
            ("net.kovidgoyal.kitty", "kitty"),
            ("org.alacritty", "Alacritty"),
            ("co.zeit.hyper", "Hyper"),
        ]
        return known.compactMap { bundleID, name in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return Terminal(bundleID: bundleID, name: name, url: url)
        }
    }

    /// Opens `directory` in a specific terminal app. `open -a` at a directory
    /// is what every one of these treats as "new terminal here".
    static func openTerminal(_ terminal: Terminal, at directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", terminal.url.path, directory]
        do { try process.run(); return nil }
        catch { return "Couldn't open \(terminal.name). (\(error.localizedDescription))" }
    }

}

// MARK: - Menu views

/// The "Open With ▸" submenu: the default app in bold-ish first, the rest, then
/// Other…. Nothing for a folder or an empty selection.
struct OpenWithMenu: View {
    let item: MSLFileItem
    let targets: Set<String>

    var body: some View {
        let apps = item.isBrowsableDirectory ? [] : FileServices.applications(forOpening: URL(fileURLWithPath: item.path))
        if !apps.isEmpty {
            Menu("Open With") {
                ForEach(apps) { app in
                    Button {
                        FileServices.open(Array(targets), withApp: app.url)
                    } label: {
                        // The icon makes the default obvious at a glance, the
                        // way Finder marks it, without a second "(default)".
                        Label {
                            Text(app.isDefault ? "\(app.name) (default)" : app.name)
                        } icon: {
                            Image(nsImage: app.icon)
                        }
                    }
                }
                Divider()
                Button("Other…") { FileServices.openWithOther(Array(targets)) }
            }
        }
    }
}

/// The "Open in Terminal ▸" submenu: one entry per Mac terminal installed,
/// plus the guest shells the row is reachable from. When only Terminal.app is
/// present it collapses to the single "Open in Terminal" it always was.
struct TerminalMenu: View {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel

    var body: some View {
        let terminals = FileServices.installedTerminals()
        let dir = files.shellDirectory(for: item)
        if terminals.count <= 1 {
            Button("Open in Terminal") { files.openInTerminal(item) }
        } else {
            Menu("Open in Terminal") {
                ForEach(terminals) { terminal in
                    Button {
                        if let error = FileServices.openTerminal(terminal, at: dir) {
                            files.errorMessage = error
                        }
                    } label: {
                        Label { Text(terminal.name) } icon: { Image(nsImage: terminal.icon) }
                    }
                }
            }
        }
    }
}

