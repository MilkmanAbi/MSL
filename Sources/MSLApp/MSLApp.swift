import MSLCore
import SwiftUI

/// Sets the Dock tile to the melon.
///
/// `CFBundleIconFile` in the built app already does this, but only for the
/// built app - running the executable directly during development gets the
/// blank generic tile, and so does any launch before `build-app.sh` has run.
/// Setting it here means the logo follows the process rather than the bundle,
/// so MSL looks like MSL everywhere it can be started from.
///
/// This is MSL's own tile only. Each Linux app gets its own process and keeps
/// its own icon - a GIMP window showing a melon in the Dock would lose exactly
/// the thing the per-app split was built for.
final class MSLAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = MSLAsset.url("App_Logo", extension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

@main
struct MSLApp: App {
    @NSApplicationDelegateAdaptor(MSLAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var terminals = TerminalSessions()
    /// `openWindow` is only available inside a scene, so the menu command
    /// reaches it through this rather than an environment lookup.
    @Environment(\.openWindow) private var openWindow
    private var openFiles: (() -> Void)? { { openWindow(id: "files") } }
    private var openAbout: (() -> Void)? { { openWindow(id: "about") } }
    private var openHelp: (() -> Void)? { { openWindow(id: "help") } }

    /// Opens the guide at an article - the window is shared, so this is how a
    /// menu item says where it should land.
    @MainActor private func openHelp(at article: String) {
        HelpNavigator.shared.search = ""
        HelpNavigator.shared.open(article)
        openHelp?()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(terminals)
                .task { model.start() }
                // A shell session is what keeps an instance awake, so a
                // session left open against an instance that has been
                // removed is a leak with teeth.
                .onChange(of: model.instances) { _, instances in
                    terminals.prune(keeping: Set(instances.map(\.name)))
                }
        }
        .defaultSize(width: 1040, height: 680)

        // A separate window rather than a fifth tab: browsing files is a
        // side-by-side activity - the point is moving things between the
        // Mac and a guest - and a tab inside one instance's page is the
        // wrong shape for something that spans all of them.
        Window("MSL Files", id: "files") {
            FilesView()
                .environmentObject(model)
                .task { model.start() }
        }
        .defaultSize(width: 940, height: 620)
        // `msl://files?...` - a Linux app asking to show a folder, sent by
        // mslhd's HostOpenService.
        .handlesExternalEvents(matching: ["msl://files"])

        // A window, not a sheet: the Licence section is the full GPL, and
        // nobody can read that in a fixed 400x380 panel that cannot be
        // resized or left open beside the app.
        Window("About MSL", id: "about") {
            AboutView()
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)

        // A window rather than a popover: granting permissions sends people
        // to System Settings and back, and a popover closes the moment focus
        // leaves it - it also looked cramped and lost against a full-screen
        // MSL window.
        Window("Permissions & Startup", id: "permissions") {
            PermissionsAndStartupWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 520, height: 680)
        .windowResizability(.contentMinSize)

        // Every experiment MSL has, in its own window rather than hidden in
        // a settings tab - they may be folded in or removed later, and the
        // window says so.
        Window("Experimental Features", id: "experimental") {
            ExperimentalFeaturesWindow()
        }
        .defaultSize(width: 560, height: 720)
        .windowResizability(.contentMinSize)

        // A window of its own, like the About panel: a guide is something
        // people keep open beside the thing it explains.
        Window("MSL Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 1060, height: 740)
        // `msl --help` in a terminal opens this after printing its own help.
        .handlesExternalEvents(matching: ["msl://help"])
        .windowResizability(.contentMinSize)

        .commands {
            // Replaces "Help isn't available for MSL". macOS keeps its own
            // menu-search field at the top of this menu regardless.
            CommandGroup(replacing: .help) {
                // No ⌘? - SwiftUI drops a shortcut whose key needs Shift, and
                // ⇧⌘? already opens this menu system-wide (checked through
                // the accessibility tree: the item carried no key at all).
                Button("MSL Help") { openHelp?() }
                Button("Getting Started") { openHelp(at: "install-distro") }
                Button("Keyboard Shortcuts") { openHelp(at: "shortcuts") }
                Button("Troubleshooting") { openHelp(at: "trouble-wont-start") }
                Button("What's Ready, What's Experimental") { openHelp(at: "whats-ready") }
                Divider()
                Link("MSL on GitHub", destination: URL(string: "https://github.com/MilkmanAbi/MSL")!)
            }
            // The default About panel can't be extended, and MSL's has
            // things worth saying (what it is, what's experimental).
            CommandGroup(replacing: .appInfo) {
                Button("About MSL") { openAbout?() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Instance…") { model.showingNewInstance = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .windowList) {
                // ⌥⌘F, not ⇧⌘F: inside the browser ⇧⌘F is Finder's "Go to
                // Recents", and matching Finder there matters more than
                // keeping this one shortcut.
                Button("MSL Files") { openFiles?() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Experimental Features") { openWindow(id: "experimental") }
            }
            FilesCommands()
        }
    }
}
