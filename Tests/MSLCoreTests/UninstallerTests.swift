import XCTest
@testable import MSLCore

/// Every test builds a whole fake Mac in a temporary directory - home,
/// Application Support, an app bundle - and runs the real planner and the
/// real remover against it. Nothing here may touch the machine it runs on,
/// which is also why `Actions` is always `.none` or a recording stub.
final class UninstallerTests: XCTestCase {
    private var root: URL!
    private var locations: Uninstaller.Locations!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uninstaller-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support/MSL")
        locations = Uninstaller.Locations(
            home: home,
            appSupport: support,
            appBundles: [root.appendingPathComponent("Applications/MSL.app")])
        try makeFakeInstall()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL, _ contents: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A believable MSL install: the Mac side, the Linux side, and the
    /// guest helpers that share `bin/` with MSL's own tools.
    private func makeFakeInstall() throws {
        let home = locations.home
        let support = locations.appSupport
        try write(locations.appBundles[0].appendingPathComponent("Contents/MacOS/MSLApp"))
        for label in ["com.msl.mslhd", "com.msl.login.terminal", "com.msl.login.app"] {
            try write(home.appendingPathComponent("Library/LaunchAgents/\(label).plist"))
        }
        try write(home.appendingPathComponent("Applications/MSL/debian/Krita.app/Contents/MacOS/launcher"))
        try write(home.appendingPathComponent("Library/Caches/MSL/AppShims/Krita"))
        try write(home.appendingPathComponent("Library/Logs/MSL/mslhd.log"))
        try write(home.appendingPathComponent("Library/Preferences/com.msl.app.plist"))

        for tool in ["msl", "mslhd", "mslgui", "msl-applauncher", "mslhd.pre-power-hardening", "virtualization.entitlements"] {
            try write(support.appendingPathComponent("bin/\(tool)"))
        }
        for helper in ["x11tunnel", "fileopsd", "shellinit"] {
            try write(support.appendingPathComponent("bin/\(helper)"))
        }
        try write(support.appendingPathComponent("rootfs-debian.img"), String(repeating: "d", count: 4096))
        try write(support.appendingPathComponent("disk-Image"), String(repeating: "k", count: 2048))
        try write(support.appendingPathComponent("instances.json"), #"{"debian":"debian"}"#)
        try write(support.appendingPathComponent("default-users.json"), #"{"debian":"abi"}"#)
        try write(support.appendingPathComponent("Custom Images/mine/rootfs.img"), String(repeating: "c", count: 1024))
    }

    private func labels(_ items: [Uninstaller.Item]) -> [String] { items.map(\.label) }

    // MARK: - Planning

    func testKeepLinuxRemovesTheMacSideAndKeepsTheLinuxSide() {
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)

        XCTAssertTrue(labels(plan.removing).contains("MSL.app"))
        XCTAssertTrue(labels(plan.removing).contains("MSL's own programs"))
        XCTAssertTrue(labels(plan.removing).contains("Linux apps added to your Mac"))
        XCTAssertFalse(labels(plan.removing).contains("Linux disk images"))
        XCTAssertFalse(labels(plan.removing).contains("Custom images"))

        XCTAssertTrue(labels(plan.keeping).contains("Linux disk images"))
        XCTAssertTrue(labels(plan.keeping).contains("Custom images"))
        XCTAssertTrue(labels(plan.keeping).contains("Instances, accounts and settings"))
        // Settings stay, so a reinstall doesn't switch back on what someone
        // deliberately switched off.
        XCTAssertTrue(labels(plan.keeping).contains("Your MSL settings"))
        XCTAssertGreaterThan(plan.keepingBytes, 0)
    }

    func testEverythingMovesTheLinuxSideIntoRemovingAndWarns() {
        let plan = Uninstaller.plan(mode: .everything, locations: locations)

        XCTAssertTrue(labels(plan.removing).contains("Linux disk images"))
        XCTAssertTrue(labels(plan.removing).contains("Custom images"))
        XCTAssertTrue(labels(plan.removing).contains("Your MSL settings"))
        XCTAssertTrue(plan.keeping.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("debian") })
        XCTAssertEqual(plan.instances, ["debian"])
    }

    func testPlanSkipsWhatIsNotThere() throws {
        try FileManager.default.removeItem(at: locations.appBundles[0])
        try FileManager.default.removeItem(at: locations.home.appendingPathComponent("Library/Caches/MSL"))
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        XCTAssertFalse(labels(plan.removing).contains("MSL.app"))
        XCTAssertFalse(labels(plan.removing).contains("Caches"))
    }

    // MARK: - bin/, which is shared with the guest

    func testHostToolsNeverIncludeTheGuestHelpers() {
        let found = Uninstaller.hostTools(in: locations.appSupport.appendingPathComponent("bin"))
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["msl", "msl-applauncher", "mslgui", "mslhd",
                               "mslhd.pre-power-hardening", "virtualization.entitlements"])
        XCTAssertFalse(found.contains("x11tunnel"))
        XCTAssertFalse(found.contains("fileopsd"))
        XCTAssertFalse(found.contains("shellinit"))
    }

    // MARK: - Performing

    func testDryRunChangesNothing() {
        let plan = Uninstaller.plan(mode: .everything, locations: locations)
        let report = Uninstaller.perform(plan, locations: locations, dryRun: true, actions: .none)

        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.appSupport.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.appBundles[0].path))
        XCTAssertTrue(report.steps.contains { $0.hasPrefix("dry run") })
    }

    func testKeepLinuxLeavesEveryImageAndGuestHelperInPlace() {
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        let report = Uninstaller.perform(plan, locations: locations, actions: .none)
        let fm = FileManager.default
        let support = locations.appSupport

        XCTAssertTrue(report.succeeded, "\(report.failed)")
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("rootfs-debian.img").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("Custom Images/mine/rootfs.img").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("instances.json").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("bin/x11tunnel").path))
        XCTAssertTrue(fm.fileExists(atPath: locations.home.appendingPathComponent("Library/Preferences/com.msl.app.plist").path))

        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("bin/mslhd").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("bin/mslhd.pre-power-hardening").path))
        XCTAssertFalse(fm.fileExists(atPath: locations.appBundles[0].path))
        XCTAssertFalse(fm.fileExists(atPath: locations.home.appendingPathComponent("Applications/MSL").path))
        XCTAssertFalse(fm.fileExists(atPath: locations.home.appendingPathComponent("Library/LaunchAgents/com.msl.mslhd.plist").path))
    }

    func testEverythingRemovesApplicationSupportToo() {
        let plan = Uninstaller.plan(mode: .everything, locations: locations)
        let report = Uninstaller.perform(plan, locations: locations, actions: .none)
        XCTAssertTrue(report.succeeded, "\(report.failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.appSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.home.appendingPathComponent("Library/Preferences/com.msl.app.plist").path))
    }

    /// The order is the safety property: unmount, then shut down, then stop
    /// the service - and MSL's own programs last, so a failure part-way
    /// still leaves a working `msl` to retry with.
    func testOrderUnmountsThenShutsDownThenRemovesToolsLast() {
        let recorder = ActionRecorder()
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        let report = Uninstaller.perform(plan, locations: locations, actions: recorder.actions)

        let calls = recorder.calls
        XCTAssertEqual(calls.first, "unmount")
        XCTAssertEqual(calls.dropFirst().first, "shutdown(debian)")
        XCTAssertTrue(calls.contains("bootout(com.msl.mslhd)"))

        let removedTool = report.removed.firstIndex { $0.hasSuffix("/bin/mslhd") }
        let removedApp = report.removed.firstIndex { $0.hasSuffix("MSL.app") }
        let removedLogs = report.removed.firstIndex { $0.hasSuffix("Logs/MSL") }
        XCTAssertNotNil(removedTool)
        XCTAssertNotNil(removedApp)
        XCTAssertNotNil(removedLogs)
        XCTAssertLessThan(removedLogs!, removedApp!)
        XCTAssertLessThan(removedApp!, removedTool!)
    }

    func testShutdownIsSkippedWhenNothingIsRegistered() throws {
        try FileManager.default.removeItem(at: locations.appSupport.appendingPathComponent("instances.json"))
        let recorder = ActionRecorder()
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        XCTAssertTrue(plan.instances.isEmpty)
        Uninstaller.perform(plan, locations: locations, actions: recorder.actions)
        XCTAssertFalse(recorder.calls.contains { $0.hasPrefix("shutdown") })
    }

    func testEverythingForgetsSSHEntriesBeforeDeletingTheFolder() {
        let recorder = ActionRecorder()
        let plan = Uninstaller.plan(mode: .everything, locations: locations)
        Uninstaller.perform(plan, locations: locations, actions: recorder.actions)
        XCTAssertTrue(recorder.calls.contains("forgetSSH(debian)"))
    }

    /// The installer puts `/usr/local/bin/msl` on PATH as root. The plan has
    /// to list it, and `perform` has to survive not being allowed to remove
    /// it - always against an injected path, never the real one.
    func testCommandSymlinkIsListedAndRemoved() throws {
        let link = root.appendingPathComponent("usr-local-bin/msl")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: locations.appBundles[0].appendingPathComponent("Contents/MacOS/msl"))
        locations.commandSymlink = link

        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        XCTAssertTrue(labels(plan.removing).contains("The msl command"))

        let report = Uninstaller.perform(plan, locations: locations, actions: .none)
        XCTAssertTrue(report.needsSudo.isEmpty, "a writable link should just be removed")
        XCTAssertFalse(Uninstaller.linkExists(link), "the link should be gone")
    }

    /// It is removed after MSL.app, so by then it dangles - and `fileExists`
    /// follows symlinks and would say it isn't there.
    func testDanglingCommandSymlinkIsStillFound() throws {
        let link = root.appendingPathComponent("usr-local-bin/msl")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("gone/msl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(Uninstaller.linkExists(link))
    }

    func testNoCommandSymlinkWhenNoneIsGiven() {
        XCTAssertNil(locations.commandSymlink)
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations)
        XCTAssertFalse(labels(plan.removing).contains("The msl command"))
    }

    func testSizeIsAllocatedSizeAndCountsWholeTrees() {
        let images = Uninstaller.size(of: locations.appSupport.appendingPathComponent("Custom Images"))
        XCTAssertGreaterThan(images, 0)
        XCTAssertEqual(Uninstaller.size(of: locations.appSupport.appendingPathComponent("nothing-here")), 0)
    }
}

/// Records what `perform` asked the system to do, without doing any of it.
private final class ActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: String) {
        lock.lock(); recorded.append(call); lock.unlock()
    }

    var actions: Uninstaller.Actions {
        Uninstaller.Actions(
            unmountGuestVolumes: { [self] in record("unmount") },
            shutdownInstances: { [self] names in record("shutdown(\(names.joined(separator: ",")))") },
            bootout: { [self] label in record("bootout(\(label))") },
            forgetSSH: { [self] instance in record("forgetSSH(\(instance))") })
    }
}
