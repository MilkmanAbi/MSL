import XCTest
@testable import MSLCore

final class MacPermissionsTests: XCTestCase {
    func testAutomationStatusesMapToStates() {
        XCTAssertEqual(MacPermissions.automationState(osStatus: 0), .granted)
        XCTAssertEqual(MacPermissions.automationState(osStatus: -1743), .denied)
        XCTAssertEqual(MacPermissions.automationState(osStatus: -1744), .notDetermined)
        XCTAssertEqual(MacPermissions.automationState(osStatus: -600), .unavailable("Terminal isn't running"))
        if case .unavailable = MacPermissions.automationState(osStatus: -50) {} else {
            XCTFail("an unexpected status should be unavailable, not granted or denied")
        }
    }

    func testAReadWithNoErrorIsGranted() {
        XCTAssertEqual(MacPermissions.folderState(readError: nil), .granted)
    }

    func testPermissionErrorsAreDenied() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(MacPermissions.folderState(readError: cocoa), .denied)

        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertEqual(MacPermissions.folderState(readError: wrapped), .denied)

        XCTAssertEqual(MacPermissions.folderState(readError: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .denied)
    }

    func testOtherErrorsAreNotMistakenForADenial() {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        if case .unavailable = MacPermissions.folderState(readError: missing) {} else {
            XCTFail("a missing folder isn't a denied permission")
        }
    }

    func testReadingAReadableFolderIsGranted() {
        XCTAssertEqual(MacPermissions.requestRead(path: NSTemporaryDirectory()), .granted)
    }

    func testSettingsPanesOpenThePrivacySection() {
        for pane in MacPermissions.Pane.allCases {
            XCTAssertTrue(pane.url.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"))
        }
    }

    func testTheThreeGuardedFoldersAreCovered() {
        XCTAssertEqual(MacPermissions.protectedFolders.map(\.name), ["Desktop", "Documents", "Downloads"])
    }
}
