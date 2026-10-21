import AppKit
import XCTest
@testable import MSLCore

/// Linux apps across a hibernate.
///
/// The closing half needs real AppKit processes, so what is tested here is
/// everything that decides *what* happens: the manifest, the name-to-command
/// resolution, the deduplication, and the reopen. Each test works in its own
/// temporary directory - a test that wrote to the real Application Support
/// once cost this project a user's `default-users.json`.
final class AppSessionRestoreTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func app(_ name: String, _ command: String) -> LinuxApp {
        LinuxApp(desktopPath: "/usr/share/applications/\(name).desktop",
                 name: name, command: command, comment: nil)
    }

    // MARK: - Which instance a host belongs to

    /// Every app host is a copy of the same binary in the same directory,
    /// so the only thing that says which instance it serves is its argv.
    func testHostInstanceComesFromArgv() {
        let line = "/Users/x/Library/Caches/MSL/AppShims/Krita --msl-app-host /tmp/k.sock --host-slot 3 --instance Milk"
        XCTAssertEqual(AppSessionRestore.instanceName(inCommandLine: line), "Milk")
    }

    /// A shim from a build older than the flag belongs to no instance.
    /// Attributing it to *every* instance is the bug: hibernating one
    /// instance would close it along with everything else.
    func testHostWithNoInstanceFlagBelongsToNoInstance() {
        let line = "/Users/x/Library/Caches/MSL/AppShims/Krita --msl-app-host /tmp/k.sock --host-slot 3"
        XCTAssertNil(AppSessionRestore.instanceName(inCommandLine: line))
    }

    /// The whole point of matching a token rather than searching for
    /// "--instance Milk" as a substring: an instance called `Milkium-2`
    /// starts with the name of one called `Milk`, and a substring search
    /// would hand `Milk`'s hibernate every one of `Milkium-2`'s apps.
    func testOneInstanceNameIsNotAPrefixOfAnother() {
        let line = "/Users/x/Library/Caches/MSL/AppShims/Krita --msl-app-host /tmp/k.sock --host-slot 3 --instance Milkium-2"
        XCTAssertEqual(AppSessionRestore.instanceName(inCommandLine: line), "Milkium-2")
        XCTAssertNotEqual(AppSessionRestore.instanceName(inCommandLine: line), "Milk")
    }

    /// `KERN_PROCARGS2` carries the process environment after the
    /// arguments, so the name is the one token after the flag and never
    /// "the rest of the line".
    func testEnvironmentAfterTheArgumentsIsNotPartOfTheName() {
        let line = "/Users/x/Library/Caches/MSL/AppShims/Krita --msl-app-host /tmp/k.sock"
            + " --host-slot 3 --instance Milk PATH=/usr/bin HOME=/Users/x MSL_X11_TRACE=1"
        XCTAssertEqual(AppSessionRestore.instanceName(inCommandLine: line), "Milk")
    }

    /// A flag with nothing after it must not read off the end.
    func testTrailingInstanceFlagWithNoValue() {
        XCTAssertNil(AppSessionRestore.instanceName(inCommandLine: "/bin/mslgui --instance"))
    }

    // MARK: - The manifest

    func testNothingIsStoredUntilSomethingIsOpen() {
        AppSessionRestore.save(.init(instance: "work", apps: []), appSupport: support)
        XCTAssertNil(AppSessionRestore.manifest(for: "work", appSupport: support))
    }

    func testRoundTrip() {
        let manifest = AppSessionRestore.Manifest(
            instance: "work", apps: [.init(name: "Blender", command: "blender")])
        XCTAssertTrue(AppSessionRestore.save(manifest, appSupport: support))
        let read = AppSessionRestore.manifest(for: "work", appSupport: support)
        XCTAssertEqual(read?.apps, manifest.apps)
        XCTAssertEqual(read?.instance, "work")
    }

    /// A new instance reusing a deleted one's name must not come up
    /// launching somebody else's apps - the same rule every other
    /// per-instance file follows.
    func testForgetting() {
        AppSessionRestore.save(.init(instance: "work", apps: [.init(name: "A", command: "a")]),
                               appSupport: support)
        AppSessionRestore.forget(instance: "work", appSupport: support)
        XCTAssertNil(AppSessionRestore.manifest(for: "work", appSupport: support))
    }

    func testInstancesDoNotShareAManifest() {
        AppSessionRestore.save(.init(instance: "a", apps: [.init(name: "A", command: "a")]), appSupport: support)
        AppSessionRestore.save(.init(instance: "b", apps: [.init(name: "B", command: "b")]), appSupport: support)
        AppSessionRestore.forget(instance: "a", appSupport: support)
        XCTAssertNil(AppSessionRestore.manifest(for: "a", appSupport: support))
        XCTAssertEqual(AppSessionRestore.manifest(for: "b", appSupport: support)?.apps.first?.name, "B")
    }

    // MARK: - Reopening

    func testReopenLaunchesEveryRecordedCommand() {
        AppSessionRestore.save(.init(instance: "work", apps: [
            .init(name: "Blender", command: "blender"),
            .init(name: "Chess", command: "gnome-chess"),
        ]), appSupport: support)

        var launched: [String] = []
        let result = AppSessionRestore.reopen(instance: "work", distro: .alpine,
                                              appSupport: support) { launched.append($0) }
        XCTAssertEqual(launched.sorted(), ["blender", "gnome-chess"])
        XCTAssertEqual(result.opened.sorted(), ["Blender", "Chess"])
        XCTAssertTrue(result.unknown.isEmpty)
    }

    /// The manifest is cleared *before* anything is launched: a relaunch
    /// that crashes must not try the same thing on every future resume.
    func testManifestIsClearedEvenIfALaunchBlowsUp() {
        AppSessionRestore.save(.init(instance: "work", apps: [.init(name: "A", command: "a")]),
                               appSupport: support)
        _ = AppSessionRestore.reopen(instance: "work", distro: .alpine, appSupport: support) { _ in }
        XCTAssertNil(AppSessionRestore.manifest(for: "work", appSupport: support))
    }

    /// An app MSL has no command for is reported, not silently dropped.
    func testUnknownCommandsAreReported() {
        AppSessionRestore.save(.init(instance: "work", apps: [
            .init(name: "Mystery", command: nil),
            .init(name: "Blender", command: "blender"),
        ]), appSupport: support)
        var launched: [String] = []
        let result = AppSessionRestore.reopen(instance: "work", distro: .alpine,
                                              appSupport: support) { launched.append($0) }
        XCTAssertEqual(launched, ["blender"])
        XCTAssertEqual(result.unknown, ["Mystery"])
    }

    func testReopenWithNothingRecordedDoesNothing() {
        var launched = 0
        let result = AppSessionRestore.reopen(instance: "work", distro: .alpine,
                                              appSupport: support) { _ in launched += 1 }
        XCTAssertEqual(launched, 0)
        XCTAssertTrue(result.opened.isEmpty)
    }

    // MARK: - The setting

    /// On by default, because the alternative is worse: without it a
    /// hibernated instance comes back with its apps alive in restored RAM
    /// but blind, holding singleton locks nothing can restart around.
    func testReopenIsOnByDefault() {
        XCTAssertTrue(MSLExperimentalSettings().reopenAppsAfterHibernate)
    }

    /// It is a per-instance override like every other experimental setting,
    /// so a shipment cannot reconfigure the receiving Mac.
    func testSettingCanBeOverriddenPerInstance() {
        var wanted = MSLExperimentalSettings()
        wanted.reopenAppsAfterHibernate = false
        InstanceExperiments.apply(wanted, to: "work",
                                  appWide: MSLExperimentalSettings(), appSupport: support)
        XCTAssertFalse(InstanceExperiments.effective(for: "work", appSupport: support)
            .reopenAppsAfterHibernate)
        XCTAssertTrue(InstanceExperiments.effective(for: "other", appSupport: support)
            .reopenAppsAfterHibernate)
    }

    // MARK: - Reopening *into state*

    /// The honest limit of a hibernate: MSL cannot hand a GUI app its
    /// windows back, but it can ask the app to restore the session it saved
    /// on the way out. Verified live with Chromium - without the flag it
    /// reopens on a blank tab, with it the search typed before the hibernate
    /// is still there.
    func testBrowsersAreRelaunchedIntoTheirSession() {
        XCTAssertEqual(AppSessionRestore.restoring("chromium"),
                       "chromium --restore-last-session")
        XCTAssertEqual(AppSessionRestore.restoring("/usr/bin/chromium"),
                       "/usr/bin/chromium --restore-last-session")
    }

    func testTheFlagIsNotAddedTwice() {
        let once = AppSessionRestore.restoring("chromium --restore-last-session")
        XCTAssertEqual(once, "chromium --restore-last-session")
    }

    /// Anything else is left exactly as it was - a flag invented for an app
    /// that does not take it would stop it starting at all.
    func testOtherAppsAreUntouched() {
        for command in ["galculator", "gnome-chess", "blender", "xterm -e top"] {
            XCTAssertEqual(AppSessionRestore.restoring(command), command)
        }
    }

    /// The executable decides, not the arguments: a file called
    /// `chrome-notes.txt` passed to an editor must not make it a browser.
    func testOnlyTheExecutableDecides() {
        XCTAssertEqual(AppSessionRestore.restoring("mousepad /home/abi/chrome-notes.txt"),
                       "mousepad /home/abi/chrome-notes.txt")
    }

    func testReopenAppliesTheRestoreFlag() {
        AppSessionRestore.save(.init(instance: "work", apps: [.init(name: "Chromium", command: "chromium")]),
                               appSupport: support)
        var launched: [String] = []
        _ = AppSessionRestore.reopen(instance: "work", distro: .alpine,
                                     appSupport: support) { launched.append($0) }
        XCTAssertEqual(launched, ["chromium --restore-last-session"])
    }
}
