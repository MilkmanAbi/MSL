import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.usb
#endif

/// Which of macOS's own drivers are holding a USB device - the question
/// that decides whether MSL can pass it through for free or has to take it
/// away from the system first.
///
/// This is the whole user-facing split. A device macOS has never heard of
/// can be opened by anyone and served to a guest with no privileges at all.
/// A device macOS has a driver for has to be *captured*, which needs root.
/// Guessing wrong in the optimistic direction produces the worst failure
/// mode available: a device that opens, answers control transfers, and then
/// has no working endpoints, because the driver on its interfaces never let
/// go.
public struct USBDriverClaim: Equatable {
    /// Drivers matched on the device itself.
    public let onDevice: [String]
    /// Drivers matched on its interfaces, by interface number.
    public let onInterfaces: [(interface: Int, driver: String)]

    public init(onDevice: [String], onInterfaces: [(interface: Int, driver: String)]) {
        self.onDevice = onDevice
        self.onInterfaces = onInterfaces
    }

    public static func == (a: USBDriverClaim, b: USBDriverClaim) -> Bool {
        a.onDevice == b.onDevice
            && a.onInterfaces.map(\.interface) == b.onInterfaces.map(\.interface)
            && a.onInterfaces.map(\.driver) == b.onInterfaces.map(\.driver)
    }

    /// Drivers that actually stand between MSL and the hardware.
    ///
    /// `AppleUSBHostCompositeDevice` is excluded: it matches on composite
    /// devices only to publish their interfaces as separate services and
    /// then steps out of the way, so counting it as a claim would mark
    /// every multi-interface device - which is most of them - as needing
    /// root when it may well not. **This exclusion is reasoning from what
    /// the driver is for, not from a measurement**; it is the first thing
    /// to re-check against a real composite device.
    public static let benignDeviceDrivers: Set<String> = [
        "AppleUSBHostCompositeDevice",
        "IOUSBHostDevice",
    ]

    public var blockingDrivers: [String] {
        onDevice.filter { !Self.benignDeviceDrivers.contains($0) } + onInterfaces.map(\.driver)
    }

    /// True when nothing macOS ships is holding this device, so a plain
    /// unprivileged open should reach it. This is the "extremely weird
    /// hardware" case MSL supports natively.
    public var isFree: Bool { blockingDrivers.isEmpty }

    /// What to show in `msl usb list`. The raw IOKit class name rather than
    /// a friendlier label, deliberately: the routing above is a heuristic,
    /// and a name someone can paste into `ioreg` is worth more than a
    /// confident verdict that might be wrong.
    public var summary: String {
        let blocking = blockingDrivers
        if blocking.isEmpty { return "none - native" }
        var seen = Set<String>()
        return blocking.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

public enum USBDriverProbe {
    /// The pure half: given the class names IOKit reports, decide what is
    /// holding the device. Split out from the registry walk so it can be
    /// tested without any hardware at all - which matters, because the
    /// machine this was written on has never had a USB device attached.
    public static func classify(deviceDrivers: [String],
                                interfaceDrivers: [(interface: Int, driver: String)]) -> USBDriverClaim {
        USBDriverClaim(onDevice: deviceDrivers, onInterfaces: interfaceDrivers)
    }

    #if canImport(IOKit)
    /// Walks a device's children in the IOService plane.
    ///
    /// The shape IOKit gives is: `IOUSBHostDevice` → `IOUSBHostInterface`
    /// (one per interface) → whatever driver matched that interface. So a
    /// driver on an interface is a *grandchild* of the device, and looking
    /// only at the device's own children finds nothing for the common case
    /// of a USB-serial adapter.
    public static func claim(of device: io_service_t) -> USBDriverClaim {
        var deviceDrivers: [String] = []
        var interfaceDrivers: [(interface: Int, driver: String)] = []

        for child in children(of: device) {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, kIOUSBHostInterfaceClassName) != 0 {
                let number = Int((numberProperty(child, kUSBHostMatchingPropertyInterfaceNumber) ?? 0))
                for driver in children(of: child) {
                    defer { IOObjectRelease(driver) }
                    interfaceDrivers.append((number, name(of: driver)))
                }
            } else {
                deviceDrivers.append(name(of: child))
            }
        }
        return classify(deviceDrivers: deviceDrivers, interfaceDrivers: interfaceDrivers)
    }

    private static func children(of service: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var found: [io_service_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 { found.append(child) }
        return found
    }

    /// A DriverKit extension is published under a generic class -
    /// `IOUserService` and friends - so the class name alone would report
    /// every dext identically. `IOUserClass` carries the real one, and the
    /// bundle identifier is the last resort (`com.apple.DriverKit-AppleUSBFTDI`
    /// still says which driver it is).
    private static func name(of service: io_service_t) -> String {
        if let userClass = stringProperty(service, "IOUserClass"), !userClass.isEmpty {
            return userClass
        }
        var className = [CChar](repeating: 0, count: 128)
        if IOObjectGetClass(service, &className) == KERN_SUCCESS {
            let text = String(cString: className)
            // Generic DriverKit shells say nothing useful on their own.
            if !text.hasPrefix("IOUser") { return text }
            if let bundle = stringProperty(service, "CFBundleIdentifier"), !bundle.isEmpty {
                return bundle
            }
            return text
        }
        return "unknown"
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func numberProperty(_ service: io_service_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }
    #else
    public static func claim(of device: Int32) -> USBDriverClaim {
        USBDriverClaim(onDevice: [], onInterfaces: [])
    }
    #endif
}
