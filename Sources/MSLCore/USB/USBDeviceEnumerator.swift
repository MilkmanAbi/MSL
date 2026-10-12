import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.usb
#endif

public enum USBDeviceEnumerator {
    #if canImport(IOKit)
    /// Lists every USB device currently visible to the host, regardless of
    /// whether anything already claims it (a claim attempt via
    /// `USBDeviceClaim` will fail cleanly for anything macOS's own drivers
    /// already own - see that type's doc comment). No entitlement needed;
    /// this is a plain IOKit registry read.
    public static func listDevices() -> [USBDeviceInfo] {
        guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = USBDeviceInfo(service: service) {
                devices.append(info)
            }
        }
        return devices
    }

    /// Finds one device by `locationID`, returning a service the caller
    /// owns and must release.
    ///
    /// `locationID` is stable for as long as the device stays in the same
    /// physical port - it encodes the port path, not the device - so it is
    /// the right handle for "pass *that* one through" and the wrong one for
    /// remembering a device across a replug.
    public static func findService(locationID: UInt32) -> (service: io_service_t, info: USBDeviceInfo)? {
        guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard let info = USBDeviceInfo(service: service), info.locationID == locationID else {
                IOObjectRelease(service)
                continue
            }
            // Handed to the caller still retained, on purpose: it has to
            // outlive this iterator to be opened.
            return (service, info)
        }
        return nil
    }
    #else
    public static func listDevices() -> [USBDeviceInfo] { [] }
    public static func findService(locationID: UInt32) -> (service: Int32, info: USBDeviceInfo)? { nil }
    #endif
}
