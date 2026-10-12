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
    /// Connections accepted but not yet counted in `liveConnections`.
    ///
    /// Without this the idle check could run in the gap between a
    /// successful handoff and the `add` below, and a host would `exit(0)`
    /// holding a descriptor it had just been given - the client on the
    /// other end simply hangs.
    private var pendingHandoffs = 0
    /// Set, under `lock`, once this host has decided to exit: from then on
    /// every handoff is declined rather than accepted and lost.
    private var closing = false
    /// Last time a connection arrived or ended. Exiting needs a full idle
    /// period since then, not merely "no connection at this instant": a
    /// client that reconnects often (xhell does per test; Qt does
    /// routinely) always has instants between connections, and a check
    /// that happened to land in one exited under the next connection.
    private var lastActivity = Date()

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
                // `break`, not `continue`: a listener that has been closed
                // or gone invalid fails every time, and continuing turned
                // that into a host process pinning a core forever with no
                // windows open. `X11Connection.run`'s read loop already
                // breaks on error for the same reason.
                guard let handoff = X11FDChannel.accept(on: listener) else { break }
                // Taken only if this host is not already on its way out.
                // Deciding under the same lock as `exitIfIdle` is what
                // closes the race: either the exit check sees this handoff
                // pending and stays, or this sees `closing` and declines,
                // and the router - getting no ack - starts a fresh host.
                self.lock.lock()
                let declined = self.closing
                if !declined { self.pendingHandoffs += 1; self.lastActivity = Date() }
                self.lock.unlock()
                if declined {
                    close(handoff.fd)
                    close(handoff.control)
                    continue
                }
                X11FDChannel.acknowledge(handoff.control)
                self.runConnection(fd: handoff.fd, prefix: handoff.payload)
            }
        }.start()
        // Nothing has connected yet, and something may have gone wrong on
        // the other side - don't sit in the Dock forever if no client ever
        // arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.exitIfNeverUsed()
        }
        return true
    }

    private func runConnection(fd: Int32, prefix: [UInt8]) {
        // The guest's global menu bridge, routed here because it named this
        // app. Not counted as a live connection: menus alone must not keep
        // a host whose windows have all gone.
        if prefix == X11AppIdentity.menuMagic {
            Thread { X11GlobalMenuConnection(fd: fd).run() }.start()
            lock.lock(); pendingHandoffs -= 1; lock.unlock()
            return
        }
        let state = self.state
        let clientIndex = state.nextClientIndex()
        lock.lock()
        liveConnections.add(clientIndex)
        everHadConnection = true
        pendingHandoffs -= 1
        lock.unlock()
        Thread { [weak self] in
            X11Connection(fd: fd, clientIndex: clientIndex, state: state, prefix: prefix, instance: self?.instance).run()
            guard let self else { return }
            self.lock.lock(); self.liveConnections.remove(clientIndex); self.lastActivity = Date(); self.lock.unlock()
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
        let quiet = Date().timeIntervalSince(lastActivity) >= 2.9
        let idle = liveConnections.count == 0 && pendingHandoffs == 0 && quiet
        if idle { closing = true }
        lock.unlock()
        guard idle else { return }
        unlink(socketPath)
        exit(0)
    }

    /// The startup timer's own check: a host that never got a client
    /// either lost a race with the router or was started in error, and
    /// should not sit in the Dock forever.
    ///
    /// This is what `everHadConnection` was computed for. It used to be
    /// read into a local and thrown away (`_ = hadOne`), so the guard the
    /// comment describes was never actually wired up - which meant the
    /// 20-second timer applied to every host, including one that was
    /// simply between connections at that moment. Qt closes one connection
    /// and opens another routinely.
    private func exitIfNeverUsed() {
        lock.lock()
        let unused = !everHadConnection && liveConnections.count == 0 && pendingHandoffs == 0
        if unused { closing = true }
        lock.unlock()
        guard unused else { return }
        unlink(socketPath)
        exit(0)
    }
}
