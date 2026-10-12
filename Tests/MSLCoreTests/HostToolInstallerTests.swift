import XCTest
@testable import MSLCore

/// Installing MSL's command-line tools out of whichever copy of MSL is
/// doing the installing.
final class HostToolInstallerTests: XCTestCase {
}

extension HostToolInstallerTests {
    /// An old MSL.app installs its own tools on every launch. Left in
    /// /Applications, opening it once silently replaced a working `mslhd`
    /// with a weeks-old one - the same staleness that had MSL shipping
    /// 17 September code while every build "succeeded".
    func testAnOlderCopyDoesNotReplaceANewerInstalledTool() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("msl-tools-\(UUID().uuidString)")
        let source = root.appendingPathComponent("old")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let old = source.appendingPathComponent("msl")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755,
                              .modificationDate: Date(timeIntervalSinceNow: -86_400)],
                             ofItemAtPath: old.path)

        let installed = root.appendingPathComponent("new-msl")
        try "new".write(to: installed, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)

        XCTAssertNotNil(HostToolInstaller.modified(old))
        XCTAssertLessThan(HostToolInstaller.modified(old)!, HostToolInstaller.modified(installed)!)
        try? fm.removeItem(at: root)
    }
}
