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
    #else
    public static func listDevices() -> [USBDeviceInfo] { [] }
    #endif
}
