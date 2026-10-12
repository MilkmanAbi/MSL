import XCTest
@testable import MSLCore

/// `msl doctor --fix` deletes files, so the critical property is not that
/// it finds orphans - it is that it never proposes deleting anything
/// belonging to an instance that still exists.
final class DiagnosticsTests: XCTestCase {

    private var root: URL!
    private var appSupport: URL!
    private var apps: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-doctor-\(UUID().uuidString)")
        appSupport = root.appendingPathComponent("Application Support/MSL")
        apps = root.appendingPathComponent("Applications/MSL")
        bin = appSupport.appendingPathComponent("bin")
        for directory in [appSupport, apps, bin,
                          appSupport.appendingPathComponent("AppCatalog")] {
            try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func environment(instances: [String: GuestDistro], tools: [String] = []) -> Diagnostics.Environment {
        Diagnostics.Environment(
            appSupport: appSupport, generatedApps: apps, binDirectory: bin,
            instances: instances, expectedTools: tools, daemonRunning: true)
    }

    /// The safety property, stated directly.
    func testNeverProposesDeletingLiveInstanceState() throws {
        try touch(appSupport.appendingPathComponent("vm-work.machineid"))
        try touch(appSupport.appendingPathComponent("vm-gone.machineid"))
        try touch(appSupport.appendingPathComponent("AppCatalog/work/apps.json"))
        try touch(appSupport.appendingPathComponent("AppCatalog/gone/apps.json"))
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("work"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("gone"), withIntermediateDirectories: true)
        try touch(appSupport.appendingPathComponent(GuestDistro.alpine.diskImageFilename))

        let findings = Diagnostics.run(environment(instances: ["work": .alpine]))
        let removable = findings.flatMap { $0.removable }.map(\.path)

        XCTAssertFalse(removable.contains { $0.contains("work") },
                       "a registered instance's state must never be proposed for deletion")
        XCTAssertTrue(removable.contains { $0.hasSuffix("vm-gone.machineid") })
        XCTAssertTrue(removable.contains { $0.hasSuffix("AppCatalog/gone") })
        XCTAssertTrue(removable.contains { $0.hasSuffix("Applications/MSL/gone") })

        // And the disk image must never be a deletion candidate - it is
        // shared by every instance of that distro.
        XCTAssertFalse(removable.contains { $0.hasSuffix(".img") })
    }

    /// A generated `.app` for a removed instance sits in the user's
    /// Applications folder and looks like a working app, so it is a
    /// problem rather than a warning.
    func testOrphanedBundlesAreAProblem() throws {
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("gone"), withIntermediateDirectories: true)
        let findings = Diagnostics.run(environment(instances: [:]))
        let bundleFinding = findings.first { $0.title.contains("Applications pointing at") }
        XCTAssertEqual(bundleFinding?.severity, .problem)
    }

    /// An instance whose distro was never downloaded has nothing to clone,
    /// so it cannot start - a problem, and the advice is to install.
    func testInstanceWhoseDistroWasNeverDownloadedIsAProblem() {
        let findings = Diagnostics.run(environment(instances: ["work": .fedora]))
        XCTAssertTrue(findings.contains {
            $0.severity == .problem && $0.title.contains("fedora isn't downloaded")
        }, "expected a problem about the missing download, got: \(findings.map(\.title))")
    }

    func testMissingToolsAreReported() throws {
        try touch(bin.appendingPathComponent("msl"))
        let findings = Diagnostics.run(
            environment(instances: ["work": .alpine], tools: ["msl", "mslhd"]))
        let tools = try XCTUnwrap(findings.first { $0.title.contains("Host tools") })
        XCTAssertEqual(tools.severity, .problem)
        XCTAssertTrue(tools.detail.contains("mslhd"))
        XCTAssertFalse(tools.detail.contains("msl,"), "an installed tool must not be listed as missing")
    }

    func testCleanInstallationHasNothingRemovable() throws {
        try touch(appSupport.appendingPathComponent("vm-work.machineid"))
        try touch(appSupport.appendingPathComponent(GuestDistro.alpine.diskImageFilename))
        try touch(bin.appendingPathComponent("msl"))
        let findings = Diagnostics.run(environment(instances: ["work": .alpine], tools: ["msl"]))
        XCTAssertTrue(findings.flatMap { $0.removable }.isEmpty)
        XCTAssertFalse(findings.contains { $0.severity == .problem })
    }

    func testStateFileOwnership() {
        let known: Set<String> = ["work", "test-box"]
        XCTAssertEqual(Diagnostics.owner(ofStateFile: "vm-work.machineid", known: known), .owned("work"))
        XCTAssertEqual(Diagnostics.owner(ofStateFile: "vm-work.state", known: known), .owned("work"))
        XCTAssertEqual(Diagnostics.owner(ofStateFile: "vm-work-before-upgrade.state", known: known), .owned("work"))
        XCTAssertEqual(Diagnostics.owner(ofStateFile: "vm-gone.machineid", known: known), .orphaned("gone"))
        XCTAssertEqual(Diagnostics.owner(ofStateFile: "vm-gone-snap.state", known: known), .orphaned("gone-snap"))

        // Not per-instance state at all.
        for file in ["rootfs.img", "vmlinuz-virt", "instances.json", "mslhd.sock", "modloop-virt"] {
            XCTAssertEqual(Diagnostics.owner(ofStateFile: file, known: known), .notInstanceState, file)
        }
    }

    /// The bug this guards: `vm-test-box.state` is either the implicit
    /// snapshot of `test-box` or the `box` snapshot of `test`. Parsing the
    /// filename alone picks `test`, and with only `test-box` registered
    /// that reports a LIVE instance's saved state as garbage for `--fix` to
    /// delete. Hyphenated instance names are completely ordinary.
    func testHyphenatedInstanceStateIsNotMistakenForAnOrphan() throws {
        XCTAssertEqual(
            Diagnostics.owner(ofStateFile: "vm-test-box.state", known: ["test-box"]), .owned("test-box"))
        XCTAssertEqual(
            Diagnostics.owner(ofStateFile: "vm-test-box.machineid", known: ["test-box"]), .owned("test-box"))

        try touch(appSupport.appendingPathComponent("vm-test-box.state"))
        try touch(appSupport.appendingPathComponent("vm-test-box.machineid"))
        try touch(appSupport.appendingPathComponent(GuestDistro.alpine.diskImageFilename))

        let findings = Diagnostics.run(environment(instances: ["test-box": .alpine]))
        XCTAssertTrue(findings.flatMap { $0.removable }.isEmpty,
                      "a hyphen-named live instance must have nothing proposed for deletion")
    }
}

extension DiagnosticsTests {
    /// The whole morning of 2026-09-22: the MSL.app being used was from
    /// 16 September, so none of the week's fixes were in it - apps still ran
    /// as root, the app list was the old instance's, and the UI was the old
    /// one. Nothing in the app said how old it was.
    func testStaleAppIsReported() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("msl-stale-\(UUID().uuidString)")
        let macos = root.appendingPathComponent("MSL.app/Contents/MacOS")
        let tools = root.appendingPathComponent("bin")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let app = macos.appendingPathComponent("MSLApp")
        try "app".write(to: app, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -6 * 86_400)],
                             ofItemAtPath: app.path)
        let daemon = tools.appendingPathComponent("mslhd")
        try "tool".write(to: daemon, atomically: true, encoding: .utf8)

        let finding = Diagnostics.staleAppFinding(bundle: root.appendingPathComponent("MSL.app"),
                                                  toolsDirectory: tools)
        XCTAssertEqual(finding?.severity, .problem)
        XCTAssertEqual(finding?.title.contains("6 day(s) older"), true)
    }

    /// A current app is not a finding, and neither is a missing one.
    func testCurrentAppIsQuiet() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("msl-current-\(UUID().uuidString)")
        let macos = root.appendingPathComponent("MSL.app/Contents/MacOS")
        let tools = root.appendingPathComponent("bin")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "app".write(to: macos.appendingPathComponent("MSLApp"), atomically: true, encoding: .utf8)
        try "tool".write(to: tools.appendingPathComponent("mslhd"), atomically: true, encoding: .utf8)

        XCTAssertNil(Diagnostics.staleAppFinding(bundle: root.appendingPathComponent("MSL.app"),
                                                 toolsDirectory: tools))
        XCTAssertNil(Diagnostics.staleAppFinding(bundle: root.appendingPathComponent("Nope.app"),
                                                 toolsDirectory: tools))
    }
}
