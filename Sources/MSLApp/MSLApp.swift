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
    /// Clicking the Dock tile, Launchpad or Spotlight for an app that is
    /// already running does not launch anything - it arrives here. Without
    /// this, MSL was activated with no window at all (see `MSLWindowReopen`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MSLWindowReopen.handleReopen(hasVisibleWindows: flag)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdatePrompt.checkAtLaunch()
        // Only for an unbundled development run. A bundled MSL has a real
        // icon (Assets.car + .icns); setting the raw PNG here replaced it at
        // runtime, and a runtime icon gets no squircle and no dark, clear or
        // tinted variant - the melon sat bare in a tinted Dock.
        guard Bundle.main.bundleURL.pathExtension != "app",
              let url = MSLAsset.url("App_Logo", extension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

struct MSLApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(MSLAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var terminals = TerminalSessions()
    /// `openWindow` is only available inside a scene, so the menu command
    /// reaches it through this rather than an environment lookup.
    @Environment(\.openWindow) private var openWindow
    /// MSL Files is its own app now; this opens it (or, when it isn't
    /// installed, the copy of the browser built into MSL).
    private var openFiles: (() -> Void)? { { MSLFilesLauncher.open { openWindow(id: "files") } } }
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
        // An explicit id, so the reopen path has something to ask for -
        // `openWindow` needs one and the main group had none.
        WindowGroup(id: MSLApp.mainWindowID) {
            RootView()
                .environmentObject(model)
                .environmentObject(terminals)
                .registersForReopen { openWindow(id: MSLApp.mainWindowID) }
                .task { model.start() }
                // Attached out here rather than inside `RootView`, which
                // already carries New Instance's sheet - two `.sheet`
                // modifiers on one view is a SwiftUI coin toss, and that
                // note is repeated three times in `RootView` for a reason.
                // This is a different view node, so both are honoured.
                .sheet(isPresented: $model.showingWelcome) {
                    WelcomeView { model.finishWelcome() }
                }
                // After `model.start()`, so the window has drawn before a
                // sheet slides over it.
                .task { model.showWelcomeIfNeeded() }
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

        // Its own window, because a managed user opens it to find out why
        // something refused them, not as part of configuring anything.
        Window("MSL Admin Portal", id: "adminportal") {
            AdminPortalWindow()
        }
        .defaultSize(width: 680, height: 620)
        .windowResizability(.contentMinSize)

        // Its own window: somebody uninstalling has already decided, and
        // making them find a terminal for it is the software arguing.
        Window("Remove MSL", id: "uninstall") {
            UninstallWindow()
        }
        .defaultSize(width: 680, height: 620)
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
                Button("Welcome to MSL") { model.showingWelcome = true }
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
                Button("Check for Updates…") { UpdatePrompt.checkNow() }
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
                // Tier 3: hiding a window, nothing more. The switches
                // behind it are each gated in the settings store, which is
                // what actually refuses - this only keeps the panel out of
                // the way when a policy says the person has no business
                // in it.
                if MSLAPGate.allows("system.experimental", instance: nil) {
                    Button("Experimental Features") { openWindow(id: "experimental") }
                }
                Button("MSL Admin Portal") { openWindow(id: "adminportal") }
                Divider()
                // Shown even when a policy forbids it, and refused when
                // pressed. Hiding it would leave a managed user hunting
                // for a menu item that is not there; the refusal says who
                // decided and why, which is the whole point of MSLAP.
                Button("Remove MSL…") { openWindow(id: "uninstall") }
            }
            FilesCommands()
        }
    }
}
