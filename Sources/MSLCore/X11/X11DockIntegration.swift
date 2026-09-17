import AppKit

/// Makes the Linux windows `mslgd` puts on screen behave like macOS
/// applications rather than like stray floating panels: a real Dock tile
/// carrying the running app's own icon, a real menu bar, a Dock menu
/// listing the open windows, minimized windows that show the app's icon in
/// the Dock, and Mission Control tiles for the windows that should have one
/// (and none for the menus and tooltips that should not).
///
/// **One Dock tile, not one per app.** macOS gives one Dock tile per
/// `NSApplication`, and every X11 client here shares `mslhd`'s single one.
/// So the tile shows whichever Linux app is frontmost, switching as the key
/// window changes, and its menu lists every open window across every
/// client. Per-app tiles would need a helper *process* per X11 connection,
/// which is a real architecture change - `X11Server`'s own doc comment
/// notes `mslhd` owns the only vsock handle Virtualization.framework hands
/// out, so a split needs an SCM_RIGHTS fd handoff first.
///
/// **Policy is switched at runtime, not fixed at launch.** `mslhd` is
/// `.accessory` (`main.swift`) because it is a daemon: a shell-only `msl`
/// session must not put anything in the Dock. The first ordinary top-level
/// X11 window promotes the process to `.regular`, and the last one to close
/// demotes it back, so the Dock tile exists exactly while there is a Linux
/// window to represent.
///
/// Everything here runs on the main thread; callers on a connection thread
/// must hop first (they all already do - every `NSWindow` touch in
/// `X11Connection` is inside a `DispatchQueue.main` block).
final class X11DockIntegration: NSObject {
    static let shared = X11DockIntegration()

    /// Ordinary (non-override-redirect) top-levels that are currently
    /// mapped, oldest first. Drives both the activation policy and the Dock
    /// menu's contents.
    private var openWindows: [(id: UInt32, window: NSWindow)] = []

    /// Guards the single permitted reply to a `.terminateLater` - see
    /// `beginTerminationWatch`. Only ever touched on the main queue.
    fileprivate var hasRepliedToTermination = false

    /// Whether this process is one of the per-app GUI hosts, as opposed to
    /// `mslhd`. `X11AppRouter.spawn` starts the hosts with this flag.
    fileprivate let isPerAppHost = CommandLine.arguments.contains("--msl-app-host")
    private var icons: [UInt32: NSImage] = [:]
    private var names: [UInt32: String] = [:]
    private var menuInstalled = false
    private var isRegular = false

    // MARK: - Window lifecycle

    func windowDidMap(_ windowID: UInt32, window: NSWindow) {
        guard !openWindows.contains(where: { $0.id == windowID }) else { return }
        openWindows.append((windowID, window))
        becomeRegularApp()
        applyIcon(forKeyWindowID: windowID)
    }

    func windowDidUnmap(_ windowID: UInt32) {
        openWindows.removeAll { $0.id == windowID }
        icons.removeValue(forKey: windowID)
        names.removeValue(forKey: windowID)
        if openWindows.isEmpty { resignRegularApp() }
    }

    /// The window's own icon, from `_NET_WM_ICON`. Also becomes its
    /// minimized-in-the-Dock image, which is what actually makes a
    /// minimized Linux window recognizable down there - AppKit's default is
    /// a shrunken screenshot of the window with the *host* app's badge.
    func setIcon(_ icon: NSImage, forWindow windowID: UInt32, window: NSWindow) {
        icons[windowID] = icon
        window.miniwindowImage = icon
        if window.isKeyWindow || openWindows.count == 1 { applyIcon(forKeyWindowID: windowID) }
    }

    /// The app name from `WM_CLASS`, which unlike the title does not change
    /// as the user opens documents - so it is what belongs in the menu bar
    /// and in the Dock menu's grouping.
    func setAppName(_ name: String, forWindow windowID: UInt32) {
        names[windowID] = name
        refreshAppMenuTitle()
    }

    /// Key-window changes retarget the single Dock tile at whichever Linux
    /// app the user is actually working in.
    func keyWindowChanged(to windowID: UInt32) {
        applyIcon(forKeyWindowID: windowID)
        refreshAppMenuTitle()
    }

    // MARK: - Mission Control / window cycling

    /// Override-redirect windows are menus, tooltips and combo dropdowns.
    /// They are `NSWindow`s here because that is the only way to put
    /// borderless content on screen at an exact position, but they are not
    /// *windows* in the sense Mission Control and Cmd-\` mean - showing a
    /// dropdown as its own Mission Control tile, or letting the user tab to
    /// a tooltip, is exactly the "doesn't feel native" tell. `.transient`
    /// keeps them out of Mission Control and Exposé; `.ignoresCycle` keeps
    /// them out of window cycling.
    static func applyCollectionBehavior(to window: NSWindow, overrideRedirect: Bool) {
        if overrideRedirect {
            window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        } else {
            window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        }
    }

    // MARK: - Activation policy

    private func becomeRegularApp() {
        guard !isRegular else { return }
        installMenuIfNeeded()
        // Returns false if AppKit refuses (it does for some transitions);
        // treat the flag as "what actually happened", not "what we asked
        // for", so a refusal doesn't leave us thinking a Dock tile exists.
        isRegular = NSApplication.shared.setActivationPolicy(.regular)
        if isRegular { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private func resignRegularApp() {
        guard isRegular else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.applicationIconImage = nil // back to the process's default
        isRegular = false
    }

    private func applyIcon(forKeyWindowID windowID: UInt32) {
        guard let icon = icons[windowID] else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    // MARK: - Menus

    /// A `.regular` app with no main menu shows an empty menu bar, which
    /// looks broken. This is deliberately minimal - the per-app menus the
    /// project wants later (mirroring a Linux app's own menu bar) hang off
    /// the same structure.
    private func installMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        if NSApplication.shared.delegate == nil { NSApplication.shared.delegate = self }

        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MSL")
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Closes the X11 windows; it does NOT stop `mslhd` itself, which is
        // a daemon other sessions may still be using.
        let closeAll = appMenu.addItem(withTitle: "Close All Windows", action: #selector(closeAllX11Windows), keyEquivalent: "")
        closeAll.target = self // explicit, not responder-chain luck - same as the Dock menu's items
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApplication.shared.mainMenu = mainMenu
        // AppKit maintains this one itself - every titled window that isn't
        // excluded shows up, which is where the popups' own
        // `isExcludedFromWindowsMenu` already pays off.
        NSApplication.shared.windowsMenu = windowMenu
        refreshAppMenuTitle()
    }

    /// The Dock tile's *label* is the process name and cannot be changed
    /// without an app bundle, but the menu bar's leftmost title can - so
    /// the frontmost Linux app at least names itself there.
    private func refreshAppMenuTitle() {
        guard menuInstalled, let appMenu = NSApplication.shared.mainMenu?.item(at: 0)?.submenu else { return }
        let keyID = openWindows.first(where: { $0.window.isKeyWindow })?.id
        let name = keyID.flatMap { names[$0] } ?? names.values.first ?? "MSL"
        appMenu.title = name
        NSApplication.shared.mainMenu?.item(at: 0)?.title = name
    }

    @objc private func closeAllX11Windows() {
        for entry in openWindows { entry.window.performClose(nil) }
    }

    @objc private func bringWindowToFront(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension X11DockIntegration: NSApplicationDelegate {
    /// macOS already puts a FLAT list of the app's window titles at the top
    /// of every Dock menu, so repeating it here would just be a second copy
    /// of the same thing (it was, briefly - two identical blocks in one
    /// menu, confirmed on screen). What that automatic list cannot show is
    /// which Linux APP each window belongs to: "Untitled1" does not say
    /// AbiWord. So this groups the windows under their `WM_CLASS` name,
    /// which is the one thing worth adding - and is the same grouping the
    /// per-app menus planned for later will need.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard openWindows.count > 0 else { return nil }
        let menu = NSMenu()
        var seenApps: [String] = []
        for entry in openWindows {
            let app = names[entry.id] ?? "X11"
            if !seenApps.contains(app) { seenApps.append(app) }
        }
        for app in seenApps {
            let header = NSMenuItem(title: app, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in openWindows where (names[entry.id] ?? "X11") == app {
                let title = entry.window.title.isEmpty ? app : entry.window.title
                let item = NSMenuItem(title: "    " + title, action: #selector(bringWindowToFront(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.window
                menu.addItem(item)
            }
        }
        return menu
    }

    /// The Dock tile represents the Linux WINDOWS, not `mslhd`. Quitting
    /// the process from here would tear down the daemon - and with it the
    /// guest VM and every unrelated `msl` shell session the user has open -
    /// which is not remotely what "quit this app" looks like it should do.
    /// Close the windows instead; the last one going away demotes the
    /// process back to `.accessory` and the tile disappears on its own,
    /// which is the outcome the user was actually asking for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ...but only when it is the *user* asking. macOS asks every running
        // application to quit during a logout, restart or shutdown, and an
        // app that answers `.terminateCancel` cancels the whole thing -
        // the user gets "MSL cancelled the shutdown" and the machine stays
        // up. With one host process per Linux app, that was several
        // processes each independently vetoing every shutdown.
        //
        // The Apple Event carries why it was sent, so a system-initiated
        // quit is distinguishable from Cmd-Q and is always honoured. There
        // is nothing to lose by agreeing: these processes own only the
        // windows. `mslhd` owns the guest, and its own resilience monitor
        // is what freezes and saves it - see `SystemResilienceMonitor`.
        //
        // The quit reason has to be read here and nowhere else:
        // `currentAppleEvent` is only valid for the duration of this call,
        // so the deferred work below cannot ask again.
        guard isSystemInitiatedQuit() else {
            closeAllX11Windows()
            return .terminateCancel
        }

        // Only a per-app host may stall. This delegate is installed by
        // whichever process maps a window first (`installMenuIfNeeded`
        // claims the slot if it is free), and `mslhd` links this same code
        // and runs its own `NSApplication`, so it can end up here too.
        //
        // `mslhd` must never answer `.terminateLater`: it is the process
        // that owns the guest, and `SystemResilienceMonitor.respond` is
        // already freezing and saving every instance on this same main
        // thread. Waiting there would stall that work behind a poll and
        // then hand macOS a "yes, terminate me" partway through a
        // `saveStateForHostPowerEvent`. It agrees immediately instead, and
        // its own SIGTERM path does the rest.
        guard isPerAppHost else { return .terminateNow }

        // Nothing on screen - there is no app to ask and nothing to lose.
        guard !openWindows.isEmpty else { return .terminateNow }

        // Otherwise close them the polite way and give the Linux apps a
        // moment to respond.
        //
        // `closeAllX11Windows` does not actually close anything: each
        // `performClose` reaches `X11Connection.windowShouldClose`, which
        // sends the client a `WM_DELETE_WINDOW` and returns `false`,
        // deliberately leaving the decision to the app. An app with nothing
        // to save destroys the window a round trip later; an app with
        // unsaved work puts up its own "save before closing?" dialog and
        // the window stays. So the window simply *being gone* is the
        // signal, and it can only be read after the guest has had a chance
        // to answer - checking `openWindows` synchronously here would
        // always find them still present and make every app look busy.
        //
        // This must not block: this thread draws those X11 windows and
        // delivers the clicks, so blocking it would freeze the very save
        // dialog being waited on.
        closeAllX11Windows()
        beginTerminationWatch()
        return .terminateLater
    }

    /// Polls until every X11 window has closed, then lets the termination
    /// macOS asked for proceed.
    ///
    /// Bounded, because `.terminateLater` is a promise to answer: an app
    /// that sits on one long enough gets the "MSL prevented shutdown"
    /// dialog, and a forced quit from there is far more dangerous to the
    /// guest filesystem than losing one unsaved document. The budget is
    /// just under the matching grace in `SystemResilienceMonitor`, so in
    /// the normal case this process is gone before the daemon stops waiting
    /// and freezes the guest.
    private func beginTerminationWatch() {
        let deadline = Date().addingTimeInterval(7)
        func poll() {
            // `.terminateLater` must be answered exactly once. Replying
            // twice is undefined, and not replying hangs the shutdown.
            guard !hasRepliedToTermination else { return }
            if openWindows.isEmpty || Date() >= deadline {
                hasRepliedToTermination = true
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
    }


    /// Whether the quit currently being handled came from macOS logging out,
    /// restarting or shutting down, rather than from the user quitting this
    /// app.
    private func isSystemInitiatedQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        // A quit sent as part of a system power transition carries a reason;
        // a plain Cmd-Q carries none.
        guard let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
            return false
        }
        // These constants come in as `OSType` (UInt32); `enumCodeValue` is
        // an OSType too, so compare in that type rather than converting.
        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut),
            OSType(kAEShowRestartDialog), OSType(kAERestart),
            OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
        ]
        return systemReasons.contains(reason)
    }

    /// Clicking the Dock tile with no visible window should bring the Linux
    /// windows back, the same way it reopens a native app's window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        for entry in openWindows { entry.window.deminiaturize(nil) }
        return true
    }
}
