import AppKit
#if canImport(Darwin)
import Darwin
#endif

/// The per-application X11 host: one process per Linux app, so each gets
/// its own Dock tile, its own icon, and its own name.
///
/// macOS gives exactly one Dock tile per `NSApplication`, and there is no
/// public API for a second. Hosting every Linux app inside `mslhd` therefore
/// could only ever produce ONE tile - labelled "mslhd", with whichever app
/// was frontmost lending it an icon, apps visibly replacing each other as
/// focus moved. That is what this splits apart.
///
/// The name comes from the executable's FILENAME: an unbundled Mach-O run
/// as `.../Krita` is "Krita" everywhere macOS shows an app name - Dock tile,
/// `NSRunningApplication.localizedName()`, Cmd-Tab (verified directly with a
/// probe binary before any of this was built). So `X11AppRouter` copies this
/// one binary to a per-app name and starts it; this type is what that copy
/// runs.
///
/// It owns a **private** `X11State`: windows, atoms and GCs live per host,
/// which is the point - two apps are now genuinely two X servers' worth of
/// state in two processes. See `X11AppRouter` for what that costs.
public final class X11AppHost {
    private let state = X11State()
    private let socketPath: String
    private let liveConnections = NSCountedSet()
    private let lock = NSLock()
    private var everHadConnection = false

    /// `hostSlot` partitions this host's X11 resource-ID space away from
    /// every other host's - see `X11State.seedClientIndex(hostSlot:)` for
    /// what collides without it.
    public init(socketPath: String, hostSlot: UInt32, instance: String? = nil) {
        self.socketPath = socketPath
        self.instance = instance
        state.seedClientIndex(hostSlot: hostSlot)
    }

    /// Which VM this host serves, for `X11InputGate`. Optional because an
    /// app shim from an older build starts this process without it.
    private let instance: String?

    /// Starts accepting handoffs. Returns immediately; the accept loop runs
    /// on its own thread so the caller can hand the main thread to AppKit.
    public func start() -> Bool {
        guard let listener = X11FDChannel.listen(atSocketPath: socketPath) else { return false }
        Thread { [weak self] in
            while let self {
                guard let handoff = X11FDChannel.accept(on: listener) else { continue }
                self.runConnection(fd: handoff.fd, prefix: handoff.payload)
            }
        }.start()
        // Nothing has connected yet, and something may have gone wrong on
        // the other side - don't sit in the Dock forever if no client ever
        // arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.exitIfIdle()
        }
        return true
    }

    private func runConnection(fd: Int32, prefix: [UInt8]) {
        // The guest's global menu bridge, routed here because it named this
        // app. Not counted as a live connection: menus alone must not keep
        // a host whose windows have all gone.
        if prefix == X11AppIdentity.menuMagic {
            Thread { X11GlobalMenuConnection(fd: fd).run() }.start()
            return
        }
        let state = self.state
        let clientIndex = state.nextClientIndex()
        lock.lock(); liveConnections.add(clientIndex); everHadConnection = true; lock.unlock()
        Thread { [weak self] in
            X11Connection(fd: fd, clientIndex: clientIndex, state: state, prefix: prefix, instance: self?.instance).run()
            guard let self else { return }
            self.lock.lock(); self.liveConnections.remove(clientIndex); self.lock.unlock()
            // A little grace: an app often closes one connection and opens
            // another (Qt does this routinely), and quitting in that gap
            // would take the Dock tile down and lose the windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.exitIfIdle() }
        }.start()
    }

    /// The Dock tile disappearing when the app closes is not decoration -
    /// it is most of what makes it read as an application. A host that
    /// outlived its client would leave a tile with no windows behind it.
    private func exitIfIdle() {
        lock.lock()
        let idle = liveConnections.count == 0
        let hadOne = everHadConnection
        lock.unlock()
        guard idle else { return }
        // A host that never got a client either lost a race with the router
        // or was started in error; either way it should not linger.
        _ = hadOne
        unlink(socketPath)
        exit(0)
    }
}
