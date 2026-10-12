import Foundation

/// The handshake between mslhd and a root USB helper.
///
/// mslhd runs as the user (it is a LaunchAgent), so it cannot capture a
/// device macOS already has a driver for -
/// `IOUSBHostObjectInitOptionsDeviceCapture` wants the restricted
/// `com.apple.vm.device-access` entitlement *or* root, and the entitlement
/// cannot be had: ad-hoc signing it gets the process SIGKILLed at exec.
///
/// So the capture happens in a short-lived `msl-usbd` run under `sudo`,
/// which serves USB/IP down a Unix socket; mslhd pumps that to the guest's
/// vsock. mslhd stays the owner of the guest connection, which is what
/// keeps the idle guards, the suspend survival and the stop/hibernate
/// teardown all working - see `USBBridge.Pending`.
///
/// **No fd is passed through `sudo`.** `sudo` closes inherited descriptors
/// above stderr, so the helper is handed a *path* and dials it itself.
public final class USBRootRelay {
    /// Where the one-shot sockets live. 0700, so only this user can reach a
    /// socket that leads to a guest's USB bus.
    public static var directory: URL { MSLPaths.appSupport.appendingPathComponent("usb") }

    public let path: String
    private let listenFD: Int32

    /// Opens a listener nothing has connected to yet.
    ///
    /// The name is random rather than derived from the device: two attaches
    /// of the same device in quick succession must not collide on one
    /// socket, and a predictable path in a shared directory is something to
    /// avoid on principle even inside a 0700 one.
    public init?() {
        let directory = Self.directory
        guard MSLPaths.ensureDirectory(directory) else { return nil }
        // Tightened explicitly rather than trusting the umask.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        let name = "relay-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let url = directory.appendingPathComponent(name)
        // A local copy for the rest of this initialiser: `self.path` is set,
        // but referring to it inside a closure before every member has a
        // value is not allowed.
        let socketPath = url.path
        self.path = socketPath
        try? FileManager.default.removeItem(at: url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard socketPath.utf8.count <= limit else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: limit + 1) { buffer in
                _ = strncpy(buffer, socketPath, limit)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // 0600 on the socket itself as well: the directory is the real
        // boundary, but a socket that hands out a guest's USB bus should not
        // rely on only one of them.
        chmod(socketPath, 0o600)
        self.listenFD = fd
    }

    /// Waits for the helper, and returns its connected socket only if root
    /// is on the other end.
    ///
    /// The uid check is the point. Without it, any process this user can run
    /// could dial the socket and pretend to be a captured device - which is
    /// a way to feed arbitrary USB traffic into a guest, and the whole
    /// reason the privileged half is a separate program in the first place.
    ///
    /// Returns nil on timeout, so a `sudo` prompt the person walks away from
    /// cannot leave a listener and a queue entry behind for ever.
    public func waitForHelper(timeout: TimeInterval = 120) -> Int32? {
        defer { stop() }
        var poller = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            let ready = poll(&poller, 1, min(remaining, 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return nil
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == 0 else {
                close(client)
                // Not root: whoever that was does not get another try on
                // this socket.
                return nil
            }
            return client
        }
        return nil
    }

    public func stop() {
        close(listenFD)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Deletes handshake sockets belonging to a dead `mslhd`.
    ///
    /// The name carries the pid of the process that listened on it, so
    /// "not mine" is the same as "nobody's": a relay socket cannot outlive
    /// its listener. Anything left over is from a daemon that was restarted
    /// while an attach sat at a password prompt.
    public static func removeOrphanedSockets() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let mine = "relay-\(getpid())-"
        for name in names where name.hasPrefix("relay-") && name.hasSuffix(".sock") {
            guard !name.hasPrefix(mine) else { continue }
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Connects to one of these, from the helper's side.
    public static func connect(to path: String) -> Int32? {
        GPUBridge.connect(toUnixSocket: path)
    }
}
