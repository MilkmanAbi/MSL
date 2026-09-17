import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.usb
#endif

public enum USBWatcherError: Error, CustomStringConvertible {
    case notificationPortCreationFailed
    case matchingDictionaryCreationFailed
    case notificationRegistrationFailed(kern_return_t)

    public var description: String {
        switch self {
        case .notificationPortCreationFailed: return "IONotificationPortCreate failed"
        case .matchingDictionaryCreationFailed: return "IOServiceMatching failed"
        case .notificationRegistrationFailed(let code): return "IOServiceAddMatchingNotification failed (\(code))"
        }
    }
}

#if canImport(IOKit)
/// Watches for USB devices arriving/leaving, delivered on `queue`. No
/// entitlement needed - same as `USBDeviceEnumerator`, this only reads the
/// IOKit registry and asks for notifications, it doesn't open/claim
/// anything.
///
/// Known limitation, not yet worked around: on removal
/// (`kIOTerminatedNotification`), the service's registry properties may
/// already be gone by the time the callback fires, so the `USBDeviceInfo`
/// delivered to `onRemoval` can be incomplete (or the device may be
/// dropped from the callback entirely if `USBDeviceInfo.init?` fails). The
/// real fix is caching identity by registry entry ID at arrival time and
/// looking it up again at removal - not implemented yet, since there's no
/// USB hardware available in this environment to verify the removal path
/// against at all (see README).
public final class USBDeviceWatcher {
    public typealias Handler = (USBDeviceInfo) -> Void

    private var notificationPort: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0
    private let onArrival: Handler?
    private let onRemoval: Handler?

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.msl.usbd.watcher"),
        onArrival: Handler? = nil,
        onRemoval: Handler? = nil
    ) throws {
        self.onArrival = onArrival
        self.onRemoval = onRemoval

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw USBWatcherError.notificationPortCreationFailed
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // IOServiceAddMatchingNotification consumes exactly one reference
        // to the matching dictionary - arrival and removal each need their
        // own dictionary object, not a shared one.
        guard let arrivalMatching = IOServiceMatching(kIOUSBHostDeviceClassName),
              let removalMatching = IOServiceMatching(kIOUSBHostDeviceClassName) else {
            throw USBWatcherError.matchingDictionaryCreationFailed
        }

        var arrivalIter: io_iterator_t = 0
        let arrivalResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, arrivalMatching,
            Self.arrivalCallback, selfPtr, &arrivalIter
        )
        guard arrivalResult == KERN_SUCCESS else {
            throw USBWatcherError.notificationRegistrationFailed(arrivalResult)
        }
        arrivalIterator = arrivalIter
        // A notification iterator isn't armed until it's been drained once
        // after registration (per IOServiceAddMatchingNotification's own
        // doc comment) - this also delivers "already present" devices as
        // if they'd just arrived, which is the behavior we want (a watcher
        // started after a device is already plugged in should still learn
        // about it).
        Self.drainAndCollect(arrivalIter).forEach { onArrival?($0) }

        var removalIter: io_iterator_t = 0
        let removalResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, removalMatching,
            Self.removalCallback, selfPtr, &removalIter
        )
        guard removalResult == KERN_SUCCESS else {
            throw USBWatcherError.notificationRegistrationFailed(removalResult)
        }
        removalIterator = removalIter
        Self.drainAndCollect(removalIter).forEach { _ in } // just arm it, nothing was "removed" yet
    }

    deinit {
        if arrivalIterator != 0 { IOObjectRelease(arrivalIterator) }
        if removalIterator != 0 { IOObjectRelease(removalIterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    private static func drainAndCollect(_ iterator: io_iterator_t) -> [USBDeviceInfo] {
        var result: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = USBDeviceInfo(service: service) {
                result.append(info)
            }
        }
        return result
    }

    // Plain C function pointers (IOServiceMatchingCallback is not a block
    // type) - `self` travels via the refcon we passed at registration, not
    // via closure capture, so these can't capture any context themselves.
    private static let arrivalCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
        drainAndCollect(iterator).forEach { watcher.onArrival?($0) }
    }

    private static let removalCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let watcher = Unmanaged<USBDeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
        drainAndCollect(iterator).forEach { watcher.onRemoval?($0) }
    }
}
#endif
