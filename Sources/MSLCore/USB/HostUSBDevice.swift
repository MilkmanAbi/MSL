import Foundation
#if canImport(IOUSBHost)
import IOKit
import IOKit.usb
import IOUSBHost

/// A real USB device on the Mac, served to a guest over USB/IP.
///
/// This is the other half of `SyntheticUSBDevice`: same `USBIPDeviceBackend`
/// contract, but every URB is forwarded to hardware through
/// IOUSBHost.framework instead of answered from a table.
///
/// ## Why this works without paid entitlements
///
/// Two levels of access, and MSL uses whichever it can get:
///
/// - **Plain open** (`capture: false`) needs nothing at all. It succeeds
///   only for a device macOS has no driver bound to - a dev board, a
///   USB-serial adapter, custom hardware. This is the case the user's
///   instinct was about, and it is genuinely unentitled.
/// - **Device capture** (`capture: true`) takes the device away from
///   whatever macOS driver owns it, which is what a flash drive or a
///   printer needs. `IOUSBHostObjectInitOptionsDeviceCapture` is
///   documented as requiring `com.apple.vm.device-access` *or root*:
///   "If the caller has root privileges the entitlement and authorization
///   is not needed." That `or root` is the whole feature - the entitlement
///   is restricted (ad-hoc signing it gets the process SIGKILLed at exec,
///   measured), but root is free.
///
/// On `destroy`, a captured device is reset and macOS's drivers are
/// re-registered for matching, so the device goes back to the Mac
/// automatically. That is why `teardown()` matters and why the server
/// calls it on every disconnect: without it, the guest crashing would
/// leave the device belonging to nobody until it was physically replugged.
///
/// **Unverified against hardware.** No USB device has ever been attached to
/// the machine this was developed on (`ioreg -p IOUSB` shows only the two
/// root XHCI controllers). The USB/IP transport either side of this class
/// *is* verified - a synthetic device enumerates in a guest end to end -
/// but every IOUSBHost call below has only been checked against the real
/// headers and the compiler, not against a device that can answer.
public final class HostUSBDevice: USBIPDeviceBackend {
    public let info: USBDeviceInfo
    public let displayName: String
    public let linkSpeed: UInt32
    public var deviceToken: String { String(format: "%08x", info.locationID) }

    private let device: IOUSBHostDevice
    private let queue: DispatchQueue
    private let logger: ((String) -> Void)?
    /// Pipes by endpoint address, opened lazily as the guest first uses
    /// each one. Interfaces have to be claimed before their endpoints
    /// exist, so this cannot be built up front.
    private var pipes: [UInt8: IOUSBHostPipe] = [:]
    private var interfaces: [IOUSBHostInterface] = []
    /// Interfaces by `bInterfaceNumber`, so a SET_INTERFACE can find the
    /// one the guest means.
    private var interfacesByNumber: [Int: IOUSBHostInterface] = [:]
    private let lock = NSLock()
    private var tornDown = false
    /// Called when IOKit says the device is going away, so whoever is
    /// serving it can stop rather than leave the guest holding a vhci port
    /// that will never answer again.
    public var onDeviceGone: (() -> Void)?

    /// Opens a device by IOKit service.
    ///
    /// - Parameter capture: take the device from macOS's own driver.
    ///   Requires root (or the restricted entitlement); without it the
    ///   open fails for anything macOS has already claimed.
    public init(service: io_service_t, info: USBDeviceInfo, capture: Bool,
                log: ((String) -> Void)? = nil) throws {
        self.info = info
        self.displayName = info.productName ?? String(format: "USB %04x:%04x", info.vendorID, info.productID)
        self.logger = log
        self.queue = DispatchQueue(label: "com.msl.usbip.device.\(String(format: "%08x", info.locationID))")
        let options: IOUSBHostObjectInitOptions = capture ? .deviceCapture : []
        // An interest handler, not nil: without one, pulling the device out
        // of the Mac is invisible to this side. The guest would keep a port
        // attached to a server with no hardware behind it, every URB would
        // time out, and `vhci_hcd` would need a manual detach to recover.
        var terminated: (() -> Void)?
        self.device = try IOUSBHostDevice(__ioService: service, options: options, queue: queue) { _, message, _ in
            // `kIOMessageServiceIsTerminated`, spelled out because IOKit's
            // message constants are not exposed to Swift.
            if message == 0xE000_0010 { terminated?() }
        }
        // The guest must be told the real speed at attach time; it cannot
        // be renegotiated afterwards. IOKit reports it in the registry.
        self.linkSpeed = Self.linkSpeed(of: service)
        // Set last: the closure captures `self`, so it cannot be built
        // until every stored property has a value.
        terminated = { [weak self] in
            guard let self else { return }
            self.logger?("\(self.displayName) was unplugged from the Mac")
            self.onDeviceGone?()
        }
    }

    /// Reads the device's speed in the kernel's `usb_device_speed`
    /// numbering, which is what `vhci_hcd`'s `attach` wants. IOKit uses the
    /// same numbering for `kUSBHostMatchingPropertySpeed`.
    public static func linkSpeed(of service: io_service_t) -> UInt32 {
        let value = IORegistryEntryCreateCFProperty(
            service, kUSBHostMatchingPropertySpeed as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber
        // Default to high-speed: wrong-but-plausible beats refusing to
        // attach, and every USB 2.0 device reports 2 here.
        guard let raw = value?.uint32Value else { return 3 }
        switch raw {
        case 0: return 1   // low
        case 1: return 2   // full
        case 2: return 3   // high
        case 3: return 5   // super
        case 4: return 6   // super-plus
        default: return 3
        }
    }

    public func teardown() {
        lock.lock()
        guard !tornDown else { lock.unlock(); return }
        tornDown = true
        let open = interfaces
        interfaces.removeAll()
        interfacesByNumber.removeAll()
        pipes.removeAll()
        lock.unlock()
        for interface in open { interface.destroy() }
        // Resets the device and lets macOS's drivers match it again, so a
        // captured device returns to the Mac on its own.
        device.destroy()
        logger?("released \(displayName) back to macOS")
    }

    public func cancel(seqnum: UInt32) {
        // IOUSBHost cancels per-endpoint, not per-URB, so there is nothing
        // precise to do here. Aborting the whole control endpoint to drop
        // one request would cancel unrelated in-flight transfers, which is
        // worse than letting it complete and be discarded by the server.
    }

    public func submit(_ request: USBIPRequest, completion: @escaping (USBIPReply) -> Void) {
        guard !tornDown else {
            completion(.submit(to: request, status: USBIPStatus.noDevice))
            return
        }
        if request.endpoint == 0, let setup = request.controlSetup {
            control(request, setup, completion)
        } else {
            transfer(request, completion)
        }
    }

    // MARK: - Control transfers

    private func control(_ request: USBIPRequest, _ setup: USBControlSetup,
                         _ completion: @escaping (USBIPReply) -> Void) {
        // Two standard requests must never reach the wire. macOS owns the
        // device's address and its configuration; forwarding either would
        // either be rejected by IOUSBHost or would desynchronise macOS's
        // own idea of the device's state.
        // Some standard requests must not reach the wire as raw control
        // transfers: macOS owns the device's address, its configuration and
        // its interface settings, and IOUSBHost has to rebuild its own
        // object graph when the last two change. The kernel's own USB/IP
        // stub does the same thing for the same reasons -
        // `drivers/usb/usbip/stub_rx.c`, `tweak_special_requests()`.
        if setup.type == 0, let standard = USBStandardRequest(rawValue: setup.bRequest) {
            switch standard {
            case .setAddress:
                // The device is already addressed on the Mac's bus. The
                // guest is addressing its *virtual* copy; answering yes is
                // both correct and the only safe option.
                completion(.submit(to: request, status: USBIPStatus.success))
                return
            case .setConfiguration:
                configure(value: UInt8(truncatingIfNeeded: setup.wValue), request: request, completion: completion)
                return
            case .setInterface:
                selectAlternate(setting: Int(setup.wValue), interface: Int(setup.wIndex),
                                request: request, completion: completion)
                return
            case .clearFeature where setup.recipient == 2 && setup.wValue == 0:
                // CLEAR_FEATURE(ENDPOINT_HALT). Sent after any stall, so a
                // guest that cannot clear one gets a permanently dead
                // endpoint - and IOUSBHost tracks the stall itself, so
                // forwarding this raw would leave its pipe stalled while
                // the hardware had moved on.
                clearStall(endpoint: UInt8(truncatingIfNeeded: setup.wIndex),
                           request: request, completion: completion)
                return
            default:
                break
            }
        }

        let length = Int(setup.wLength)
        let buffer: NSMutableData? = length > 0 ? NSMutableData(length: length) : nil
        if setup.isDeviceToHost == false, length > 0 {
            // An OUT transfer's bytes arrived with the URB.
            request.payload.withUnsafeBytes { raw in
                buffer?.replaceBytes(in: NSRange(location: 0, length: min(length, request.payload.count)),
                                     withBytes: raw.baseAddress!)
            }
        }
        var deviceRequest = IOUSBDeviceRequest(
            bmRequestType: setup.bmRequestType, bRequest: setup.bRequest,
            wValue: setup.wValue, wIndex: setup.wIndex, wLength: setup.wLength
        )
        do {
            try device.__enqueue(
                deviceRequest, data: buffer,
                completionTimeout: Self.timeout(for: request)
            ) { status, bytesTransferred in
                completion(Self.reply(to: request, status: status,
                                      buffer: buffer, bytesTransferred: bytesTransferred))
            }
        } catch {
            logger?("control \(setup.description) refused: \(error.localizedDescription)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
        _ = deviceRequest
    }

    /// Changes configuration through IOUSBHost rather than as a raw control
    /// request, because the framework has to rebuild the interface tree
    /// when it changes. `matchInterfaces: false` keeps macOS's drivers from
    /// grabbing the new interfaces out from under the guest.
    private func configure(value: UInt8, request: USBIPRequest,
                           completion: @escaping (USBIPReply) -> Void) {
        do {
            try device.__configure(withValue: Int(value), matchInterfaces: false)
            lock.lock()
            pipes.removeAll()
            let previous = interfaces
            interfaces.removeAll()
            interfacesByNumber.removeAll()
            lock.unlock()
            for interface in previous { interface.destroy() }
            logger?("configured \(displayName) as configuration \(value)")
            completion(.submit(to: request, status: USBIPStatus.success))
        } catch {
            logger?("could not set configuration \(value): \(error.localizedDescription)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
    }

    /// SET_INTERFACE, through IOUSBHost so it can rebuild the pipes.
    ///
    /// Alternate settings are how DFU exposes a device's flash regions, so
    /// this is not an exotic request for the hardware MSL is aimed at - it
    /// is the one in the middle of every firmware write.
    ///
    /// `selectAlternateSetting` invalidates every `IOUSBHostPipe` the
    /// interface had handed out, so the cache has to be dropped or the next
    /// transfer would use a pipe object that no longer refers to anything.
    private func selectAlternate(setting: Int, interface number: Int,
                                 request: USBIPRequest,
                                 completion: @escaping (USBIPReply) -> Void) {
        _ = claimInterfaces()
        lock.lock()
        let target = interfacesByNumber[number]
        lock.unlock()
        guard let target else {
            logger?("no interface \(number) on \(displayName) - SET_INTERFACE stalled")
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }
        do {
            try target.selectAlternateSetting(setting)
            lock.lock()
            // Every pipe of that interface is now stale. Dropping all of
            // them is heavier than needed and always correct; keeping a
            // stale one is neither.
            pipes.removeAll()
            lock.unlock()
            logger?("interface \(number) set to alternate \(setting)")
            completion(.submit(to: request, status: USBIPStatus.success))
        } catch {
            logger?("interface \(number) refused alternate \(setting): \(error.localizedDescription)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
    }

    /// CLEAR_FEATURE(ENDPOINT_HALT), through the pipe that owns the
    /// endpoint.
    private func clearStall(endpoint address: UInt8, request: USBIPRequest,
                            completion: @escaping (USBIPReply) -> Void) {
        guard let pipe = pipe(for: address) else {
            logger?("no endpoint \(String(format: "0x%02x", address)) to unstall on \(displayName)")
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }
        do {
            try pipe.clearStall()
            completion(.submit(to: request, status: USBIPStatus.success))
        } catch {
            logger?("could not unstall \(String(format: "0x%02x", address)): \(error.localizedDescription)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
    }

    // MARK: - Bulk and interrupt transfers

    private func transfer(_ request: USBIPRequest, _ completion: @escaping (USBIPReply) -> Void) {
        // USB/IP carries the endpoint number and direction separately; USB
        // endpoint addresses pack the direction into bit 7.
        let address = UInt8(truncatingIfNeeded: request.endpoint) | (request.direction == .in ? 0x80 : 0x00)
        guard let pipe = pipe(for: address) else {
            logger?("no endpoint \(String(format: "0x%02x", address)) on \(displayName) - stalled")
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }
        let length = Int(request.transferBufferLength)
        guard let buffer = NSMutableData(length: max(length, 1)) else {
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }
        if request.direction == .out, !request.payload.isEmpty {
            request.payload.withUnsafeBytes { raw in
                buffer.replaceBytes(in: NSRange(location: 0, length: min(length, request.payload.count)),
                                    withBytes: raw.baseAddress!)
            }
        }
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: Self.timeout(for: request)) { status, bytesTransferred in
                completion(Self.reply(to: request, status: status,
                                      buffer: buffer, bytesTransferred: bytesTransferred))
            }
        } catch {
            logger?("transfer on \(String(format: "0x%02x", address)) refused: \(error.localizedDescription)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
    }

    /// Finds (and on first use, opens) the pipe for an endpoint address.
    ///
    /// Endpoints only exist once their interface is claimed, and an
    /// interface is a separate IOKit service that has to be opened in its
    /// own right - so the first URB on each endpoint pays for discovering
    /// which interface owns it.
    private func pipe(for address: UInt8) -> IOUSBHostPipe? {
        lock.lock()
        if let existing = pipes[address] { lock.unlock(); return existing }
        lock.unlock()

        for interface in claimInterfaces() {
            guard let pipe = try? interface.copyPipe(withAddress: Int(address)) else { continue }
            lock.lock()
            pipes[address] = pipe
            lock.unlock()
            return pipe
        }
        return nil
    }

    /// Opens every interface of the current configuration, once.
    private func claimInterfaces() -> [IOUSBHostInterface] {
        lock.lock()
        if !interfaces.isEmpty { let open = interfaces; lock.unlock(); return open }
        lock.unlock()

        var opened: [IOUSBHostInterface] = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, kIOUSBHostInterfaceClassName) != 0 else { continue }
            guard let interface = try? IOUSBHostInterface(__ioService: child, options: [],
                                                          queue: queue, interestHandler: nil) else { continue }
            opened.append(interface)
        }
        lock.lock()
        interfaces = opened
        interfacesByNumber = [:]
        for interface in opened {
            let number = Int(interface.interfaceDescriptor.pointee.bInterfaceNumber)
            interfacesByNumber[number] = interface
        }
        lock.unlock()
        return opened
    }

    // MARK: - Shared

    /// USB/IP carries no timeout; the guest's own URB timeout governs. A
    /// zero timeout means "never" to IOUSBHost, which is right for an
    /// interrupt endpoint that may legitimately wait minutes for input, and
    /// wrong for a control transfer that should fail fast.
    private static func timeout(for request: USBIPRequest) -> TimeInterval {
        request.endpoint == 0 ? 5.0 : 0
    }

    /// Turns an IOKit completion into a USB/IP reply.
    ///
    /// `kIOUSBPipeStalled` is a device saying "no" and must come back as
    /// `-EPIPE`, not as a transport failure - the guest clears the stall
    /// and carries on, exactly as it would with real hardware.
    private static func reply(to request: USBIPRequest, status: IOReturn,
                              buffer: NSMutableData?, bytesTransferred: Int) -> USBIPReply {
        guard status == kIOReturnSuccess || status == kIOReturnOverrun else {
            return .submit(to: request, status: translate(status))
        }
        guard request.direction == .in, let buffer, bytesTransferred > 0 else {
            return .submit(to: request, status: USBIPStatus.success)
        }
        let count = min(bytesTransferred, buffer.length)
        return .submit(to: request, status: USBIPStatus.success,
                       payload: Data(bytes: buffer.bytes, count: count))
    }

    /// `kIOUSBPipeStalled`. IOUSBHost still reports it, but the constant
    /// itself lived in IOKit's legacy `USB.h` and is no longer declared in
    /// the SDK, so its documented value is spelled out: `iokit_usb_err(0x60)`
    /// is `sys_iokit | sub_iokit_usb | 0x60`.
    static let pipeStalled = IOReturn(bitPattern: 0xe000_4060)

    private static func translate(_ status: IOReturn) -> Int32 {
        switch status {
        case Self.pipeStalled:     return USBIPStatus.stall
        case kIOReturnAborted:     return USBIPStatus.cancelled
        case kIOReturnTimeout:     return USBIPStatus.timeout
        case kIOReturnNoDevice,
             kIOReturnNotAttached: return USBIPStatus.noDevice
        default:                   return USBIPStatus.stall
        }
    }
}
#endif
