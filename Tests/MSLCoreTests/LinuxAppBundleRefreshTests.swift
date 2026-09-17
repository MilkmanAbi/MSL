import XCTest
@testable import MSLCore

/// Generated app bundles must pick up launcher fixes. Each bundle embeds a
/// copy of `msl-applauncher`, and until 2026-09-14 nothing ever replaced it.
final class LinuxAppBundleRefreshTests: XCTestCase {
    private var root: URL!
    private var launcher: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("msl-refresh-\(UUID().uuidString)")
        root = base.appendingPathComponent("Applications/MSL")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = base.appendingPathComponent("msl-applauncher")
        try Data("new launcher".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent())
    }

    @discardableResult
    private func makeBundle(instance: String, name: String, executable: String, isMSL: Bool = true) throws -> URL {
        let bundle = root.appendingPathComponent(instance).appendingPathComponent("\(name).app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleName": name]
        if isMSL { plist["MSLInstance"] = instance; plist["MSLExec"] = name.lowercased() }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data(executable.utf8).write(to: macOS.appendingPathComponent(name))
        return bundle
    }

    private func executable(of bundle: URL, named name: String) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/MacOS/\(name)"), encoding: .utf8)
    }

    func testAStaleBundleGetsTheCurrentLauncherAndIsResigned() throws {
        let bundle = try makeBundle(instance: "debian", name: "XClock", executable: "old launcher")
        var signed: [URL] = []
        let count = LinuxAppBundle.refreshLaunchers(in: root, launcher: launcher, sign: { signed.append($0); return nil })
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try executable(of: bundle, named: "XClock"), "new launcher")
        XCTAssertEqual(signed.map(\.lastPathComponent), ["XClock.app"])
    }

    func testAnUpToDateBundleIsLeftAloneSignatureAndAll() throws {
        try makeBundle(instance: "debian", name: "XEyes", executable: "new launcher")
        var signed = 0
        let count = LinuxAppBundle.refreshLaunchers(in: root, launcher: launcher, sign: { _ in signed += 1; return nil })
        XCTAssertEqual(count, 0)
        XCTAssertEqual(signed, 0, "re-signing an unchanged bundle is churn for nothing")
    }

    func testBundlesMSLDidNotMakeAreNeverTouched() throws {
        let other = try makeBundle(instance: "debian", name: "SomethingElse", executable: "someone else's binary", isMSL: false)
        let count = LinuxAppBundle.refreshLaunchers(in: root, launcher: launcher, sign: { _ in nil })
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try executable(of: other, named: "SomethingElse"), "someone else's binary")
    }

    func testAFailedSignatureIsNotCountedAsRefreshed() throws {
        try makeBundle(instance: "arch", name: "Krita", executable: "old launcher")
        let count = LinuxAppBundle.refreshLaunchers(in: root, launcher: launcher, sign: { _ in "codesign failed" })
        XCTAssertEqual(count, 0)
    }

    func testNoInstalledLauncherIsANoOp() throws {
        let bundle = try makeBundle(instance: "debian", name: "XClock", executable: "old launcher")
        let missing = launcher.deletingLastPathComponent().appendingPathComponent("not-there")
        XCTAssertEqual(LinuxAppBundle.refreshLaunchers(in: root, launcher: missing, sign: { _ in nil }), 0)
        XCTAssertEqual(try executable(of: bundle, named: "XClock"), "old launcher")
    }
}
