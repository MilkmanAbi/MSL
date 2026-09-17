import Foundation
#if canImport(IOUSBHost)
import IOKit
import IOKit.usb
import IOUSBHost
#endif

public enum USBClaimError: Error, CustomStringConvertible {
    case deviceNotFound
    case matchingDictionaryCreationFailed

    public var description: String {
        switch self {
        case .deviceNotFound: return "no USB device found matching the given criteria"
        case .matchingDictionaryCreationFailed: return "IOServiceMatching failed"
        }
    }
}

#if canImport(IOUSBHost)
/// Opens and claims a single USB device for exclusive host-side access -
/// the entry point for actual passthrough (a claimed device's control/bulk
/// transfers can be driven directly, ready to be forwarded from a guest's
/// USB/IP requests once that transport is wired up - not yet done, see
/// README).
///
/// Requires the `com.apple.vm.device-access` entitlement (restricted, see
/// `Resources/msl-usbd/`) - unlike `USBDeviceEnumerator`/`USBDeviceWatcher`,
/// which only read the IOKit registry.
///
/// **Phase 1 scope, matching the design docs exactly**: this can only
/// claim devices macOS has no existing system driver for (dev boards,
/// USB-serial adapters, custom hardware) - `IOUSBHostDevice`'s own
/// initializer fails cleanly (throws) if a driver already owns the
/// device, which is precisely the safety boundary Phase 1 wants (it
/// naturally can't claim the built-in keyboard/trackpad, or anything with
/// a loaded HID/audio/etc. driver, without a DriverKit extension to first
/// detach that driver - Phase 2, see `Sources/MSLUSBDriver`). No separate
/// class-based blocklist is implemented on top of this for that reason -
/// it would either be redundant (blocking what already fails to claim) or
/// wrong (blocking legitimate external HID devices, e.g. a real USB
/// keyboard someone wants to pass through, which macOS's own driver
/// claiming already prevents at Phase 1 regardless of any blocklist).
///
/// **Untested against real hardware** - no USB devices were attached in
/// the environment this was written in (confirmed via `system_profiler
/// SPUSBDataType` / `ioreg -p IOUSB`, both show zero downstream devices,
/// only the root XHCI controllers). Every API call here was verified
/// against the actual `IOUSBHost.framework` headers on this machine and
/// against real compiler type-checking (the `NS_REFINED_FOR_SWIFT` methods
/// import as double-underscore-prefixed selectors - e.g. `__send`,
/// `__string(with:languageID:)` - confirmed empirically since the
/// "friendly" unprefixed names are stubbed out as
/// `@available(*, unavailable, message: "Please use the refined for Swift
/// API")` rather than actually resolving to a nicer overload), but the
/// actual claim/transfer path needs a real device plugged in to verify.
public final class USBDeviceClaim {
    public let info: USBDeviceInfo
    private let device: IOUSBHostDevice

    public init(service: io_service_t, info: USBDeviceInfo, queue: DispatchQueue? = nil) throws {
        self.info = info
        self.device = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil)
    }

    /// Finds and claims a device by its `locationID` (stable for as long as
    /// it stays plugged into the same physical port, not persistent across
    /// replug/reboot).
    public convenience init(locationID: UInt32, queue: DispatchQueue? = nil) throws {
        guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else {
            throw USBClaimError.matchingDictionaryCreationFailed
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw USBClaimError.deviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let info = USBDeviceInfo(service: service), info.locationID == locationID else { continue }
            try self.init(service: service, info: info, queue: queue)
            return
        }
        throw USBClaimError.deviceNotFound
    }

    deinit {
        device.destroy()
    }

    public var deviceDescriptorSummary: String {
        guard let desc = device.deviceDescriptor else { return "no device descriptor available" }
        return String(
            format: "USB %x.%02x, class %02x/%02x/%02x, %d configuration(s)",
            Int(desc.pointee.bcdUSB) >> 8, Int(desc.pointee.bcdUSB) & 0xFF,
            desc.pointee.bDeviceClass, desc.pointee.bDeviceSubClass, desc.pointee.bDeviceProtocol,
            desc.pointee.bNumConfigurations
        )
    }

    /// The device's `iProduct` string descriptor, if it has one. Default
    /// language ID 0x0409 is US English, the overwhelmingly common case
    /// for a device's only string language.
    public func productString(languageID: Int = 0x0409) throws -> String? {
        guard let desc = device.deviceDescriptor, desc.pointee.iProduct != 0 else { return nil }
        return try device.__string(with: Int(desc.pointee.iProduct), languageID: languageID)
    }

    /// Sends a raw control request on the default control endpoint -
    /// `bmRequestType`/`bRequest`/`wValue`/`wIndex` match the USB
    /// specification's own control request fields exactly (USB 2.0 9.3).
    /// This is the primitive a future USB/IP-over-vsock transport would
    /// call to forward a guest's control requests to the real device.
    @discardableResult
    public func controlTransfer(
        bmRequestType: UInt8,
        bRequest: UInt8,
        wValue: UInt16,
        wIndex: UInt16,
        dataLength: Int,
        timeout: TimeInterval = 5.0
    ) throws -> Data {
        let request = IOUSBDeviceRequest(
            bmRequestType: bmRequestType, bRequest: bRequest,
            wValue: wValue, wIndex: wIndex, wLength: UInt16(dataLength)
        )
        let buffer = NSMutableData(length: dataLength) ?? NSMutableData()
        var bytesTransferred = 0
        try device.__send(request, data: buffer, bytesTransferred: &bytesTransferred, completionTimeout: timeout)
        return Data(bytes: buffer.bytes, count: bytesTransferred)
    }
}
#endif
