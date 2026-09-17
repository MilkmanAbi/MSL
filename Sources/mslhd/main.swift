import Foundation
import MSLCore
import AppKit

let appSupport = NSHomeDirectory() + "/Library/Application Support/MSL"

let registry = InstanceRegistry(path: URL(fileURLWithPath: DaemonProtocol.defaultInstanceRegistryPath()))

// Every instance boots from its distro's own persistent disk image, but
// shares the same kernel/initramfs regardless of distro - see
// `GuestDistro`'s doc comment for why (the kernel doesn't care what
// userspace is on the disk it mounts, same as WSL2's single shared kernel
// across distros on Windows). `disk-Image`/`disk-initramfs-virt` are
// extracted once from Alpine's own kernel build by `provision-disk-image`;
// each distro's own `rootfs*.img` is built by `bootstrap-guest` (Alpine) or
// `bootstrap-distro` (Debian/Ubuntu) - see README's "Guest boot strategy".
// Every instance gets the host's home directory shared in read-write via
// virtiofs, tag "mac_home" - the guest-side mount point is fixed
// (`/mnt/mac`, matching WSL's own `/mnt/c` convention) and wired into
// every distro's fstab so it auto-mounts at boot with no per-session setup
// (see `provision-disk-image`/`bootstrap-distro`). This is the MSL Sandbox's
// macOS-to-Linux direction - see README's "MSL Sandbox" section.
func makeConfiguration(instance: String, distro: GuestDistro) -> VMConfiguration {
    // CPU and memory come from the instance's own `ResourcePolicy` when it
    // has one. An instance nobody has configured gets exactly what it got
    // before this existed - `ResourcePolicy.inherited` resolves to
    // `VMConfiguration.defaultCPUCount()` and `defaultMemorySize()`.
    //
    // In dynamic mode the VM is configured with the *ceiling*: the balloon
    // can only take memory away from the configured size, never add to it,
    // so the ceiling is what has to be booked at boot. `BalloonGovernor`
    // then holds the guest wherever it should actually be.
    let policy = ResourcePolicyStore.load(instance: instance)
    // A custom image brings its own kernel, initramfs, disk and possibly
    // command line (`CustomImage`); a published distro resolves to the
    // shared kernel and its `rootfs*.img`, exactly as before.
    let boot = distro.bootFiles(appSupport: URL(fileURLWithPath: appSupport))
    return VMConfiguration(
        name: instance,
        bootMode: .persistentDisk,
        diskImagePath: boot.disk.path,
        kernelPath: boot.kernel.path,
        initrdPath: boot.initramfs.path,
        cpuCount: policy.resolvedCPUCount(),
        memorySize: policy.resolvedMemory().configuredBytes,
        sharedFolders: [SharedFolder(tag: "mac_home", hostPath: NSHomeDirectory(), readOnly: false)],
        kernelCommandLineOverride: boot.kernelCommandLine,
        diskStorageKey: boot.storageKey
    )
}

/// Unmounts any leftover MSL Sandbox WebDAV mounts under `/Volumes` before
/// this daemon starts accepting connections - best-effort cleanup for a
/// stale mount left behind by a *previous* `mslhd` process that didn't
/// exit cleanly (killed, crashed) rather than going through `hibernate`'s
/// normal `stopFileSandbox` teardown. Without this, a fresh daemon start
/// would mount a NEW WebDAV share for the same instance without ever
/// noticing the old, now-orphaned one still sitting there pointing at a
/// dead server - `NetFSMountURLSync` would just auto-suffix around it
/// (`127.0.0.1-1`, etc.) rather than erroring, so the mess would go
/// unnoticed and accumulate across repeated crashes instead of failing
/// loudly. Every instance binds the same loopback address (see
/// `VMManager.webdavLoopbackAddress`'s doc comment on why), so "starts
/// with /Volumes/127.0.0.1" reliably identifies MSL's own mounts and
/// nothing else a user might have mounted there themselves.
func cleanupStaleWebDAVMounts() {
    let mountProcess = Process()
    mountProcess.executableURL = URL(fileURLWithPath: "/sbin/mount")
    let pipe = Pipe()
    mountProcess.standardOutput = pipe
    guard (try? mountProcess.run()) != nil else { return }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    mountProcess.waitUntilExit()

    for line in output.split(separator: "\n") {
        // Format: "http://127.0.0.1:PORT/ on /Volumes/127.0.0.1 (webdav, ...)"
        guard line.contains("(webdav,"), let onRange = line.range(of: " on ") else { continue }
        let afterOn = line[onRange.upperBound...]
        guard let parenIndex = afterOn.firstIndex(of: "(") else { continue }
        let mountPoint = afterOn[..<parenIndex].trimmingCharacters(in: .whitespaces)
        guard mountPoint.hasPrefix("/Volumes/127.0.0.1") else { continue }

        FileHandle.standardError.write("mslhd: unmounting stale WebDAV mount from a previous run: \(mountPoint)\n".data(using: .utf8)!)
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = ["-f", mountPoint]
        try? umount.run()
        umount.waitUntilExit()
    }
}
cleanupStaleWebDAVMounts()

let server = DaemonServer(registry: registry, makeConfiguration: makeConfiguration(instance:distro:))

// VMManager drives each VM entirely through its own private serial
// DispatchQueue (see VMManager.swift) - it does not need to be called from
// any particular thread. `DaemonServer.run()`'s accept loop is a plain
// blocking `while true`, so it moves to its own thread here, freeing the
// main thread to actually pump a run loop - required for
// `SystemResilienceMonitor` below, whose GCD signal sources (scheduled on
// `.main`) and IOKit power-notification `CFRunLoopSource` (added to
// `CFRunLoopGetMain()`) both need one running to ever fire. Before this
// restructuring, the main thread just blocked in `accept()` forever with
// no run loop at all - fine when there was nothing that needed one, not
// fine now that macOS sleep/shutdown hardening does.
Thread {
    do {
        try server.run()
    } catch {
        FileHandle.standardError.write("mslhd: DaemonServer.run() failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}.start()

let resilience = SystemResilienceMonitor(
    managersSnapshot: { server.allManagers() },
    hostDidWake: { server.hostDidWake() })
resilience.powerTransitionBegan = { server.beginPowerTransition() }
resilience.start()

// Lets `msl power-test <event>` drive the real handlers. Without it, the
// sleep/shutdown/low-battery paths could only ever be exercised by actually
// sleeping or shutting down the machine - which cannot be done from inside
// the process under test, so they would ship having never been executed.
server.onPowerTest = { event in
    switch event {
    case "sleep":
        resilience.respond(.pauseOnly, reason: "power-test sleep")
        return "ran the sleep response"
    case "shutdown", "poweroff", "restart":
        resilience.respond(.pauseAndSave, reason: "power-test shutdown")
        return "ran the shutdown response"
    case "lowbattery":
        resilience.respond(.pauseAndSave, reason: "power-test low battery")
        return "ran the low-battery response"
    case "wake":
        resilience.simulateWake()
        return "ran the wake response"
    case "logout":
        // Posts the real notification rather than calling the handler, so
        // the observer registration itself is what gets tested - a handler
        // that works but was never subscribed would otherwise look fine.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willPowerOffNotification, object: nil)
        return "posted the logout notification"
    case "switchaway":
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        return "posted the fast-user-switch notification"
    case "switchback":
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        return "posted the switch-back notification"
    case "battery":
        // Read-only: reports what the battery watcher sees without acting.
        return resilience.batteryDescription()
    default:
        return "unknown event '\(event)' - try sleep, shutdown, logout, switchaway, switchback, lowbattery, wake or battery"
    }
}

// `NSApplication.shared.run()`, not a bare `RunLoop.main.run()` - confirmed
// live this actually matters, not just style: a plain `CFRunLoop` pumps
// timers/GCD/IOKit sources (everything `SystemResilienceMonitor` needs,
// still fine here - see its own doc comment) but never touches
// `NSApplication`'s own event queue at all. `X11Server`'s windows were
// created and even genuinely appeared on screen without this, but their
// TRAFFIC-LIGHT BUTTONS didn't respond to clicks and drawn content never
// reliably flushed - both need AppKit's real event-fetch-and-dispatch
// loop (`-[NSApplication run]`'s `nextEventMatchingMask`/`sendEvent:`
// cycle) actually running on the main thread, which nothing here ever
// did before. `.accessory` here (not deferred to `X11Server.start()`
// anymore) so every session - GUI or shell-only - gets the exact same
// activation policy from the start; `X11Server.start()`'s own `app.
// activate(ignoringOtherApps:)` still runs later, when a GUI is actually
// first used, to bring its window forward.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
