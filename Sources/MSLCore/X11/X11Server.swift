import Foundation
import AppKit
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 2):
/// `mslgd` - a minimal, from-scratch X11 server, killing the XQuartz
/// dependency `DisplayBridge` (Phase 1) relies on. Real X apps connect
/// (via the guest's `x11tunnel`, same as Phase 1) and get real `NSWindow`s
/// on the macOS desktop, drawn to with CoreGraphics - no X protocol code
/// runs on either the guest or the transport layer; it all lives here.
///
/// This is a fraction of the real X11 core protocol (see the doc's
/// "Priority Request Set" - this implements enough of it to get simple
/// clients like `xdpyinfo`/`xclock`/`xterm` through connection setup and
/// basic window/rectangle drawing, not the whole thing). Extensions
/// (RENDER included) are always reported absent - text will look worse
/// than Phase 1's XQuartz-backed path until RENDER lands. Keyboard input
/// is NOT translated yet (X keysym mapping is real, separate work the doc
/// itself calls out as "the annoying part") - only mouse events are
/// forwarded for this first pass.
///
/// Structurally identical to `DisplayBridge`: a `VZVirtioSocketListener`
/// on its own port (avoids colliding with `DisplayBridge`'s - both can
/// run side by side during development), each accepted connection handed
/// to a background `Thread` immediately (never do blocking work inside
/// the listener delegate callback - see `DisplayBridge`'s doc comment for
/// why). Embedded in `mslhd` for now, same "can move to a standalone
/// process later" caveat the transport doc section makes about Phase 1 -
/// doing that split now would mean building a second SCM_RIGHTS fd-
/// handoff channel (mslhd owns the only handle Virtualization.framework
/// gives out on a VM's vsock device) for no immediate benefit.
public final class X11Server: NSObject {
    private let socketDevice: VZVirtioSocketDevice
    private let port: UInt32

    /// Which instance these connections belong to, so the sandbox's input
    /// gate can be answered per-instance rather than globally - and so it
    /// can be handed to each `mslgui` app host, which otherwise has no idea
    /// which VM it is serving. See `X11InputGate`.
    private let instance: String?
    private var listener: VZVirtioSocketListener?

    /// Shared, server-wide state - every connection's windows/GCs/atoms
    /// live in one flat table (see `X11State`'s doc comment on why
    /// resource IDs don't collide across simultaneously-connected
    /// clients despite that).
    private let state = X11State()

    public init(socketDevice: VZVirtioSocketDevice, port: UInt32, instance: String? = nil) {
        self.socketDevice = socketDevice
        self.port = port
        self.instance = instance
        super.init()
    }

    public func start() {
        DispatchQueue.main.async {
            // `NSApplication.shared` is already fully bootstrapped and
            // actually RUNNING by this point - `mslhd`'s main.swift calls
            // `NSApplication.shared.run()` unconditionally at process
            // startup now (a real Cocoa event loop, not just a bare
            // `RunLoop.main.run()` - see its own doc comment on why that
            // distinction turned out to matter: without it, windows could
            // appear but their traffic-light buttons never responded to
            // clicks and drawn content didn't reliably flush to screen).
            // `.accessory` is set there too. All that's left here is
            // bringing this specific GUI session's window forward -
            // `.accessory` apps don't do that automatically just because
            // a window exists.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: port)
        self.listener = listener
    }

    /// See `DisplayBridge.stop()`'s doc comment on why this doesn't call
    /// `setSocketListener(_:forPort:)` to unregister - the SDK doesn't
    /// accept `nil` here.
    public func stop() {
        listener = nil
        state.closeAllWindows()
    }
}

extension X11Server: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let state = self.state
        let instance = self.instance
        Thread {
            let fd = connection.fileDescriptor
            // Learn WHICH app this is, then hand the whole connection to
            // that app's own process - see `X11AppRouter` for why a second
            // process is the only way to get a second Dock tile out of
            // macOS, and `X11AppIdentity` for why the answer comes from the
            // guest rather than from the X11 stream. Blocks on a socket
            // read, which is why it belongs on this already-spawned thread
            // and not in the listener callback.
            let sniffed = X11AppIdentity.read(fd: fd)
            let isMenuBridge = sniffed.consumed == X11AppIdentity.menuMagic
            // One line per client connecting, never per X11 request:
            // a real GTK app issues thousands a second.
            ActivityLog.shared.record(.display, instance: instance,
                                      isMenuBridge ? "Menu bar bridge connected" : "X11 client connected",
                                      detail: sniffed.appName ?? "unnamed client")
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] route app=\(sniffed.appName ?? "<unnamed>") prefixBytes=\(sniffed.consumed.count)\n".data(using: .utf8)!)
            }
            let started = Date()
            let routed = X11AppRouter.route(fd: fd, appName: sniffed.appName, prefix: sniffed.consumed, instance: instance)
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] route done=\(routed) in \(Int(Date().timeIntervalSince(started) * 1000))ms\n".data(using: .utf8)!)
            }
            if routed {
                // Deliberately NOT `close(fd)` here. `SCM_RIGHTS` gave the
                // host its own descriptor, so this process is done with
                // its copy - but the copy belongs to `connection`
                // (`VZVirtioSocketConnection` owns the descriptor it hands
                // out and closes it when released). Closing it here as well
                // is a double close, and a double close does not merely
                // fail: the number is free the moment the first close
                // returns, so the second one can shut down an unrelated
                // descriptor another thread has just opened. That showed up
                // as tests failing with `XOpenDisplay failed` only when run
                // back to back, never alone. Letting `connection` go out of
                // scope closes it exactly once, right here.
                withExtendedLifetime(connection) {}
                return
            }
            // Routing failed (no host binary next to `mslhd`, a spawn that
            // never came up). Host it here rather than dropping the client
            // on the floor - one shared Dock tile is a far better outcome
            // than a window that never appears.
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] route FAILED - hosting in-process\n".data(using: .utf8)!)
            }
            // A menu bridge is not X11 and has no in-process fallback: its
            // app keeps its own in-window menus when this closes.
            if isMenuBridge {
                withExtendedLifetime(connection) {}
                return
            }
            let clientIndex = state.nextClientIndex()
            X11Connection(fd: fd, clientIndex: clientIndex, state: state, prefix: sniffed.consumed, instance: instance).run()
            withExtendedLifetime(connection) {} // keep the retain alive through the whole session, same reasoning as DisplayBridge
        }.start()
        return true
    }
}
