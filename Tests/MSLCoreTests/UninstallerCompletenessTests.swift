import XCTest
@testable import MSLCore

/// Whether "uninstalled" means it.
///
/// These are about **completeness**, which is the only property that makes
/// an uninstaller worth trusting. The existing suite covers the plan's
/// shape; this covers the places that were missed, each of which was found
/// by uninstalling and then looking.
final class UninstallerCompletenessTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-uninstall-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func make(_ relative: String, bytes: Int = 16) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x4d, count: bytes).write(to: url)
        return url
    }

    private func locations(shared: URL? = nil, system: URL? = nil) -> Uninstaller.Locations {
        Uninstaller.Locations(
            home: root.appendingPathComponent("home"),
            appSupport: root.appendingPathComponent("appsupport"),
            appBundles: [],
            commandSymlink: nil,
            sharedSupport: shared,
            systemSupport: system)
    }

    // MARK: - The places that were missed

    func testTheAdminKeysAndContainersAreListed() throws {
        // **The worst thing to miss.** /Users/Shared/MSL holds the MSLAP
        // password, the signing keys, the vault secret - and the encrypted
        // containers, which can be gigabytes. It sits outside the home
        // folder on purpose (outside the guest's /mnt/mac view), which is
        // exactly why a sweep of the home folder never found it, and why
        // "uninstalled" could leave behind more than it removed.
        let shared = root.appendingPathComponent("shared")
        _ = try make("shared/mslap-admin.json")
        _ = try make("shared/vaults/abc.sparsebundle/token", bytes: 4096)

        // Keeping the Linux lists the pieces rather than the whole
        // directory, because the identity keys inside it must survive - see
        // `UninstallerTests`. Either way the containers and the admin
        // material are in the plan, with their size counted.
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations(shared: shared),
                                    instances: [])
        let listed = plan.removing.filter { $0.path.hasPrefix(shared.path) }
        XCTAssertFalse(listed.isEmpty, "the admin keys and encrypted disks are not in the plan")
        XCTAssertGreaterThan(listed.reduce(0) { $0 + $1.bytes }, 4000,
                             "their size is not being counted")

        // And removing everything still takes the directory whole.
        let all = Uninstaller.plan(mode: .everything, locations: locations(shared: shared),
                                   instances: [])
        XCTAssertTrue(all.removing.contains { $0.path == shared.path })
    }

    func testTheManagedPolicyIsListedAndSaysItNeedsPermission() throws {
        let system = root.appendingPathComponent("system")
        _ = try make("system/policy.json")
        let plan = Uninstaller.plan(mode: .keepLinux, locations: locations(system: system),
                                    instances: [])
        let item = plan.removing.first { $0.path == system.path }
        XCTAssertNotNil(item, "the enrolled policy is not in the plan")
        XCTAssertTrue(item?.note?.contains("password") == true, item?.note ?? "no note")
    }

    func testTheAdminsOwnMaterialGoesInBothModes() throws {
        // These are MSL's own records about who administers this Mac, not
        // the person's Linux - so "keep my Linux" keeps nothing of them.
        //
        // The identity keys that live in the same directory are the
        // exception and are covered by `UninstallerTests`: they are what
        // proves the kept instances are yours, so taking them would leave
        // every one of them unverifiable with no way back.
        for mode in Uninstaller.Mode.allCases {
            let shared = root.appendingPathComponent("shared-\(mode.rawValue)")
            _ = try make("shared-\(mode.rawValue)/mslap-admin.json")
            let plan = Uninstaller.plan(mode: mode, locations: locations(shared: shared),
                                        instances: [])
            let removedPaths = plan.removing.map(\.path)
            let takesTheAdminFile = removedPaths.contains(shared.path)
                || removedPaths.contains(shared.appendingPathComponent("mslap-admin.json").path)
            XCTAssertTrue(takesTheAdminFile,
                          "\(mode.rawValue) does not remove the admin keys")
            XCTAssertFalse(plan.keeping.contains { $0.path == shared.path })
        }
    }

    func testNothingIsListedWhenThoseLocationsDoNotExist() {
        // A plan that names paths that are not there reads as "MSL is
        // everywhere" and makes the real list harder to trust.
        let plan = Uninstaller.plan(
            mode: .keepLinux,
            locations: locations(shared: root.appendingPathComponent("nope"),
                                 system: root.appendingPathComponent("nope2")),
            instances: [])
        XCTAssertFalse(plan.removing.contains { $0.path.hasSuffix("nope") })
        XCTAssertFalse(plan.removing.contains { $0.path.hasSuffix("nope2") })
    }

    func testTheLiveLocationsPointAtTheRealPlaces() {
        // The plan is only as complete as this.
        let live = Uninstaller.Locations.live
        XCTAssertEqual(live.sharedSupport?.path, "/Users/Shared/MSL")
        XCTAssertEqual(live.systemSupport?.path, "/Library/Application Support/MSL")
    }

    // MARK: - The privileged finish

    func testOnlyPathsMSLInstallsCanBeRemovedAsAdministrator() {
        // This builds a command that runs as root. "Looks like ours" is
        // not good enough - it has to BE one of the handful of places MSL
        // puts things.
        for ours in ["/Applications/MSL.app", "/Applications/MSL Files.app",
                     "/usr/local/bin/msl", "/Library/Application Support/MSL"] {
            XCTAssertTrue(Uninstaller.privilegedPathIsOurs(ours), ours)
        }
        for theirs in ["/", "/System", "/Users/abinaash", "/Applications",
                      "/Applications/MSL.app/..", "/Library/Application Support",
                      "/usr/local/bin", "/Applications/Safari.app"] {
            XCTAssertFalse(Uninstaller.privilegedPathIsOurs(theirs), theirs)
        }
    }

    func testAPathThatIsNotOursRefusesInsteadOfRunning() {
        var report = Uninstaller.Report()
        report.needsSudo = ["/Users/abinaash/Documents"]
        var ran: String?
        let why = Uninstaller.finishPrivileged(report) { ran = $0 }
        XCTAssertNotNil(why, "a path outside MSL's own would have been removed as root")
        XCTAssertNil(ran, "the command ran anyway")
    }

    func testAQuoteInAPathRefusesRatherThanEscapingIt() {
        var report = Uninstaller.Report()
        report.needsSudo = ["/Applications/MSL.app'; rm -rf /"]
        var ran: String?
        XCTAssertNotNil(Uninstaller.finishPrivileged(report) { ran = $0 })
        XCTAssertNil(ran)
    }

    func testTheReceiptIsForgottenEvenWithNothingElseToRemove() throws {
        // Left behind, a reinstall thinks MSL is already there and skips
        // its own work.
        var ran: String?
        XCTAssertNil(Uninstaller.finishPrivileged(Uninstaller.Report()) { ran = $0 })
        XCTAssertTrue(ran?.contains("pkgutil --forget com.msl.app") == true, ran ?? "nothing ran")
    }

    func testEveryPathIsQuotedInTheCommand() {
        var report = Uninstaller.Report()
        report.needsSudo = ["/Applications/MSL Files.app"]
        var ran: String?
        XCTAssertNil(Uninstaller.finishPrivileged(report) { ran = $0 })
        XCTAssertTrue(ran?.contains("rm -rf '/Applications/MSL Files.app'") == true,
                      "a path with a space is not quoted: \(ran ?? "")")
    }

    func testTheAppleScriptQuotingSurvivesAwkwardCommands() {
        // Two layers deep - Swift, then AppleScript - and inlining it
        // produced a literal that would not even parse.
        let script = Uninstaller.appleScript(forShellCommand: "rm -rf '/a b' && echo \"x\"")
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertTrue(script.contains("\\\"x\\\""), "an inner quote is not escaped: \(script)")
    }
}
