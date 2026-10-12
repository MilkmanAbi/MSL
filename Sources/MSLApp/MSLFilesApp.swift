import MSLCore
import SwiftUI

/// MSL Files as its own application: a Dock tile, a Launchpad icon and a
/// Spotlight entry of its own, beside MSL rather than inside it.
///
/// Same executable as MSL - `main.swift` picks this app when the binary runs
/// from `MSL Files.app` (see `MSLFilesIdentity`). It is a client of MSL, not a
/// second copy of it: it reads the live instances from mslhd over the same
/// control socket MSL uses, but never installs tools, writes shell profiles or
/// touches the LaunchAgent. Those stay MSL's job.
struct MSLFilesApp: App {
    static let windowID = "files"
    static let pickWindowID = "pick"

    @NSApplicationDelegateAdaptor(MSLFilesAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    /// Only so the reopen path has something to call - see `MSLWindowReopen`.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // **The browser is declared first, and that is load-bearing.** SwiftUI
        // opens an app's FIRST scene at launch, so with the picker window
        // above this one, clicking the Dock tile got you "Choose a file - no
        // file dialog is waiting" instead of MSL Files (reported 2026-09-30).
        // MSL Files is a file browser that can also act as a dialog, never
        // the other way round.
        //
        // A WindowGroup, not a single Window: ⌘N opens another browser, the
        // way Finder does. Each window has its own `FilesModel`; the instance
        // list is shared.
        WindowGroup("MSL Files", id: MSLFilesApp.windowID) {
            FilesView()
                .environmentObject(model)
                // A prewarm launch wants the app ready, not a window on
                // screen. SwiftUI always builds the first scene's window, so
                // it is put out of sight rather than prevented - and it is
                // still a real window, so a Dock click or a pick brings one
                // back through the usual paths.
                .withdrawsIfPrewarmed()
                .registersForReopen { openWindow(id: MSLFilesApp.windowID) }
                // Whichever window appears first can bring the picker up -
                // at a cold launch the picker window does not exist yet, so
                // it cannot register itself.
                .onAppear {
                    MSLFilesPicks.present = { openWindow(id: MSLFilesApp.pickWindowID) }
                    if MSLFilesPicks.hasPending { MSLFilesPicks.present?() }
                }
                .onReceive(NotificationCenter.default.publisher(for: MSLFilesPicks.didArrive)) { _ in
                    if MSLFilesPicks.hasPending { openWindow(id: MSLFilesApp.pickWindowID) }
                }
                .task { model.start(installsTools: false) }
        }
        .defaultSize(width: 980, height: 640)
        // An EMPTY matching set: this scene never opens a window for an
        // external event. With any non-empty set - and with none at all - a
        // `msl-files://` link arriving while the app was NOT running opened
        // TWO windows: the one every launch creates, and a second one SwiftUI
        // made for the link ("one in the location, one on MSL tab", reported
        // 2026-09-28). The link does not need a window of its own - it is
        // delivered by `MSLFilesAppDelegate.application(_:open:)` and taken by
        // whichever window is ready, so exactly one window launches and it is
        // the one that navigates.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .help) {
                Button("MSL Help") { openInMSL("msl://help") }
            }
            CommandGroup(after: .windowList) {
                Button("Open MSL") { openMSL() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
            FilesCommands()
        }

        // The file dialog: an auxiliary window, opened only when a Linux app
        // is waiting on an answer, and closed again the moment none is.
        //
        // A single window, not a `WindowGroup(for:)`. A value-keyed group is
        // restored on relaunch with **no value**, which left an empty
        // "this dialog has finished" window on screen AND stopped SwiftUI
        // creating the browser window that drains the pending queue - so a
        // cold-launch pick never opened at all. One window sidesteps the
        // whole case; picks queue behind each other, which is what a file
        // dialog does anyway.
        Window("Choose a file", id: MSLFilesApp.pickWindowID) {
            FilePickerHost()
                .environmentObject(model)
                // Not one of the app's own windows, and never restored - see
                // `marksAsFilePickerWindow`.
                .marksAsFilePickerWindow()
                // `openWindow` only exists inside a scene, so the window
                // registers its own way of being brought up - the same
                // trick `MSLWindowReopen` uses for the browser.
                .onAppear {
                    MSLFilesPicks.present = { openWindow(id: MSLFilesApp.pickWindowID) }
                }
                .task { model.start(installsTools: false) }
        }
        .defaultSize(width: 1040, height: 600)
        .handlesExternalEvents(matching: [])
    }

    private func openInMSL(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func openMSL() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.msl.app") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The melon-folder Dock tile, for the same reason `MSLAppDelegate` sets the
/// melon: a development run (no bundle) otherwise gets the blank generic tile.
final class MSLFilesAppDelegate: NSObject, NSApplicationDelegate {
    /// Before any window reads its settings: a separate app means a separate
    /// preferences domain (`com.msl.files`), so the theme, view mode and sort
    /// someone chose while MSL Files lived inside MSL would otherwise vanish on
    /// the first launch of the standalone app. Copied once, never again.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let marker = "files.migratedFromMSL"
        guard !defaults.bool(forKey: marker),
              let old = UserDefaults(suiteName: "com.msl.app")?.dictionaryRepresentation() else { return }
        for (key, value) in old where key.hasPrefix("files.") || key == "MSLFilesShowHidden" {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }

    /// Every `msl-files://` link, taken here rather than by SwiftUI.
    ///
    /// SwiftUI's own URL routing opened **two** windows when a link arrived
    /// while the app was not running: the one every launch creates, and a
    /// second one it made for the link (reported live, 2026-09-28 - "one in
    /// the location, one on MSL tab"). Neither `handlesExternalEvents`
    /// spelling prevented it. An `NSApplicationDelegate` that claims
    /// `application(_:open:)` takes the URL before any of that, so the link
    /// becomes a message to the window that is already opening.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A pick opens its own window and must not be queued as a browser
        // link - a Linux app is blocked waiting for it.
        let picks = urls.compactMap { MSLFilesLink.pickToken(in: $0) }
        for token in picks { MSLFilesPicks.open(token) }
        for url in urls where MSLFilesLink.pickToken(in: url) == nil {
            MSLFilesLink.deliver(url)
        }
        guard picks.isEmpty else { return }

        // **Every browser link gets its own window**, whether or not MSL
        // Files is already open. The three ways in are different things and
        // must not fight over one window: opened from the Dock it is a file
        // browser the person is using; opened from an instance in MSL it is
        // "show me this instance's files", which should not take over
        // whatever they were looking at; and a pick is its own window
        // already, handled above.
        //
        // On a cold launch there is nothing registered to reopen, `reopen()`
        // says so, and the window the launch is already making takes the link
        // on its first appearance - which is why this does not produce the
        // two windows SwiftUI's own URL routing used to.
        MSLWindowReopen.reopen()

        // The safety net. `reopen` may instead revive the window prewarming
        // hid, which has already appeared once and will not appear again, so
        // nothing would consume the link. If it is still sitting there a
        // moment later, give it to whatever is on screen rather than let
        // "show this folder" do nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MSLFilesLink.releaseToAnyWindow()
        }
    }

    /// Same as MSL's: a Dock, Launchpad or Spotlight click on an app that is
    /// already running arrives here, and a `WindowGroup` does not answer it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MSLWindowReopen.handleReopen(hasVisibleWindows: flag)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development runs only - see `MSLAppDelegate`: the bundle's own
        // icon is the one with the system's squircle and appearances.
        guard Bundle.main.bundleURL.pathExtension != "app",
              let url = MSLAsset.url("MSL_Files_Logo", extension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

/// The one place a `msl-files://` link is held between arriving and a window
/// being ready for it.
///
/// A link can arrive before any window exists (a cold launch), so it is kept
/// until a window asks. `pending` is cleared by whoever takes it, so a second
/// window never re-navigates to a link the first one already handled.
@MainActor
enum MSLFilesLink {
    static let didArrive = Notification.Name("MSLFilesLinkDidArrive")
    private static var pending: URL?

    /// A pick request's token, if this URL is one. `msl-files://pick?token=`
    /// opens the file-dialog window rather than a browser.
    static func pickToken(in url: URL) -> String? {
        guard url.host == "pick",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Set while a link is waiting for a window that does not exist yet.
    ///
    /// **A link gets a window of its own.** Opening an instance's files from
    /// MSL used to post this as a broadcast, so whichever window answered
    /// first took it - meaning a second instance's folder hijacked the
    /// window somebody was already working in, and which window that was
    /// depended on the order listeners happened to fire in. Holding the link
    /// for a window that has not appeared yet makes it deterministic: the
    /// new window takes it on first appearance, and windows already on
    /// screen leave it alone.
    private static var wantsOwnWindow = false

    static func deliver(_ url: URL, toNewWindow: Bool = true) {
        pending = url
        wantsOwnWindow = toNewWindow
        // Deliberately no broadcast here when the link wants its own window:
        // posting it would hand the link to a window already on screen,
        // which is the behaviour being fixed.
        if !toNewWindow { NotificationCenter.default.post(name: didArrive, object: nil) }
    }

    /// The link waiting to be handled, if any. Taking it consumes it.
    ///
    /// `firstAppearance` is the window saying it has just come into
    /// existence. A link held for a new window is given only to such a
    /// window; one that is already on screen asking again gets nothing.
    static func take(firstAppearance: Bool = false) -> URL? {
        guard pending != nil else { return nil }
        guard !wantsOwnWindow || firstAppearance else { return nil }
        defer { pending = nil; wantsOwnWindow = false }
        return pending
    }

    /// Hands a link that nobody took to whatever window is on screen.
    ///
    /// The safety net for the one case the rule above cannot cover: when
    /// `reopen()` revives the window prewarming hid rather than making a
    /// new one, that window has already appeared and will not appear again,
    /// so nothing would ever consume the link and "show this folder" would
    /// do nothing at all.
    static func releaseToAnyWindow() {
        guard pending != nil else { return }
        wantsOwnWindow = false
        NotificationCenter.default.post(name: didArrive, object: nil)
    }
}

/// Pick requests arriving before any window exists.
///
/// Same shape as `MSLFilesLink`: a token can land during a cold launch, when
/// there is no view to open a window from, so it waits here until one is.
@MainActor
enum MSLFilesPicks {
    static let didArrive = Notification.Name("MSLFilesPickDidArrive")
    private static var pending: [String] = []

    /// Set by the picker window while it is alive, so a token arriving
    /// later can bring it up. Registered the same way `MSLWindowReopen`
    /// registers the browser: `openWindow` only exists inside a scene.
    static var present: (() -> Void)?

    static func open(_ token: String) {
        pending.append(token)
        present?()
        NotificationCenter.default.post(name: didArrive, object: token)
    }

    /// The next pick to show, if any.
    static func next() -> String? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    static var hasPending: Bool { !pending.isEmpty }
}

/// How MSL opens MSL Files: the separate app when it's installed, the window
/// built into MSL when it isn't (a development run, or a copy of MSL.app moved
/// somewhere on its own).
enum MSLFilesLauncher {
    @MainActor
    static func open(fallback: () -> Void) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MSLFilesIdentity.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            fallback()
        }
    }

    /// Opens MSL Files at a path inside an instance - "Browse Files" on an
    /// instance lands in that instance, not wherever the window last was.
    @MainActor
    static func reveal(instance: String, guestPath: String = "/", fallback: () -> Void) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: MSLFilesIdentity.bundleIdentifier) != nil,
              let url = MSLFilesIdentity.revealURL(instance: instance, guestPath: guestPath, select: false)
        else { return fallback() }
        NSWorkspace.shared.open(url)
    }
}
