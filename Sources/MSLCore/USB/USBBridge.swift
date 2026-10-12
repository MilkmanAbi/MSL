import Foundation
import Virtualization

/// USB devices from the Mac, inside a Linux guest.
///
/// ```
/// Mac USB device → IOUSBHost (HostUSBDevice) → USBIPServer
///   → vsock 5012 → [guest] msl-usbattach → /sys/.../vhci_hcd.0/attach
///   → the guest's own USB stack
/// ```
///
/// Nothing here emulates a controller and the guest needs no MSL driver:
/// `vhci_hcd` and `usbip_core` are in every image MSL ships, and USB/IP is
/// a kernel feature from 2008. The Mac side is a plain userspace server.
///
/// **Attachment is always host-initiated.** The Mac decides which device
/// goes to which guest, then tells the guest to connect back - so a
/// connection arriving on this port is always the answer to a request MSL
/// just made. That is why pairing is a queue rather than a handshake:
/// `vhci_hcd` expects a pure USB/IP stream from the first byte and would
/// read any identifying preamble as a URB header.
public final class USBBridge: NSObject {
    /// One port for the subsystem, one connection per device - the same
    /// shape as `PeripheralBridge` (5010) and `GPUBridge` (5011).
    public static let vsockPort: UInt32 = 5012

    /// How the next guest connection gets served.
    ///
    /// Two tiers, because macOS decides which one a device needs. A device
    /// nothing on the Mac has claimed, mslhd opens and serves itself. A
    /// device macOS has a driver for has to be captured by a root helper -
    /// and that helper serves USB/IP down a Unix socket which mslhd then
    /// **pumps** to the guest's vsock.
    ///
    /// The relay is what keeps the root helper out of the guest's business.
    /// If it took the guest's connection directly, mslhd would not know an
    /// attachment existed: the idle guards would pause and then hibernate
    /// the guest underneath it, and nothing would close the helper's socket
    /// when the guest stopped, leaving the device captured and stranded.
    /// Relaying means every guard, the suspend survival and the teardown
    /// all keep working unchanged, and the helper simply reads EOF and
    /// releases the device.
    private enum Pending {
        case serve(USBIPDeviceBackend)
        case relay(fd: Int32, attachment: USBAttachment, speed: UInt32)

        var attachment: USBAttachment {
            switch self {
            case .serve(let backend):
                return USBAttachment(device: backend.deviceToken, displayName: backend.displayName,
                                     captured: false)
            case .relay(_, let attachment, _): return attachment
            }
        }

        var speed: UInt32 {
            switch self {
            case .serve(let backend): return backend.linkSpeed
            case .relay(_, _, let speed): return speed
            }
        }
    }

    /// A live attachment, so the Mac side can say what a guest is holding
    /// and take it back again.
    private final class Live {
        let attachment: USBAttachment
        /// Set for the native tier.
        let server: USBIPServer?
        /// Set for the relay tier - closing it ends the pump and makes the
        /// root helper exit.
        let relayFD: Int32?
        /// The guest's side of the relay.
        ///
        /// Kept so a detach can `shutdown` it. **`shutdown` is what works
        /// here, not `close`**: the serving side runs on a `dup`, and
        /// closing one descriptor leaves the socket open, while `shutdown`
        /// acts on the socket itself however many descriptors share it.
        /// That is why the native tier already detached cleanly -
        /// `USBIPServer.stop()` shuts down - and the relay tier did not: it
        /// only ended the *helper's* end, so `vhci_hcd` went on listing the
        /// device in `VDEV_ST_USED` with nothing behind it (measured).
        let guestFD: Int32
        let connection: VZVirtioSocketConnection
        init(attachment: USBAttachment, server: USBIPServer?, relayFD: Int32?,
             guestFD: Int32, connection: VZVirtioSocketConnection) {
            self.attachment = attachment
            self.server = server
            self.relayFD = relayFD
            self.guestFD = guestFD
            self.connection = connection
        }
    }

    private let socketDevice: VZVirtioSocketDevice
    private let instance: String
    private var listener: VZVirtioSocketListener?
    /// Devices promised to the guest and not yet collected, oldest first.
    private var queue: [Pending] = []
    /// Live attachments, so `stop()` can end them and hand every captured
    /// device back to macOS.
    private var live: [Live] = []
    private let lock = NSLock()

    public init(socketDevice: VZVirtioSocketDevice, instance: String) {
        self.socketDevice = socketDevice
        self.instance = instance
        super.init()
    }

    public func start() {
        // Sockets left by a previous mslhd are garbage by definition - no
        // relay can outlive the process that was listening on it - and
        // without this they pile up every time the daemon is restarted
        // while an attach is waiting for a password.
        USBRootRelay.removeOrphanedSockets()
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
        self.listener = listener
    }

    public func stop() {
        listener = nil
        lock.lock()
        let attached = live
        let waiting = queue
        live.removeAll()
        queue.removeAll()
        lock.unlock()
        // Ending a server tears its backend down, which resets a captured
        // device and lets macOS's drivers match it again. Without this a
        // guest shutting down would leave the device belonging to nobody
        // until it was physically unplugged.
        for entry in attached { end(entry) }
        for pending in waiting { discard(pending) }
    }

    /// Ends an attachment without closing anything.
    ///
    /// Only `shutdown`, deliberately: the threads below own the
    /// descriptors and close them when their loop returns. Closing here as
    /// well would be a double close, and the second one lands on whatever
    /// descriptor the process has opened since.
    private func end(_ entry: Live) {
        entry.server?.stop()
        // The guest's end, so `vhci_hcd` sees the socket go and detaches
        // its port.
        shutdown(entry.guestFD, SHUT_RDWR)
        entry.connection.close()
        // The helper's end: it reads EOF, `destroy()`s the device - which
        // resets it and lets macOS match its drivers again - and exits.
        if let fd = entry.relayFD { shutdown(fd, SHUT_RDWR) }
    }

    private func discard(_ pending: Pending) {
        switch pending {
        case .serve(let backend): backend.teardown()
        case .relay(let fd, _, _): shutdown(fd, SHUT_RDWR); close(fd)
        }
    }

    /// Promises a device to the next guest connection, and returns the
    /// speed the guest must attach it at.
    ///
    /// The caller is responsible for actually telling the guest to connect
    /// (`USBBridge.attachCommand`); until it does, the device sits in the
    /// queue holding its claim on the hardware.
    public func enqueue(_ backend: USBIPDeviceBackend) -> UInt32 {
        lock.lock()
        queue.append(.serve(backend))
        lock.unlock()
        log("\(backend.displayName) is waiting for the guest")
        return backend.linkSpeed
    }

    /// Promises a device a *root helper* is serving. `fd` is the connected
    /// Unix socket the helper is speaking USB/IP on; this side only pumps
    /// bytes and never looks at them.
    public func enqueueRelay(fd: Int32, attachment: USBAttachment, speed: UInt32) {
        lock.lock()
        queue.append(.relay(fd: fd, attachment: attachment, speed: speed))
        lock.unlock()
        log("\(attachment.displayName) is waiting for the guest (captured by a root helper)")
    }

    /// Drops a promised device that the guest never collected.
    public func cancelPending(_ backend: USBIPDeviceBackend) {
        lock.lock()
        let removed = queue.filter { if case .serve(let b) = $0 { return b === backend }; return false }
        queue.removeAll { if case .serve(let b) = $0 { return b === backend }; return false }
        lock.unlock()
        for pending in removed { discard(pending) }
    }

    /// Everything this guest is holding or about to hold.
    public var attachments: [USBAttachment] {
        lock.lock(); defer { lock.unlock() }
        return live.map(\.attachment) + queue.map(\.attachment)
    }

    /// Takes a device back from the guest. Matches on the device token
    /// (`locationID` hex, or `synthetic`), which is what the person typed.
    @discardableResult
    public func detach(device: String) -> USBAttachment? {
        lock.lock()
        let wanted = device.lowercased()
        guard let index = live.firstIndex(where: { $0.attachment.device.lowercased() == wanted }) else {
            // Not attached yet, but promised - cancel the promise instead.
            guard let queued = queue.firstIndex(where: { $0.attachment.device.lowercased() == wanted }) else {
                lock.unlock()
                return nil
            }
            let pending = queue.remove(at: queued)
            lock.unlock()
            discard(pending)
            return pending.attachment
        }
        let entry = live.remove(at: index)
        lock.unlock()
        end(entry)
        log("\(entry.attachment.displayName) detached")
        return entry.attachment
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    /// Whether any device is attached or waiting to be.
    ///
    /// The idle timer asks, because a passed-through device is activity even
    /// when nothing is talking to the daemon. Without this, attaching a
    /// device and walking away pauses the guest seconds later (mslhd pauses
    /// an instance shortly after its last session closes) and then
    /// hibernates it, which releases the device - "I attached my board and
    /// it vanished", the same shape as the idle hibernate that used to kill
    /// live shell sessions.
    public var hasLiveAttachments: Bool {
        lock.lock(); defer { lock.unlock() }
        return !live.isEmpty || !queue.isEmpty
    }

    /// `Guest/init/usbattach.c`, as shipped inside MSL.app.
    public static func helperSource(kit: URL? = CustomImage.bundledKit()) -> Data? {
        guard let kit else { return nil }
        return try? Data(contentsOf: kit.appendingPathComponent("daemons/usbattach.c"))
    }

    /// The guest-side command that collects a promised device, or nil when
    /// the helper's source is not available to send.
    ///
    /// `msl-usbattach` has to be a compiled program: a shell cannot open an
    /// AF_VSOCK socket, and the fd number written to `attach` must belong
    /// to a process that still holds it open at the moment of the write. It
    /// travels base64'd inside this one command and is compiled in the
    /// guest, exactly as `GuestShellUpgrade` delivers `shellinit` - no image
    /// rebuild needed, and every image MSL ships carries a compiler.
    ///
    /// `vhci-hcd` is modprobed first. It is built as a module in every
    /// image MSL ships and is never loaded at boot, so the first attach
    /// into a fresh guest always has to load it.
    public static func attachCommand(speed: UInt32, devid: UInt32 = 1,
                                     source: Data? = helperSource()) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let encoded = source.base64EncodedString()
        // Stamped with the source's own hash, like `shellinit`. Testing only
        // for the binary's existence would mean a guest built once never
        // picked up a later fix - and this helper is the one piece of the
        // path that lives in the guest's filesystem rather than in MSL.app.
        let version = GuestShellUpgrade.version(of: source)
        return """
        set -e
        modprobe vhci-hcd 2>/dev/null || true
        [ -e /sys/devices/platform/vhci_hcd.0/attach ] || { echo "no vhci_hcd in this guest"; exit 1; }
        if [ ! -x '\(helperPath)' ] || [ "$(cat '\(stampPath)' 2>/dev/null)" != '\(version)' ]; then
            command -v cc >/dev/null 2>&1 || { echo "no cc - cannot build the attach helper"; exit 1; }
            mkdir -p /usr/local/libexec
            printf '%s' '\(encoded)' | base64 -d > /tmp/msl-usbattach.c
            cc -O1 -o /tmp/msl-usbattach /tmp/msl-usbattach.c || { echo "the attach helper did not build"; exit 1; }
            # Moved into place only after a clean compile, and the stamp
            # written last, so a broken toolchain leaves the working helper.
            mv /tmp/msl-usbattach '\(helperPath)'
            printf '%s' '\(version)' > '\(stampPath)'
        fi
        '\(helperPath)' --vsock \(vsockPort) --devid \(devid) --speed \(speed)
        """
    }

    static let helperPath = "/usr/local/libexec/msl-usbattach"
    static let stampPath = "/usr/local/libexec/.msl-usbattach-version"

    private func log(_ message: String) {
        FileHandle.standardError.write("[mslusb \(instance)] \(message)\n".data(using: .utf8)!)
    }

    private func handle(connection: VZVirtioSocketConnection) {
        lock.lock()
        let pending = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        guard let pending else {
            // Nothing was promised. Closing is the right answer: the guest
            // would otherwise hand a dead socket to `vhci_hcd`, which then
            // holds a port in a half-attached state.
            log("a guest asked for a device when none was waiting - refused")
            return
        }
        let guestFD = dup(connection.fileDescriptor)
        guard guestFD >= 0 else { discard(pending); return }

        switch pending {
        case .serve(let backend):
            let server = USBIPServer(fd: guestFD, backend: backend) { [weak self] in self?.log($0) }
            // A device pulled out of the Mac ends the attachment, rather
            // than leaving the guest with a port nothing will ever answer
            // on.
            if let host = backend as? HostUSBDevice {
                host.onDeviceGone = { server.stop() }
            }
            let entry = Live(attachment: pending.attachment, server: server, relayFD: nil,
                             guestFD: guestFD, connection: connection)
            lock.lock(); live.append(entry); lock.unlock()
            Thread { [weak self] in
                server.run()
                close(guestFD)
                self?.forget(entry)
            }.start()

        case .relay(let helperFD, let attachment, _):
            let entry = Live(attachment: attachment, server: nil, relayFD: helperFD,
                             guestFD: guestFD, connection: connection)
            lock.lock(); live.append(entry); lock.unlock()
            Thread { [weak self] in
                // The same relay the GPU bridge uses: one `poll` over both
                // fds, so neither direction can block the other. USB/IP is
                // a byte stream to this side - it never parses a URB.
                GPUBridge.pump(guestFD, helperFD)
                close(guestFD)
                close(helperFD)
                self?.log("\(attachment.displayName) released by its root helper")
                self?.forget(entry)
            }.start()
        }
    }

    private func forget(_ entry: Live) {
        lock.lock()
        live.removeAll { $0 === entry }
        lock.unlock()
    }
}

extension USBBridge: VZVirtioSocketListenerDelegate {
    public func listener(_ listener: VZVirtioSocketListener,
                         shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                         from socketDevice: VZVirtioSocketDevice) -> Bool {
        handle(connection: connection)
        return true
    }
}
