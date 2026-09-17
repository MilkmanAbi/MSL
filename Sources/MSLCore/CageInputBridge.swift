import Foundation
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Phase 3 step 3 of `cage-planning.md`: the host side of host->guest
/// input injection - DELIBERATELY a separate listener/port from
/// `CageBridge` (the guest->host frame stream), not the same connection
/// used bidirectionally. See `Guest/init/wayland-tests/cageinput.c`'s own
/// doc comment for the full reasoning (a 3.6MB frame under sustained
/// streaming can block `cagebridge`'s single-threaded write path for
/// long enough that a shared fd would starve input) - same shape this
/// project already uses elsewhere (`DisplayBridge`/`X11Server`/
/// `CageBridge` are independent listeners on independent ports; `grim`/
/// `wtype` are independent guest binaries).
///
/// Unlike `CageBridge` (which only ever reads), this class both accepts
/// the guest's connection AND writes to it on demand, from whatever
/// thread calls `sendKey`/`sendPointerMotion`/`sendPointerButton` - the
/// guest's `cageinput` never sends anything back, so there's no read
/// loop here at all, just a retained connection to write into.
///
/// Wire format - see `cageinput.c`'s own doc comment for the
/// authoritative description: a 20-byte command
/// (`type, a, b, c, d: UInt32`, native-endian) per injected event.
public final class CageInputBridge: NSObject {
    private let socketDevice: VZVirtioSocketDevice
    private let port: UInt32
    private var listener: VZVirtioSocketListener?

    /// The most recently accepted connection - `cageinput` dials out
    /// once at startup and holds that one connection for its whole
    /// lifetime, so "most recent" is "the only one" in practice. Only
    /// ever touched from `queue`.
    private var connection: VZVirtioSocketConnection?
    private let queue = DispatchQueue(label: "CageInputBridge")

    private static let keyCommand: UInt32 = 1
    private static let pointerMotionCommand: UInt32 = 2
    private static let pointerButtonCommand: UInt32 = 3

    public init(socketDevice: VZVirtioSocketDevice, port: UInt32) {
        self.socketDevice = socketDevice
        self.port = port
        super.init()
    }

    public func start() {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: port)
        self.listener = listener
    }

    /// See `DisplayBridge.stop()`'s doc comment - same "no unset API,
    /// dropping the retained listener/connection is the best available
    /// substitute" reasoning applies here verbatim.
    public func stop() {
        listener = nil
        queue.sync { connection = nil }
    }

    /// `keycode` is an evdev code (e.g. `KEY_A` = 30), matching
    /// `wl_keyboard.key`/`zwp_virtual_keyboard_v1.key`'s own convention -
    /// NOT an Xkb keycode (which is evdev + 8). Returns `false` if there's
    /// no connected guest `cageinput` to send to, or the write failed.
    @discardableResult
    public func sendKey(keycode: UInt32, pressed: Bool) -> Bool {
        send(type: Self.keyCommand, a: keycode, b: pressed ? 1 : 0, c: 0, d: 0)
    }

    /// `x`/`y` are absolute, in the range `[0, xExtent]`/`[0, yExtent]` -
    /// matching `zwlr_virtual_pointer_v1.motion_absolute`'s own
    /// convention (see the protocol XML). Callers pass the target
    /// output's real pixel dimensions as the extents (1280x720 for this
    /// project's headless cage sessions).
    @discardableResult
    public func sendPointerMotion(x: UInt32, y: UInt32, xExtent: UInt32, yExtent: UInt32) -> Bool {
        send(type: Self.pointerMotionCommand, a: x, b: y, c: xExtent, d: yExtent)
    }

    /// `button` is a Linux evdev button code (e.g. `BTN_LEFT` = 0x110).
    @discardableResult
    public func sendPointerButton(button: UInt32, pressed: Bool) -> Bool {
        send(type: Self.pointerButtonCommand, a: button, b: pressed ? 1 : 0, c: 0, d: 0)
    }

    private func send(type: UInt32, a: UInt32, b: UInt32, c: UInt32, d: UInt32) -> Bool {
        queue.sync {
            guard let connection else { return false }
            var words: [UInt32] = [type, a, b, c, d]
            return words.withUnsafeMutableBytes { ptr -> Bool in
                let fd = connection.fileDescriptor
                var sent = 0
                let base = ptr.baseAddress!
                while sent < ptr.count {
                    let n = write(fd, base + sent, ptr.count - sent)
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
        }
    }
}

extension CageInputBridge: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        queue.sync { self.connection = connection }
        return true
    }
}
