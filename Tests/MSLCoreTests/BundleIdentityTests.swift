import AppKit
import XCTest
@testable import MSLCore

/// The same application packaged twice must become two bundles.
///
/// Once Flatpak and Snap directories are scanned, GIMP legitimately appears
/// as `/usr/share/applications/gimp.desktop` and as
/// `/var/lib/flatpak/.../org.gimp.GIMP.desktop` with an identical `Name=`.
/// If the bundle path is derived from `Name` alone they collide: adding the
/// second overwrites the first, and `installedApps` reports one name for two
/// tiles, so both show as installed and removing either removes both.
final class BundleIdentityTests: XCTestCase {

    private let instance = "msl-test-\(UUID().uuidString.prefix(8))"

    override func tearDownWithError() throws {
        try? LinuxAppBundle.removeAll(instance: instance)
    }

    func testFlatpakAndSystemCopiesGetDistinctBundles() throws {
        // Generating a bundle copies the installed launcher, so this needs
        // MSL's tools on this Mac - skip rather than fail on one without them.
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: MSLPaths.tool("msl-applauncher").path),
                          "msl-applauncher isn't installed on this Mac")
        let system = LinuxApp(
            desktopPath: "/usr/share/applications/gimp.desktop", name: "GIMP",
            command: "'/usr/bin/gimp'", comment: nil, source: .system)
        let flatpak = LinuxApp(
            desktopPath: "/var/lib/flatpak/exports/share/applications/org.gimp.GIMP.desktop",
            name: "GIMP", command: "'/usr/bin/flatpak' 'run' 'org.gimp.GIMP'",
            comment: nil, source: .flatpak)

        XCTAssertEqual(system.qualifiedName, "GIMP")
        XCTAssertEqual(flatpak.qualifiedName, "GIMP (Flatpak)")

        func descriptor(_ app: LinuxApp) -> LinuxAppBundle.Descriptor {
            LinuxAppBundle.Descriptor(
                instance: instance, distro: .alpine, displayName: app.qualifiedName,
                command: app.command, icon: LinuxAppCatalog.monogram(for: app.name))
        }

        let first = try LinuxAppBundle.generate(descriptor(system))
        let second = try LinuxAppBundle.generate(descriptor(flatpak))

        XCTAssertNotEqual(first, second, "two packagings must not share one bundle path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path),
                      "the Flatpak copy must not have overwritten the system one")
        XCTAssertEqual(LinuxAppBundle.installedApps(instance: instance).count, 2)

        // And each must launch its own command, not the other's.
        let plist = second.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(parsed["MSLExec"] as? String, "'/usr/bin/flatpak' 'run' 'org.gimp.GIMP'")

        // Removing one must leave the other alone.
        try LinuxAppBundle.remove(descriptor(system))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
