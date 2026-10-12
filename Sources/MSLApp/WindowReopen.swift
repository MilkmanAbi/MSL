import AppKit
import MSLCore
import SwiftUI

/// How MSL and MSL Files get a window back after the last one is closed.
///
/// macOS does not quit an app when its last window closes, and clicking its
/// Dock tile (or Launchpad, or Spotlight) sends `applicationShouldHandleReopen`
/// rather than launching anything. A plain SwiftUI `WindowGroup` does **not**
/// answer that on its own: the app is activated, its menu bar appears, and no
/// window is ever made. Measured 2026-09-29 - same pid, same start time, zero
/// windows - which is exactly the "the window shows MSL but the app is
/// basically dead" report.
///
/// There is no API to recreate a closed `WindowGroup` window from outside a
/// view: `NSApp.windows` no longer holds it, and `openWindow` is an
/// environment value. So a window registers the action **while it exists**,
/// and the reopen path calls the one it last saw.
@MainActor
enum MSLWindowReopen {
    private static var open: (() -> Void)?

    /// Called from the root view. Registering on every appearance is
    /// deliberate: the stored action belongs to whichever window is alive
    /// most recently, and one that has gone away is the one not to keep.
    static func register(_ action: @escaping () -> Void) {
        open = action
    }

    /// Makes a window if there is a way to. Returns false when there was
    /// nothing registered - the app has never opened a window this launch,
    /// which the caller may want to report rather than fail silently.
    @discardableResult
    static func reopen() -> Bool {
        guard let open else { return false }
        open()
        return true
    }

    /// Whether any ordinary window is on screen.
    ///
    /// `hasVisibleWindows` cannot be trusted on its own: AppKit counts
    /// panels, the status item's window and SwiftUI's own offscreen helpers,
    /// so it can be `true` with nothing the person can see. Only a window
    /// that is visible, not a panel, and has a real content size counts.
    ///
    /// **A file-dialog window does not count**, and that exclusion matters
    /// more than it looks. A picker belongs to the Linux app that asked for
    /// it, not to MSL Files; treating it as "the app already has a window"
    /// meant a Dock click did nothing while one was up, and - worse - an
    /// arriving `msl-files://` link found no browser to open itself in, so
    /// "open this folder" from Linux silently did nothing.
    static var hasRealWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && !(window is NSPanel)
                && !window.isMSLFilePicker
                && window.contentView != nil
                && window.frame.width > 200 && window.frame.height > 200
        }
    }

    /// The shared `applicationShouldHandleReopen` body. Both apps want the
    /// same thing: if nothing is on screen, put something there.
    static func handleReopen(hasVisibleWindows flag: Bool) -> Bool {
        guard !flag || !hasRealWindow else { return true }
        if !reopen() {
            // Nothing registered: no window has ever existed this launch, so
            // there is nothing to copy. Better to say so in the log than to
            // leave the person with a menu bar and no window and no clue.
            NSLog("[MSL] reopen requested but no window action was registered")
        }
        return true
    }
}

/// Holds the `NSWindow` a SwiftUI view ended up in.
///
/// SwiftUI has no way to ask "which window am I?", and some questions only
/// AppKit can answer - here, whether this view is the hidden prewarmed window
/// that must not swallow a `msl-files://` link.
final class HostWindowBox: ObservableObject {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let box: HostWindowBox

    func makeNSView(context: Context) -> Reader { Reader(box: box) }
    func updateNSView(_ view: Reader, context: Context) {}

    final class Reader: NSView {
        let box: HostWindowBox
        init(box: HostWindowBox) {
            self.box = box
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func viewDidMoveToWindow() { box.window = window }
    }
}

extension View {
    /// Records which window this view is in, into `box`.
    func readsHostWindow(into box: HostWindowBox) -> some View {
        background(HostWindowReader(box: box))
    }

    /// Registers this window as the one to reproduce on reopen.
    func registersForReopen(_ action: @escaping () -> Void) -> some View {
        onAppear { MSLWindowReopen.register(action) }
    }

    /// Marks this window as a Linux app's file dialog: excluded from
    /// `hasRealWindow`, and never restored by macOS.
    func marksAsFilePickerWindow() -> some View {
        background(FilePickerWindowTrait())
    }
}

extension NSWindow {
    static let mslFilePickerIdentifier = NSUserInterfaceItemIdentifier("msl.files.picker")
    static let mslPrewarmedBrowserIdentifier = NSUserInterfaceItemIdentifier("msl.files.prewarmed")

    var isMSLFilePicker: Bool { identifier == Self.mslFilePickerIdentifier }

    /// The window prewarming made and hid, while it is still hidden.
    ///
    /// **It must not consume a `msl-files://` link.** Its `FilesView` is alive
    /// and listening even though nothing is on screen, so "show this folder"
    /// from Linux was taken by the invisible window - and the visible one that
    /// opened a moment later found the link already consumed and sat on the
    /// MSL tab instead ("opened it as if mac side", reported 2026-10-01).
    ///
    /// Identified by tag rather than by asking whether it is visible, because
    /// a window that is legitimately being opened is not on screen yet either,
    /// and would wrongly refuse the link it was opened for. Once this window
    /// is actually shown it stops matching and behaves like any other.
    var isWithdrawnPrewarm: Bool {
        identifier == Self.mslPrewarmedBrowserIdentifier && !isVisible
    }
}

extension View {
    /// Orders this window out once, when the app was started only to be
    /// ready (see `MSLFilesPrewarm.prewarmArgument`).
    ///
    /// **Why not simply not make the window.** SwiftUI always creates a
    /// window for an app's first scene, and there is no way to ask it not
    /// to. Hiding the *application* is not enough either: the moment
    /// anything activates it - a Linux app asking for a file - every hidden
    /// window comes back, so "Save As" put the browser on screen next to the
    /// picker (reported 2026-09-30).
    ///
    /// Ordering the window out leaves it a real, live window that has simply
    /// never been shown, so `MSLWindowReopen` and `openWindow` bring it back
    /// the usual way when someone actually wants it.
    func withdrawsIfPrewarmed() -> some View {
        background(PrewarmWithdraw())
    }
}

private struct PrewarmWithdraw: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        /// **Only the first window of a prewarmed process is withdrawn, ever.**
        ///
        /// `MSLFilesPrewarm.launchedForPrewarm` reads the process's launch
        /// arguments, so it stays true for as long as MSL Files runs - while
        /// `done` below is per-window, because every new window builds a new
        /// Probe. Together those meant that in a prewarmed MSL Files *every*
        /// browser window opened afterwards was ordered straight back out:
        /// a Dock click, ⌘N, a reopen, or a Linux app asking to show a folder
        /// gave a window that flashed and vanished, again and again, until
        /// the app was quit (reported 2026-10-01: "opened as if mac side,
        /// kept crashing over and over... I quit MSL Files and suddenly all
        /// was working" - quitting it ended the prewarmed process, and the
        /// next launch had no prewarm argument).
        ///
        /// One hidden window is the entire point of prewarming; a second one
        /// is someone asking for it.
        private static var didWithdrawFirstWindow = false

        private var done = false

        override func viewDidMoveToWindow() {
            guard !done, MSLFilesPrewarm.launchedForPrewarm, window != nil else { return }
            done = true
            guard !Self.didWithdrawFirstWindow else { return }
            Self.didWithdrawFirstWindow = true
            // Tagged so a `msl-files://` link can tell this window apart
            // while it is off screen - see `NSWindow.isWithdrawnPrewarm`.
            window?.identifier = NSWindow.mslPrewarmedBrowserIdentifier
            // After the current run loop pass: ordering a window out while
            // SwiftUI is still setting it up leaves it in a state where
            // `openWindow` will not bring it back.
            DispatchQueue.main.async { [weak self] in
                self?.window?.orderOut(nil)
            }
        }
    }
}

/// Tags the picker's `NSWindow` and stops macOS restoring it.
///
/// **Why it must not be restorable.** macOS reopens a `Window` scene that was
/// on screen when the app last quit. A file dialog belongs to a Linux app
/// that asked a question once; restored on the next launch it is a window
/// nobody asked for, with nothing to answer - which is exactly the "Choose a
/// file / No file dialog is waiting" window that greeted a Dock click
/// (reported 2026-09-30). `restorationBehavior(.disabled)` would say this in
/// one line, but it is macOS 15 and MSL supports 14, so the flag goes
/// straight onto the window.
private struct FilePickerWindowTrait: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { apply() }
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                window.identifier = NSWindow.mslFilePickerIdentifier
                window.isRestorable = false
            }
        }
    }
}
