import Foundation

/// A USB device that does not exist.
///
/// It serves hand-built descriptors over USB/IP and nothing else, which is
/// exactly enough for the guest kernel to enumerate it and for `lsusb` to
/// list it. That makes it the test fixture for the whole transport: if a
/// synthetic device appears in the guest, then the vsock carriage, the
/// `vhci_hcd` attach, the 48-byte big-endian framing, the control-transfer
/// path and the descriptor little-endianness are all correct, and the only
/// unproven piece left is reading a *real* device through IOUSBHost.
///
/// It claims the pid.codes vendor ID (0x1209), which exists precisely so
/// open-source projects do not have to squat on someone else's.
public final class SyntheticUSBDevice: USBIPDeviceBackend {
    public let displayName = "MSL Virtual Test Device"
    public let deviceToken = "synthetic"
    public let linkSpeed: UInt32 = 3   // high-speed

    public static let vendorID: UInt16 = 0x1209
    public static let productID: UInt16 = 0x4D53   // "MS"

    private let strings: [Data]
    private let logger: ((String) -> Void)?

    public init(log: ((String) -> Void)? = nil) {
        self.logger = log
        self.strings = [
            USBDescriptorBuilder.languageIDs(),
            USBDescriptorBuilder.string("MSL"),
            USBDescriptorBuilder.string("MSL Virtual Test Device"),
            USBDescriptorBuilder.string("MSL-SYNTH-0001"),
            USBDescriptorBuilder.string("Loopback Proof Interface"),
        ]
    }

    private var deviceDescriptor: Data {
        var d = USBDescriptorBuilder()
        d.u8(18)                                        // bLength
        d.u8(USBDescriptorType.device.rawValue)
        d.u16(0x0200)                                   // bcdUSB 2.00
        d.u8(0xFF)                                      // vendor-specific class
        d.u8(0x00)
        d.u8(0x00)
        d.u8(64)                                        // bMaxPacketSize0
        d.u16(Self.vendorID)
        d.u16(Self.productID)
        d.u16(0x0200)                                   // bcdDevice
        d.u8(1)                                         // iManufacturer
        d.u8(2)                                         // iProduct
        d.u8(3)                                         // iSerialNumber
        d.u8(1)                                         // bNumConfigurations
        return d.data
    }

    /// One configuration holding one interface with no endpoints. No
    /// endpoints on purpose: there is nothing behind this device to talk
    /// to, and an advertised bulk endpoint would invite a driver to try.
    /// `wTotalLength` must cover configuration + interface together, or the
    /// kernel reads a truncated tree and rejects the device.
    private var configurationDescriptor: Data {
        var interface = USBDescriptorBuilder()
        interface.u8(9)
        interface.u8(USBDescriptorType.interface.rawValue)
        interface.u8(0)                                 // bInterfaceNumber
        interface.u8(0)                                 // bAlternateSetting
        interface.u8(0)                                 // bNumEndpoints
        interface.u8(0xFF)                              // vendor-specific
        interface.u8(0x00)
        interface.u8(0x00)
        interface.u8(4)                                 // iInterface

        var config = USBDescriptorBuilder()
        config.u8(9)
        config.u8(USBDescriptorType.configuration.rawValue)
        config.u16(UInt16(9 + interface.bytes.count))   // wTotalLength
        config.u8(1)                                    // bNumInterfaces
        config.u8(1)                                    // bConfigurationValue
        config.u8(0)                                    // iConfiguration
        config.u8(0x80)                                 // bus powered
        config.u8(50)                                   // 100 mA
        return config.data + interface.data
    }

    public func submit(_ request: USBIPRequest, completion: @escaping (USBIPReply) -> Void) {
        guard let setup = request.controlSetup else {
            // Nothing is listening on any other endpoint. A stall is the
            // honest answer, and the guest treats it as such.
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }
        guard setup.type == 0 else {
            logger?("synthetic: non-standard request stalled (\(setup.description))")
            completion(.submit(to: request, status: USBIPStatus.stall))
            return
        }

        switch USBStandardRequest(rawValue: setup.bRequest) {
        case .getDescriptor:
            guard let data = descriptor(type: setup.descriptorType, index: setup.descriptorIndex) else {
                // An unsupported descriptor (BOS, device-qualifier on a
                // full-speed-only device) is a stall, not a failure - the
                // kernel asks for several it is happy not to get.
                logger?(String(format: "synthetic: no descriptor %02x[%d], stalled",
                               setup.descriptorType, Int(setup.descriptorIndex)))
                completion(.submit(to: request, status: USBIPStatus.stall))
                return
            }
            // A device must never send more than the host asked for.
            let limit = min(Int(setup.wLength), data.count)
            completion(.submit(to: request, status: USBIPStatus.success, payload: data.prefix(limit)))

        case .setConfiguration, .setInterface, .clearFeature, .setFeature, .setAddress:
            // Acknowledged with a zero-length status stage.
            completion(.submit(to: request, status: USBIPStatus.success))

        case .getConfiguration:
            completion(.submit(to: request, status: USBIPStatus.success, payload: Data([1])))

        case .getInterface:
            completion(.submit(to: request, status: USBIPStatus.success, payload: Data([0])))

        case .getStatus:
            completion(.submit(to: request, status: USBIPStatus.success, payload: Data([0, 0])))

        case .setDescriptor, .none:
            logger?("synthetic: unhandled standard request \(setup.description)")
            completion(.submit(to: request, status: USBIPStatus.stall))
        }
    }

    private func descriptor(type: UInt8, index: UInt8) -> Data? {
        switch USBDescriptorType(rawValue: type) {
        case .device:        return deviceDescriptor
        case .configuration: return index == 0 ? configurationDescriptor : nil
        case .string:        return Int(index) < strings.count ? strings[Int(index)] : nil
        default:             return nil
        }
    }
}
