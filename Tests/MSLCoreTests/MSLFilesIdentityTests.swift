import XCTest
@testable import MSLCore

/// MSL Files is its own app now; these pin the link mslhd uses to reach it.
final class MSLFilesIdentityTests: XCTestCase {
    func testRevealURLUsesTheFilesScheme() throws {
        let url = try XCTUnwrap(MSLFilesIdentity.revealURL(instance: "Milk", guestPath: "/etc/my folder", select: true))
        XCTAssertEqual(url.scheme, "msl-files")
        XCTAssertEqual(url.host, "files")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "instance" }?.value, "Milk")
        XCTAssertEqual(items.first { $0.name == "path" }?.value, "/etc/my folder")
        XCTAssertEqual(items.first { $0.name == "select" }?.value, "1")
    }

    func testLegacySchemeStillBuildable() throws {
        let url = try XCTUnwrap(MSLFilesIdentity.revealURL(scheme: MSLFilesIdentity.legacyScheme,
                                                            instance: "Milk", guestPath: "/", select: false))
        XCTAssertEqual(url.absoluteString, "msl://files?instance=Milk&path=/")
    }

    func testUninstallerKnowsAboutMSLFiles() {
        let bundles = Uninstaller.Locations.live.appBundles.map(\.lastPathComponent)
        XCTAssertTrue(bundles.contains("MSL Files.app"))
        XCTAssertTrue(bundles.contains("MSL.app"))
    }
}
