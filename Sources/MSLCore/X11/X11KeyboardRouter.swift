import AppKit

/// Gets Command-key combinations to the Linux window that has focus.
///
/// AppKit treats anything with Command held as a menu shortcut first
/// (`performKeyEquivalent:`), and only offers it to the view as a
/// `keyDown` if nothing claims it. Worse, it never delivers the matching
/// `keyUp` while Command is held - a long-standing `NSApplication`
/// behaviour - so a Linux app would see Super+C go down and never come up.
///
/// A local event monitor sees every key event before any of that happens.
/// It forwards Command-key events to the focused canvas and consumes them,
/// except for the few shortcuts that belong to the Mac: quitting, hiding,
/// minimizing, cycling windows, and the Emoji & Symbols palette. Those must keep working exactly as in
/// any other app, or the Linux windows stop behaving like Mac windows.
enum X11KeyboardRouter {
    private static var monitor: Any?

    /// Idempotent. Main thread.
    static func installIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.modifierFlags.contains(.command),
                  let view = (event.window ?? NSApp.keyWindow)?.firstResponder as? X11CanvasView,
                  !isReservedForMac(event)
            else { return event }
            view.forwardKey(event, pressed: event.type == .keyDown)
            return nil
        }
    }

    /// Mac window-management shortcuts that stay with macOS.
    static func isReservedForMac(_ event: NSEvent) -> Bool {
        isReservedForMac(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    static func isReservedForMac(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection([.command, .option, .control, .shift])
        // **Control+Command belongs to macOS, whatever the key.** ⌃⌘F is
        // full screen, ⌃⌘Q locks the screen, ⌃⌘Space is the character
        // picker - all system-wide window and session commands with no
        // Linux meaning. Without this the shortcut remapper turned ⌃⌘F into
        // a plain Ctrl+F and full screen stopped working inside Linux
        // windows. Checked before the per-key list so it covers the ones
        // nobody has thought of yet.
        if mods.contains([.command, .control]) { return true }
        switch keyCode {
        case 0x0C: return mods == [.command] // Cmd+Q
        case 0x04: return mods == [.command] || mods == [.command, .option] // Cmd+H, Hide Others
        case 0x2E: return mods == [.command] || mods == [.command, .option] // Cmd+M, Minimize All
        case 0x32: return mods == [.command] || mods == [.command, .shift] // Cmd+` window cycling
        default: return false
        }
    }
}
