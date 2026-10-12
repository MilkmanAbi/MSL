import AppKit
import Foundation
import MSLCore

/// The executable inside every generated `~/Applications/MSL/<instance>/
/// <App>.app`. Double-clicking one of those runs *this*, which brings MSL
/// up if it isn't already and then runs the Linux application.
///
/// It takes no arguments: LaunchServices doesn't pass any, and the user
/// isn't typing this. Everything it needs is baked into the bundle's own
/// `Info.plist` by `LinuxAppBundle.generate` under `MSL*` keys, which this
/// reads back out of its own bundle.
///
/// The process stays alive for the whole life of the Linux app - it is the
/// open session that keeps `mslhd` from auto-suspending the VM. That is why
/// the bundle is marked `LSUIElement`: a long-lived process with a normal
/// activation policy would put a *second* Dock tile on screen, next to the
/// per-app `mslgui` tile that the X11 side already creates.

// A bundle has nowhere to print. Everything goes to a per-app log, which
// the app reads back to explain a launch that silently did nothing.
let logURL: URL = {
    MSLPaths.ensureDirectory(MSLPaths.logsDirectory)
    // The bundle's own filename, not `CFBundleName`: the Flatpak and the
    // Snap build of one application deliberately share a display name now,
    // and they must not share a log.
    let name = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    return MSLPaths.logsDirectory.appendingPathComponent("\(name.isEmpty ? "app" : name).log")
}()

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(data)
    } else {
        try? data.write(to: logURL)
    }
}

/// A launch that failed used to end here with a line in a log and nothing
/// on screen - clicking the app in Launchpad "did nothing". The bundle is
/// `LSUIElement`, so it has to become active on its own for the alert to
/// come to the front.
func showFailure(_ message: String) {
    // Called from the background queue that runs the Linux app; AppKit
    // wants this on the main thread, and the caller has to wait for the
    // answer because it exits as soon as this returns.
    if !Thread.isMainThread {
        DispatchQueue.main.sync { showFailure(message) }
        return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Couldn't open \(info("MSLAppName") ?? "the app")"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Show Log")
    if alert.runModal() == .alertSecondButtonReturn {
        NSWorkspace.shared.open(logURL)
    }
}

func info(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
}

guard let instance = info("MSLInstance"),
      let exec = info("MSLExec") else {
    log("this bundle is missing its MSLInstance/MSLExec keys - regenerate it from MSL")
    exit(1)
}
let distro = info("MSLDistro").flatMap(GuestDistro.init(rawValue:)) ?? .alpine
let appName = info("MSLAppName") ?? instance

// Fail closed on an instance that no longer exists. Without this, a stale
// bundle left over from a removed instance would be handed to
// `DaemonServer.manager(for:)`, which registers any name it is given - so
// double-clicking a dead app would silently recreate the instance and
// cold-boot an empty one.
let registry = InstanceRegistry(path: URL(fileURLWithPath: DaemonProtocol.defaultInstanceRegistryPath()))
guard let registeredDistro = registry.distro(for: instance) else {
    log("instance '\(instance)' no longer exists - remove this app, or recreate the instance in MSL")
    showFailure("\(instance) no longer exists. Remove this app, or recreate the instance in MSL.")
    exit(1)
}

/// Opening the app again means "open another one".
///
/// Without a run loop, this process never answered macOS's reopen events.
/// They queued instead, and were delivered when it exited - so clicking an
/// app three times opened one window, and *closing* that window made
/// another one appear, out of nowhere, some time later.
///
/// Answering them by starting a fresh instance is also the behaviour to
/// want: a second click on a Linux app should open a second window, exactly
/// as it would on a Linux desktop. Apps that allow only one instance
/// (Firefox, GNOME's single-instance apps) still say so themselves and
/// simply raise the window they have - that is their decision to make, not
/// MSL's.
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        return true
    }
}

let application = NSApplication.shared
// Accessory, not regular: the X11 side already puts one tile in the Dock
// for this app, and a second would be worse than none. See `LSUIElement`
// in `LinuxAppBundle`.
application.setActivationPolicy(.accessory)
let delegate = LauncherDelegate()
application.delegate = delegate

log("launching \(appName) on \(instance) (\(registeredDistro.rawValue))")
let started = Date()

// The guest app runs off the main thread so the run loop above stays free
// to answer reopen events for this app's whole life.
DispatchQueue.global(qos: .userInitiated).async {
    do {
        let (code, output) = try LinuxAppLauncher.runCapturingOutput(
            instance: instance, distro: registeredDistro == distro ? distro : registeredDistro,
            command: exec, log: log
        )
        if let message = LinuxAppLauncher.failureMessage(
            appName: appName, instance: instance, command: exec,
            exitCode: code, output: output, runTime: Date().timeIntervalSince(started)) {
            showFailure(message)
        }
        exit(code)
    } catch {
        log("launch failed: \(error)")
        showFailure("\(error)")
        exit(1)
    }
}

application.run()
