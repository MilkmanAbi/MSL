import Foundation
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 1):
/// the host side of MSL's X11-over-vsock GUI tunnel. Listens for the
/// guest's `x11tunnel` (`Guest/init/x11tunnel.c`) dialing *out* to a vsock
/// port - the opposite connection direction from the shell/fileops
/// bridges, where the guest listens and the host connects (see
/// `VMConfiguration.displayVsockPort`'s doc comment for why). For each
/// connection, dials XQuartz's own local X11 socket (`/tmp/.X11-unix/X0`
/// on the HOST - a completely separate path/filesystem from the guest's
/// identically-named one) and relays raw bytes both directions until
/// either side closes. No X11 protocol code here at all - that's the
/// entire point of Phase 1 per the doc: the protocol passes through
/// completely opaque, and XQuartz does all the real X server work.
///
/// Deliberately NOT started automatically with every VM boot - GUI
/// support stays fully opt-in (see `msl gui <instance>`), so every
/// existing shell-only session stays exactly as lean as it already was.
public final class DisplayBridge: NSObject {
    private let socketDevice: VZVirtioSocketDevice
    private let port: UInt32
    private let xquartzSocketPath: String
    private var listener: VZVirtioSocketListener?

    /// `xquartzSocketPath` defaults to X11's own well-known convention,
    /// confirmed live against a real running XQuartz on this machine
    /// (`lsof` showed `X11.bin` holding `/tmp/.X11-unix/X0` open) rather
    /// than assumed from documentation - XQuartz also owns a separate
    /// launchd-activation socket under `/var/run/com.apple.launchd.*/
    /// org.xquartz:0`, which is NOT this: that one's for lazily launching
    /// XQuartz itself when some other app first tries to use it, not a
    /// live X11 protocol endpoint.
    public init(socketDevice: VZVirtioSocketDevice, port: UInt32, xquartzSocketPath: String = "/tmp/.X11-unix/X0") {
        self.socketDevice = socketDevice
        self.port = port
        self.xquartzSocketPath = xquartzSocketPath
        super.init()
    }

    public func start() {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: port)
        self.listener = listener
    }

    /// `setSocketListener(_:forPort:)` doesn't accept `nil` to unset in
    /// this SDK (confirmed at build time: non-optional parameter) - there's
    /// no supported "stop listening on this port" call. Dropping this
    /// object's own reference to the `VZVirtioSocketListener` is the best
    /// available substitute: nothing else retains it, so it deallocates,
    /// and its delegate (this object) won't be invoked again regardless of
    /// whatever the framework's internal port registration still thinks.
    /// In practice this only ever runs alongside the VM itself stopping
    /// (see `stopFileSandbox`'s call site), at which point the whole
    /// `VZVirtioSocketDevice` this was registered against goes away too.
    public func stop() {
        listener = nil
    }
}

extension DisplayBridge: VZVirtioSocketListenerDelegate {
    /// Fires synchronously on Virtualization.framework's own queue for
    /// every guest-initiated connection attempt on `port` - MUST return
    /// fast, no blocking I/O here. Confirmed the hard way earlier in this
    /// project (see the shell-rewrite era's HANDOFF notes): blocking work
    /// called directly inside a `VZVirtioSocketListenerDelegate` callback
    /// hangs the *entire process* indefinitely, not just this connection.
    /// The actual relay work happens on a plain background `Thread`,
    /// started here and immediately returned from.
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let path = xquartzSocketPath
        Thread {
            Self.relay(connection: connection, xquartzSocketPath: path)
        }.start()
        return true
    }

    /// `connection` is captured (and thereby kept alive) for this entire
    /// function's duration - never call `close()` on its `.fileDescriptor`
    /// directly, same rule as `VMManager.openConnections`'s doc comment:
    /// the connection object closes its own fd on deallocation, and a
    /// manual `close()` racing that risks closing an unrelated fd number
    /// reused in the meantime.
    private static func relay(connection: VZVirtioSocketConnection, xquartzSocketPath: String) {
        let vsockFD = connection.fileDescriptor
        guard let localFD = connectToLocalSocket(path: xquartzSocketPath) else {
            return // XQuartz isn't reachable - nothing to relay, just drop.
        }
        defer { close(localFD) }
        pumpBytes(vsockFD, localFD)
        withExtendedLifetime(connection) {} // keep the retain alive through the whole pump, explicit about why
    }

    private static func connectToLocalSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                path.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Raw, opaque byte pump - no framing, no interpretation, mirroring
    /// `Guest/init/x11tunnel.c`'s own `relay()`.
    private static func pumpBytes(_ a: Int32, _ b: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfds = [
                pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                pollfd(fd: b, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&pfds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if pfds[0].revents & Int16(POLLIN) != 0 {
                let n = buf.withUnsafeMutableBytes { read(a, $0.baseAddress, $0.count) }
                if n <= 0 || !writeAll(b, buf, n) { break }
            }
            if pfds[1].revents & Int16(POLLIN) != 0 {
                let n = buf.withUnsafeMutableBytes { read(b, $0.baseAddress, $0.count) }
                if n <= 0 || !writeAll(a, buf, n) { break }
            }
            if pfds[0].revents & Int16(POLLHUP | POLLERR) != 0 { break }
            if pfds[1].revents & Int16(POLLHUP | POLLERR) != 0 { break }
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ count: Int) -> Bool {
        buf.withUnsafeBytes { ptr -> Bool in
            let base = ptr.baseAddress!
            var sent = 0
            while sent < count {
                let n = write(fd, base + sent, count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
