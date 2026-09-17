import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.usb
#endif

/// A snapshot of one USB device's identity, read from the IOKit registry.
/// Enumerating this needs no entitlement at all - it's a plain registry
/// read. Actually opening/claiming the device (`USBDeviceClaim`) is the
/// part that needs `com.apple.vm.device-access`.
public struct USBDeviceInfo: Equatable, CustomStringConvertible {
    public let vendorID: UInt16
    public let productID: UInt16
    public let deviceClass: UInt8
    public let deviceSubClass: UInt8
    public let deviceProtocol: UInt8
    public let locationID: UInt32
    public let productName: String?
    public let vendorName: String?
    public let serialNumber: String?

    public var description: String {
        let name = productName ?? "Unknown Device"
        return String(format: "%@ (%04x:%04x, class %02x, location 0x%08x)", name, vendorID, productID, deviceClass, locationID)
    }

    /// USB class codes worth calling out by name in diagnostics - not a
    /// security boundary (see `USBDeviceClaim`'s doc comment for why this
    /// project doesn't implement a class-based blocklist).
    public var isHIDClass: Bool { deviceClass == 0x03 }

    #if canImport(IOKit)
    /// Reads device identity properties directly from the IOKit registry
    /// for a service already known to be an `IOUSBHostDevice`-matched
    /// entry. Returns nil if the required identity fields (vendor/product
    /// ID) aren't present - shouldn't happen for anything that matched
    /// `kIOUSBHostDeviceClassName`, but IOKit properties are always
    /// optional in principle.
    public init?(service: io_service_t) {
        func property(_ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func uint(_ key: String) -> UInt32? {
            (property(key) as? NSNumber)?.uint32Value
        }
        func string(_ key: String) -> String? {
            property(key) as? String
        }

        guard let vendorID = uint(kUSBHostMatchingPropertyVendorID),
              let productID = uint(kUSBHostMatchingPropertyProductID) else {
            return nil
        }
        self.vendorID = UInt16(truncatingIfNeeded: vendorID)
        self.productID = UInt16(truncatingIfNeeded: productID)
        self.deviceClass = UInt8(truncatingIfNeeded: uint(kUSBHostMatchingPropertyDeviceClass) ?? 0)
        self.deviceSubClass = UInt8(truncatingIfNeeded: uint(kUSBHostMatchingPropertyDeviceSubClass) ?? 0)
        self.deviceProtocol = UInt8(truncatingIfNeeded: uint(kUSBHostMatchingPropertyDeviceProtocol) ?? 0)
        self.locationID = uint(kUSBHostPropertyLocationID) ?? 0
        self.productName = string(kUSBHostDevicePropertyProductString)
        self.vendorName = string(kUSBHostDevicePropertyVendorString)
        self.serialNumber = string(kUSBHostDevicePropertySerialNumberString)
    }
    #endif
}
