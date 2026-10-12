import Foundation

/// The USB/IP wire format, URB phase only.
///
/// MSL attaches devices by writing straight to the guest's
/// `/sys/devices/platform/vhci_hcd.0/attach`, which hands `vhci_hcd` a
/// socket that is *already* connected. That skips USB/IP's connection
/// phase entirely - no `OP_REQ_DEVLIST`, no `OP_REQ_IMPORT`, no 8-byte
/// op-common headers - so the only thing that ever crosses the wire is
/// URB traffic: fixed 48-byte headers, big-endian, optionally followed by
/// a payload.
///
/// Reference: Linux `Documentation/usb/usbip_protocol.rst`, and
/// `drivers/usb/usbip/` for what the kernel actually reads (which is
/// narrower than the document in places - see `Reply.encode`).
public enum USBIPCommand: UInt32 {
    case submit = 1
    case unlink = 2
    case returnSubmit = 3
    case returnUnlink = 4
}

/// Header size for every USB/IP URB PDU, in both directions. The format
/// is deliberately fixed-width: 20 bytes of basic header plus 28 bytes
/// that mean different things per command.
public let usbipHeaderSize = 48

/// `USBIP_DIR_OUT` / `USBIP_DIR_IN` as the kernel numbers them.
public enum USBIPDirection: UInt32 {
    case out = 0
    case `in` = 1
}

/// A big-endian reader/writer for the fixed header. Hand-rolled rather
/// than `withUnsafeBytes` over a struct: the PDU is packed big-endian with
/// no padding, which no Swift struct layout gives for free.
@inline(__always)
private func beUInt32(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
}

@inline(__always)
private func appendBE(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
}

@inline(__always)
private func appendBE(_ data: inout Data, _ value: Int32) {
    appendBE(&data, UInt32(bitPattern: value))
}

/// One request from the guest's `vhci_hcd`.
public struct USBIPRequest {
    public let command: USBIPCommand
    public let seqnum: UInt32
    public let devid: UInt32
    public let direction: USBIPDirection
    public let endpoint: UInt32

    // CMD_SUBMIT fields.
    public var transferFlags: UInt32 = 0
    public var transferBufferLength: Int32 = 0
    public var startFrame: Int32 = 0
    public var numberOfPackets: Int32 = 0
    public var interval: Int32 = 0
    /// The 8-byte USB setup packet, carried verbatim (never byte-swapped,
    /// it is already little-endian per the USB specification).
    public var setup: [UInt8] = Array(repeating: 0, count: 8)

    // CMD_UNLINK field.
    public var unlinkSeqnum: UInt32 = 0

    /// Payload bytes that followed the header, for an OUT transfer.
    public var payload: Data = Data()

    public var isControl: Bool { endpoint == 0 }

    /// `number_of_packets` is `-1` (or 0) for everything that is not
    /// isochronous. The kernel sends `0xffffffff` for non-iso URBs, so a
    /// plain `> 0` test is the only safe one.
    public var isIsochronous: Bool { numberOfPackets > 0 }

    /// Decodes a 48-byte header. Returns nil for a command this server
    /// does not speak, rather than guessing at the remaining 28 bytes.
    public init?(header: UnsafePointer<UInt8>) {
        guard let command = USBIPCommand(rawValue: beUInt32(header, 0)),
              let direction = USBIPDirection(rawValue: beUInt32(header, 12)) else { return nil }
        self.command = command
        self.seqnum = beUInt32(header, 4)
        self.devid = beUInt32(header, 8)
        self.direction = direction
        self.endpoint = beUInt32(header, 16)

        switch command {
        case .submit:
            self.transferFlags = beUInt32(header, 20)
            self.transferBufferLength = Int32(bitPattern: beUInt32(header, 24))
            self.startFrame = Int32(bitPattern: beUInt32(header, 28))
            self.numberOfPackets = Int32(bitPattern: beUInt32(header, 32))
            self.interval = Int32(bitPattern: beUInt32(header, 36))
            self.setup = (0..<8).map { header[40 + $0] }
        case .unlink:
            self.unlinkSeqnum = beUInt32(header, 20)
        case .returnSubmit, .returnUnlink:
            // Only ever sent host → guest. Receiving one means the guest
            // and host have disagreed about who speaks when.
            return nil
        }
    }

    /// The setup packet's fields, for a control transfer on endpoint 0.
    public var controlSetup: USBControlSetup? {
        guard isControl else { return nil }
        return USBControlSetup(
            bmRequestType: setup[0],
            bRequest: setup[1],
            wValue: UInt16(setup[2]) | (UInt16(setup[3]) << 8),
            wIndex: UInt16(setup[4]) | (UInt16(setup[5]) << 8),
            wLength: UInt16(setup[6]) | (UInt16(setup[7]) << 8)
        )
    }
}

/// A decoded USB control setup packet (USB 2.0 §9.3), little-endian on the
/// wire as the specification requires.
public struct USBControlSetup {
    public let bmRequestType: UInt8
    public let bRequest: UInt8
    public let wValue: UInt16
    public let wIndex: UInt16
    public let wLength: UInt16

    public var isDeviceToHost: Bool { bmRequestType & 0x80 != 0 }
    /// 0 = standard, 1 = class, 2 = vendor.
    public var type: UInt8 { (bmRequestType >> 5) & 0x03 }
    public var recipient: UInt8 { bmRequestType & 0x1F }

    /// High byte of `wValue` for a GET_DESCRIPTOR request.
    public var descriptorType: UInt8 { UInt8(truncatingIfNeeded: wValue >> 8) }
    public var descriptorIndex: UInt8 { UInt8(truncatingIfNeeded: wValue) }

    public var description: String {
        String(format: "bmRequestType=%02x bRequest=%02x wValue=%04x wIndex=%04x wLength=%u",
               bmRequestType, bRequest, wValue, wIndex, wLength)
    }
}

/// Standard USB request codes this server has to recognise to get a device
/// enumerated at all.
public enum USBStandardRequest: UInt8 {
    case getStatus = 0x00
    case clearFeature = 0x01
    case setFeature = 0x03
    case setAddress = 0x05
    case getDescriptor = 0x06
    case setDescriptor = 0x07
    case getConfiguration = 0x08
    case setConfiguration = 0x09
    case getInterface = 0x0A
    case setInterface = 0x0B
}

public enum USBDescriptorType: UInt8 {
    case device = 0x01
    case configuration = 0x02
    case string = 0x03
    case interface = 0x04
    case endpoint = 0x05
    case deviceQualifier = 0x06
    case otherSpeedConfiguration = 0x07
    case bos = 0x0F
}

/// Linux errnos as USB/IP status values - negative, because that is
/// literally what the kernel stores in `urb->status`.
public enum USBIPStatus {
    public static let success: Int32 = 0
    /// A stalled endpoint. The correct answer to any request a device does
    /// not support, and the one the kernel expects for e.g. a missing BOS
    /// descriptor - it is not an error condition, it is a "no".
    public static let stall: Int32 = -32      // -EPIPE
    public static let shutdown: Int32 = -108  // -ESHUTDOWN
    public static let noDevice: Int32 = -19   // -ENODEV
    public static let timeout: Int32 = -110   // -ETIMEDOUT
    public static let cancelled: Int32 = -104 // -ECONNRESET
}

/// One reply, host → guest.
public struct USBIPReply {
    public let command: USBIPCommand
    public let seqnum: UInt32
    public let direction: USBIPDirection
    public let endpoint: UInt32
    public let status: Int32
    public let payload: Data

    public static func submit(to request: USBIPRequest, status: Int32, payload: Data = Data()) -> USBIPReply {
        USBIPReply(command: .returnSubmit, seqnum: request.seqnum,
                   direction: request.direction, endpoint: request.endpoint,
                   status: status, payload: payload)
    }

    public static func unlink(to request: USBIPRequest, status: Int32) -> USBIPReply {
        USBIPReply(command: .returnUnlink, seqnum: request.seqnum,
                   direction: request.direction, endpoint: request.endpoint,
                   status: status, payload: Data())
    }

    /// The 48-byte header plus, for an IN transfer that returned data, the
    /// payload.
    ///
    /// `devid` is deliberately zero: a reply's basic header reuses the
    /// field layout but `vhci_rx.c` matches the URB by `seqnum` alone and
    /// never reads `devid` back, and real `usbip-host` sends zero here too.
    public func encode() -> Data {
        var data = Data(capacity: usbipHeaderSize + payload.count)
        appendBE(&data, command.rawValue)
        appendBE(&data, seqnum)
        appendBE(&data, UInt32(0))               // devid
        appendBE(&data, direction.rawValue)
        appendBE(&data, endpoint)
        appendBE(&data, status)
        switch command {
        case .returnSubmit:
            appendBE(&data, Int32(payload.count)) // actual_length
            appendBE(&data, Int32(0))             // start_frame
            appendBE(&data, Int32(0))             // number_of_packets
            appendBE(&data, Int32(0))             // error_count
            data.append(Data(repeating: 0, count: 8)) // padding
        case .returnUnlink:
            data.append(Data(repeating: 0, count: 24))
        case .submit, .unlink:
            // Never encoded by the host side.
            data.append(Data(repeating: 0, count: 24))
        }
        precondition(data.count == usbipHeaderSize, "USB/IP header must be exactly 48 bytes")
        // Only an IN transfer carries data back; an OUT reply is header only.
        if direction == .in, !payload.isEmpty { data.append(payload) }
        return data
    }
}
