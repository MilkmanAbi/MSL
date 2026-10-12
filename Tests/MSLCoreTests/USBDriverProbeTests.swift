import XCTest
@testable import MSLCore

/// The classifier decides whether a device is passed through for free or
/// taken from macOS with a password, so getting it wrong in the optimistic
/// direction produces the worst failure available: a device that opens,
/// answers control transfers, and then has no working endpoints because the
/// driver on its *interfaces* never let go.
///
/// The IOKit walk needs hardware; this half does not, which is why
/// `USBDriverProbe.classify` is split out from it.
final class USBDriverProbeTests: XCTestCase {

    func testADeviceNobodyWantsIsNative() {
        // The case MSL supports with no privileges at all: a vendor-specific
        // board macOS has never heard of.
        let claim = USBDriverProbe.classify(deviceDrivers: [], interfaceDrivers: [])
        XCTAssertTrue(claim.isFree)
        XCTAssertEqual(claim.summary, "none - native")
    }

    func testADriverOnAnInterfaceStillBlocks() {
        // The one that matters. A plain open of the *device* can succeed
        // while macOS holds its interfaces - so looking only at the device's
        // own children would call an FTDI adapter native, attach it, and
        // hand the guest a device with no pipes.
        let claim = USBDriverProbe.classify(
            deviceDrivers: [],
            interfaceDrivers: [(0, "AppleUSBFTDI")])
        XCTAssertFalse(claim.isFree)
        XCTAssertEqual(claim.summary, "AppleUSBFTDI")
    }

    func testCompositeShimIsNotAClaim() {
        // AppleUSBHostCompositeDevice matches on a composite device only to
        // publish its interfaces as separate services, then steps aside.
        // Counting it would mark most multi-interface devices as needing
        // root when they may not.
        let claim = USBDriverProbe.classify(
            deviceDrivers: ["AppleUSBHostCompositeDevice"],
            interfaceDrivers: [])
        XCTAssertTrue(claim.isFree)
    }

    func testCompositeShimDoesNotHideARealDriver() {
        let claim = USBDriverProbe.classify(
            deviceDrivers: ["AppleUSBHostCompositeDevice"],
            interfaceDrivers: [(0, "AppleUSBACM"), (1, "AppleUSBCDC")])
        XCTAssertFalse(claim.isFree)
        XCTAssertEqual(claim.summary, "AppleUSBACM, AppleUSBCDC")
    }

    func testOneDriverAcrossSeveralInterfacesIsNamedOnce() {
        // A four-port adapter would otherwise read
        // "AppleUSBFTDI, AppleUSBFTDI, AppleUSBFTDI, AppleUSBFTDI".
        let claim = USBDriverProbe.classify(
            deviceDrivers: [],
            interfaceDrivers: (0..<4).map { ($0, "AppleUSBFTDI") })
        XCTAssertEqual(claim.summary, "AppleUSBFTDI")
        XCTAssertFalse(claim.isFree)
    }

    func testMassStorageBlocks() {
        // A flash drive: the obvious thing someone tries first, and it does
        // need a password.
        let claim = USBDriverProbe.classify(
            deviceDrivers: [],
            interfaceDrivers: [(0, "IOUSBMassStorageDriver")])
        XCTAssertFalse(claim.isFree)
    }

    func testDextBundleIdentifiersSurviveAsNames() {
        // DriverKit extensions are published under a generic IOUser* class,
        // so the probe falls back to the bundle id. It is not pretty, but
        // "com.apple.DriverKit-AppleUSBFTDI" still says which driver it is,
        // and it can be pasted into ioreg.
        let claim = USBDriverProbe.classify(
            deviceDrivers: [],
            interfaceDrivers: [(0, "com.apple.DriverKit-AppleUSBFTDI")])
        XCTAssertEqual(claim.summary, "com.apple.DriverKit-AppleUSBFTDI")
        XCTAssertFalse(claim.isFree)
    }

    func testIOUSBHostDeviceItselfIsNotADriver() {
        // The device's own class can turn up as a child in some registry
        // shapes; it is not something holding the device.
        let claim = USBDriverProbe.classify(deviceDrivers: ["IOUSBHostDevice"], interfaceDrivers: [])
        XCTAssertTrue(claim.isFree)
    }

    func testAttachmentWireLineRoundTripsTheToken() {
        // `msl usb detach` matches on this token, so it has to survive the
        // trip through the daemon intact.
        let attachment = USBAttachment(device: "00100000", displayName: "Weird Board", captured: true)
        XCTAssertEqual(attachment.wireLine, "00100000 CAPTURED Weird Board")
        let open = USBAttachment(device: "synthetic", displayName: "MSL Virtual Test Device", captured: false)
        XCTAssertEqual(open.wireLine, "synthetic OPEN MSL Virtual Test Device")
    }
}

/// The helper that `msl usb attach` runs under `sudo` must not be writable
/// by anything but root - and the obvious copy, in Application Support, is
/// writable by a Linux guest, because MSL mounts the Mac's home at
/// `/mnt/mac` read-write.
final class USBHelperLocatorTests: XCTestCase {

    func testSystemDirectoriesAreTrusted() {
        // `/Applications` ships as drwxrwxr-x root:admin on every Mac, so
        // "not group-writable" is too strict to be usable - it would refuse
        // the only trustworthy copy of the helper there is.
        XCTAssertNil(USBHelperLocator.firstUnsafeComponent(of: "/Applications"))
        XCTAssertNil(USBHelperLocator.firstUnsafeComponent(of: "/usr/bin/sudo"))
    }

    func testTheUsersHomeIsNotTrusted() {
        // This is the whole point: a guest can write here, so MSL must
        // refuse to run anything under it as root.
        let home = NSHomeDirectory()
        let candidate = home + "/Library/Application Support/MSL/bin/msl-usbd"
        let unsafe = USBHelperLocator.firstUnsafeComponent(of: candidate)
        XCTAssertNotNil(unsafe, "the user's home must never pass the root-ownership check")
        // It should name the component that actually fails, not the leaf.
        XCTAssertTrue(candidate.hasPrefix(unsafe ?? "/nope"))
    }

    func testAMissingPathIsNotTrusted() {
        // A path that cannot be stat'd is refused rather than assumed safe.
        XCTAssertNotNil(USBHelperLocator.firstUnsafeComponent(of: "/Applications/NoSuchApp.app/x"))
    }
}
