import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Keeps MSL Files running, hidden, so it can answer a Linux app's file
/// dialog immediately.
///
/// **Why this exists.** A Linux app asking for a file blocks its own main
/// process on the D-Bus reply. If MSL Files has to launch cold at that
/// moment, the several seconds it takes are several seconds the app is
/// frozen - and Firefox does not survive them: its IPC to its child
/// processes times out and it quits with "Exiting due to channel error"
/// (measured 2026-09-29). Starting MSL Files when an instance starts turns a
/// cold launch into a window that is already there.
///
/// Launched **hidden and without activating**: nothing comes to the front,
/// no window appears, and whatever the person was doing is undisturbed. It
/// is an ordinary app afterwards - clicking its Dock tile shows its browser
/// window like any other launch.
///
/// Gated on the same setting as the rest of the integration: with "MSL Files
/// handles folders and file dialogs" off, nothing is started, because nothing
/// would ask it anything.
public enum MSLFilesPrewarm {
    /// Passed to MSL Files when MSL starts it for readiness rather than
    /// because someone asked for it.
    ///
    /// It is a *launch* argument, so it only reaches a cold start - which is
    /// exactly the case it is for. An app already running was started by
    /// someone, and keeps whatever windows they opened.
    public static let prewarmArgument = "--msl-prewarm"

    /// Whether this process was started to sit ready, with no window wanted.
    public static var launchedForPrewarm: Bool {
        CommandLine.arguments.contains(prewarmArgument)
    }

    /// Starts MSL Files hidden if it is not already running. Cheap and safe
    /// to call repeatedly - a start when it is already up is skipped.
    public static func ensureReady(settings: MSLExperimentalSettings = MSLExperimentalSettingsStore.load()) {
#if canImport(AppKit)
        guard settings.preferMSLFiles else { return }
        // Never block the caller. `mslhd`'s main thread serves the X11
        // bridge, and LaunchServices calls on it have frozen every Linux app
        // three separate times - see `HostOpenService`'s `.pick` case.
        DispatchQueue.main.async {
            guard !isRunning else { return }
            guard let app = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: MSLFilesIdentity.bundleIdentifier)
            else { return }   // not installed; a pick will decline and the app uses its own dialog
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            // Tells MSL Files this launch is nobody asking for a window.
            // Without it, the browser window SwiftUI makes for the first
            // scene comes up alongside the picker the moment a Linux app
            // asks for a file - so "Save As" opened two windows, one of
            // which nobody wanted.
            configuration.arguments = [Self.prewarmArgument]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
#endif
    }

    /// Whether MSL Files is up. Also the answer to "will a pick be fast?".
    public static var isRunning: Bool {
#if canImport(AppKit)
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: MSLFilesIdentity.bundleIdentifier)
            .isEmpty
#else
        false
#endif
    }
}
