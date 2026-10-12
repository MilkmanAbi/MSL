import Foundation

/// What a USB/IP server needs from whatever is pretending to be (or
/// actually is) a USB device.
///
/// Deliberately asynchronous: `vhci_hcd` keeps several URBs in flight and
/// accepts them completing out of order, so a real device's transfers must
/// not block the read loop. `SyntheticUSBDevice` answers inline and calls
/// the completion straight away; a hardware-backed one hands the URB to
/// IOUSBHost and completes later.
/// One device a guest is holding, as the Mac side describes it.
public struct USBAttachment: Equatable, Sendable {
    /// What the person typed to attach it: a `locationID` in hex, or
    /// `synthetic`. Used to match a later `msl usb detach`.
    public let device: String
    public let displayName: String
    /// Taken from a macOS driver by a root helper, as opposed to opened
    /// directly because nothing on the Mac wanted it.
    public let captured: Bool

    public init(device: String, displayName: String, captured: Bool) {
        self.device = device
        self.displayName = displayName
        self.captured = captured
    }

    /// One line for `msl usb list`, parsed back by the CLI.
    public var wireLine: String {
        "\(device) \(captured ? "CAPTURED" : "OPEN") \(displayName)"
    }
}

public protocol USBIPDeviceBackend: AnyObject {
    /// A short human name for logs and `msl usb` output.
    var displayName: String { get }

    /// How the person named this device - a `locationID` in hex, or
    /// `synthetic`. Kept so `msl usb detach` can match on what they typed
    /// rather than on a display name that may not be unique.
    var deviceToken: String { get }

    /// The speed to tell `vhci_hcd` about at attach time, in the kernel's
    /// own `usb_device_speed` numbering (1 = low, 2 = full, 3 = high,
    /// 5 = super). It is fixed at attach and cannot be renegotiated.
    var linkSpeed: UInt32 { get }

    /// Serve one URB. Must call `completion` exactly once, on any thread.
    func submit(_ request: USBIPRequest, completion: @escaping (USBIPReply) -> Void)

    /// Best-effort cancellation of a URB the guest has given up on. A
    /// backend that cannot cancel should simply do nothing - the server
    /// always answers the guest's `CMD_UNLINK` itself.
    func cancel(seqnum: UInt32)

    /// Called once the guest is gone, so the backend can let go of
    /// whatever it was holding. For a captured device this is what hands
    /// it back to macOS.
    func teardown()
}

public extension USBIPDeviceBackend {
    var linkSpeed: UInt32 { 3 }
    func cancel(seqnum: UInt32) {}
    func teardown() {}
}

/// Builds the little-endian descriptor bytes a USB device has to be able
/// to hand back. Shared by the synthetic device and by anything that needs
/// to synthesise a descriptor rather than read one off hardware.
public struct USBDescriptorBuilder {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ value: UInt8) { bytes.append(value) }

    /// USB descriptors are little-endian throughout, unlike USB/IP's own
    /// headers - mixing the two up is the classic way to get a device that
    /// enumerates as `idVendor 0x0912` instead of `0x1209`.
    public mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public var data: Data { Data(bytes) }

    /// A string descriptor: length, type, then UTF-16LE with no
    /// terminator.
    public static func string(_ text: String) -> Data {
        var builder = USBDescriptorBuilder()
        let units = Array(text.utf16)
        builder.u8(UInt8(2 + units.count * 2))
        builder.u8(USBDescriptorType.string.rawValue)
        for unit in units { builder.u16(unit) }
        return builder.data
    }

    /// String descriptor zero: the list of language IDs the device has
    /// strings for. 0x0409 is US English.
    public static func languageIDs(_ ids: [UInt16] = [0x0409]) -> Data {
        var builder = USBDescriptorBuilder()
        builder.u8(UInt8(2 + ids.count * 2))
        builder.u8(USBDescriptorType.string.rawValue)
        for id in ids { builder.u16(id) }
        return builder.data
    }
}
