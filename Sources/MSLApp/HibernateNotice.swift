import AppKit
import MSLCore

/// The one thing people get wrong about hibernate, said before it happens.
///
/// Hibernate is for **putting an instance away** - it writes the guest's RAM
/// to disk and stops the VM, so the instance survives a Mac restart and
/// costs nothing while it is gone. What it is not is a way to save what you
/// were doing: stopping the VM takes `mslgd` with it, and `mslgd` is the X
/// server every Linux app is drawing into, so their windows cannot come
/// back. MSL reopens the apps, and a browser can be asked to restore its own
/// tabs, but a half-finished drawing is gone.
///
/// A shell is different and does come back exactly as it was - the pty lives
/// in the guest, so only the connection died (`READMES/27`).
///
/// Shown once. Somebody who hibernates often knows what it does by the
/// second time, and an alert that cannot be dismissed for good is a reason
/// to stop using the button rather than to read it.
enum HibernateNotice {

    /// Asks, then calls back with whether to go ahead.
    ///
    /// A **sheet** on the main window rather than a floating alert: this is
    /// about the instance being looked at, so it belongs to that window.
    /// That makes it asynchronous - `beginSheetModal` returns at once - so
    /// the hibernate happens in the callback rather than being gated on a
    /// return value.
    @MainActor
    static func confirm(instance: Instance, then act: @escaping (Bool) -> Void) {
        guard !AppModel.hibernateWarningSilenced else { return act(true) }

        let alert = NSAlert()
        alert.messageText = "Hibernate puts \(instance.name) away - it doesn't save your work"
        alert.informativeText = """
            It writes \(instance.name)'s memory to disk and stops it, so it survives a Mac restart \
            and costs nothing while it's away. Your terminal comes back exactly as it was, \
            mid-command and all.

            Open Linux apps don't. They're closed first, and reopened when you come back - a \
            browser can usually restore its own tabs, but anything unsaved in another app is lost.

            If you're coming back soon, Suspend keeps everything exactly as it is, windows \
            included - and it survives your Mac going to sleep. If you're done, save your work \
            and shut the instance down.
            """
        alert.addButton(withTitle: "Hibernate \(instance.name)")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Suspend Instead")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me again"

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on { AppModel.hibernateWarningSilenced = true }
            switch response {
            case .alertFirstButtonReturn:
                act(true)
            case .alertThirdButtonReturn:
                // Doing the better thing for them, rather than making them
                // go and find the other menu item.
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = DaemonClient.send(.suspend(instance: instance.name), timeout: 60)
                }
                act(false)
            default:
                act(false)
            }
        }

        guard let window = mainWindow else {
            // No window to hang it on - a menu-bar action with everything
            // closed. Better a floating alert than none at all.
            NSApp.activate(ignoringOtherApps: true)
            handle(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handle)
    }

    /// The app's own window, not a panel or a sheet already up.
    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.sheetParent == nil
        }
    }
}
