import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Routes each accepted X11 connection to the per-application host process
/// that should own it, starting that process the first time an app appears.
///
/// **Why there is a second process at all.** macOS gives one Dock tile per
/// `NSApplication` and offers no way to ask for another. With every Linux
/// app hosted inside `mslhd`, the Dock could only show one tile, named
/// "mslhd", whose icon changed to whichever app was frontmost - apps
/// replacing one another instead of appearing as themselves. Per-app tiles
/// require per-app processes; everything here is the plumbing for that.
///
/// **How an app gets its name.** An unbundled executable is named in the
/// Dock, in `NSRunningApplication.localizedName()` and in Cmd-Tab by its
/// FILENAME - verified with a probe binary before this was built: the same
/// Mach-O copied to `.../Krita` reports as "Krita" everywhere. So the one
/// shared host binary is copied per app, named after the app, and started
/// from that path. No `.app` bundle, no Info.plist. The name itself comes
/// from the guest - see `X11AppIdentity` for why it cannot come from the
/// X11 stream.
///
/// **Grouping is by app, not by connection.** Krita opens several X11
/// connections and several top-level windows; those must be ONE tile, not
/// five. The host is keyed by name and reused, so every connection
/// announcing itself as "Krita" lands in the same process.
///
/// **What this costs.** Each host has its own `X11State`, so atoms and
/// window IDs no longer agree between two different apps, and the
/// cross-connection selection path (`X11Connection.handleConvertSelection`
/// reaching another client through `X11State.connection(forWindow:)`) can
/// only reach clients of the SAME app. Copy/paste between two different
/// Linux apps needs a broker; bridging through `NSPasteboard` is the right
/// one, since it also buys copy/paste with real macOS apps, but it is not
/// built yet.
public enum X11AppRouter {
    /// Where the per-app copies of the host binary and their handoff
    /// sockets live. Under Caches because every file here is reproducible
    /// from the build.
    static var shimDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/MSL/AppShims")
    }

    /// Used when a client never named itself (see `X11AppIdentity`). Such
    /// clients still get a host - just a shared, generically named one -
    /// rather than being handled differently from everything else.
    private static let fallbackName = "Linux App"

    private static let spawnLock = NSLock()

    /// One slot per host process, partitioning the X11 resource-ID space
    /// between them - see `X11State.seedClientIndex(hostSlot:)`. Slot 0 is
    /// reserved for `mslhd`'s own in-process fallback.
    private static var nextHostSlot: UInt32 = 1
    private static var slotsByApp: [String: UInt32] = [:]

    /// Hands `fd` to the right host process, starting one if needed.
    /// Returns `false` if that could not be arranged, so the caller can
    /// fall back to hosting the connection itself.
    public static func route(fd: Int32, appName: String?, prefix: [UInt8], instance: String? = nil) -> Bool {
        let name = appName.flatMap(X11AppIdentity.sanitized) ?? fallbackName
        let socketPath = self.socketPath(forApp: name)

        // Fast path: a host for this app is already up.
        if X11FDChannel.send(fd: fd, payload: prefix, toSocketPath: socketPath) { return true }

        // Serialized so two connections arriving together for the same new
        // app don't each start a host and race for the socket.
        spawnLock.lock()
        defer { spawnLock.unlock() }
        if X11FDChannel.send(fd: fd, payload: prefix, toSocketPath: socketPath) { return true }
        guard let binary = ensureShimBinary(named: name) else { return false }
        // A restarted host keeps the slot it had, so an app that quits and
        // reopens doesn't consume slots without bound.
        let slot = slotsByApp[name] ?? {
            let assigned = nextHostSlot
            nextHostSlot += 1
            slotsByApp[name] = assigned
            return assigned
        }()
        guard spawn(binary: binary, socketPath: socketPath, hostSlot: slot, instance: instance) else { return false }

        // The host has to bind its socket before it can be handed anything.
        for _ in 0..<100 {
            usleep(50_000) // 50ms, up to 5s
            if X11FDChannel.send(fd: fd, payload: prefix, toSocketPath: socketPath) { return true }
        }
        return false
    }

    static func socketPath(forApp name: String) -> String {
        (shimDirectory as NSString).appendingPathComponent("\(name).sock")
    }

    /// Copies the shared host binary to a path named after the app, which
    /// is what actually gives the process its user-visible name. Re-copied
    /// whenever the build's binary is newer, so a rebuild doesn't leave
    /// stale hosts behind.
    private static func ensureShimBinary(named name: String) -> String? {
        let fileManager = FileManager.default
        guard let source = hostBinaryPath, fileManager.isExecutableFile(atPath: source) else { return nil }
        try? fileManager.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
        let destination = (shimDirectory as NSString).appendingPathComponent(name)

        let sourceAttributes = try? fileManager.attributesOfItem(atPath: source)
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination)
        let sourceDate = sourceAttributes?[.modificationDate] as? Date
        let destinationDate = destinationAttributes?[.modificationDate] as? Date
        if destinationAttributes == nil || sourceDate == nil || destinationDate == nil
            || sourceDate! > destinationDate! {
            try? fileManager.removeItem(atPath: destination) // replace, never overwrite a running image
            do { try fileManager.copyItem(atPath: source, toPath: destination) } catch { return nil }
            // An ad-hoc signature: a copied Mach-O keeps the original's,
            // which no longer matches its own contents/path, and macOS
            // refuses to run it. Re-signing is not optional here.
            guard adhocSign(destination) else { return nil }
        }
        return destination
    }

    /// The shared host binary, built alongside `mslhd` and living beside it.
    private static var hostBinaryPath: String? {
        guard let executable = Bundle.main.executablePath else { return nil }
        let directory = (executable as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("mslgui")
    }

    private static func adhocSign(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `posix_spawn` rather than `Process` so the child inherits this
    /// process's environment and stderr as-is - `MSL_X11_TRACE` and
    /// `MSL_X11_SNAPSHOT_DIR` have to reach the host, or tracing and the
    /// whole snapshot test harness go dark the moment windows move out of
    /// `mslhd`.
    private static func spawn(binary: String, socketPath: String, hostSlot: UInt32, instance: String? = nil) -> Bool {
        // `--instance` is appended, never inserted: an app shim copied to
        // the cache by an older build is still started by this code, and a
        // host that does not understand the flag must not be handed a
        // shifted argv. The receiving side treats it as optional for the
        // same reason.
        var arguments = [binary, "--msl-app-host", socketPath, "--host-slot", String(hostSlot)]
        if let instance { arguments += ["--instance", instance] }
        var pid: pid_t = 0
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer { for pointer in cArguments where pointer != nil { free(pointer) } }
        let result = posix_spawn(&pid, binary, nil, nil, &cArguments, environ)
        return result == 0
    }
}
