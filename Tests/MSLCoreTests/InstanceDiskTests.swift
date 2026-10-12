import XCTest
@testable import MSLCore

/// Each instance is its own machine.
///
/// Before this, every instance of a distro booted one `rootfs-<distro>.img`:
/// a second instance of a distro you already had was the same accounts and
/// the same files under a different name, and running two at once corrupted
/// the image (reported 2026-10-01).
final class InstanceDiskTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-disks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func writeBase(_ distro: GuestDistro, _ contents: String) throws {
        try Data(contents.utf8).write(to: distro.baseImageURL(appSupport: support))
    }

    private func read(_ instance: String) throws -> String {
        String(decoding: try Data(contentsOf: InstanceDisk.url(instance: instance, appSupport: support)),
               as: UTF8.self)
    }

    func testEachInstanceGetsItsOwnDisk() throws {
        try writeBase(.debian, "pristine")
        try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "play", distro: .debian, appSupport: support)

        XCTAssertNotEqual(InstanceDisk.url(instance: "work", appSupport: support),
                          InstanceDisk.url(instance: "play", appSupport: support))
        XCTAssertEqual(try read("work"), "pristine")
        XCTAssertEqual(try read("play"), "pristine")
    }

    /// The point of the whole change: writing in one must not reach the other.
    func testInstancesDoNotShareWrites() throws {
        try writeBase(.debian, "pristine")
        try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "play", distro: .debian, appSupport: support)

        try Data("work wrote this".utf8)
            .write(to: InstanceDisk.url(instance: "work", appSupport: support))

        XCTAssertEqual(try read("play"), "pristine", "one instance's writes reached another")
        XCTAssertEqual(String(decoding: try Data(contentsOf: GuestDistro.debian.baseImageURL(appSupport: support)),
                              as: UTF8.self),
                       "pristine", "an instance wrote through to the base")
    }

    /// A new instance must be a fresh installation, not a copy of whatever
    /// an existing one has done.
    func testANewInstanceIsClonedFromTheBaseNotFromASibling() throws {
        try writeBase(.arch, "pristine")
        try InstanceDisk.ensure(instance: "old", distro: .arch, appSupport: support)
        try Data("old made accounts".utf8)
            .write(to: InstanceDisk.url(instance: "old", appSupport: support))

        try InstanceDisk.ensure(instance: "fresh", distro: .arch, appSupport: support)
        XCTAssertEqual(try read("fresh"), "pristine")
    }

    func testEnsureIsIdempotentAndKeepsWhatIsThere() throws {
        try writeBase(.debian, "pristine")
        try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)
        try Data("changed".utf8).write(to: InstanceDisk.url(instance: "work", appSupport: support))
        try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)
        XCTAssertEqual(try read("work"), "changed", "ensure overwrote a disk that already existed")
    }

    func testWithoutABaseThereIsNothingToClone() throws {
        XCTAssertThrowsError(try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)) {
            guard case InstanceDisk.DiskError.baseMissing = $0 else {
                return XCTFail("expected .baseMissing, got \($0)")
            }
        }
    }

    func testRemovingOneInstanceLeavesTheBaseAndTheOthers() throws {
        try writeBase(.debian, "pristine")
        try InstanceDisk.ensure(instance: "work", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "play", distro: .debian, appSupport: support)

        InstanceDisk.remove(instance: "work", appSupport: support)
        XCTAssertFalse(InstanceDisk.exists(instance: "work", appSupport: support))
        XCTAssertTrue(InstanceDisk.exists(instance: "play", appSupport: support))
        XCTAssertTrue(GuestDistro.debian.baseIsInstalled(appSupport: support),
                      "removing an instance must not cost the next one a download")
    }

    func testStorageKeysAreDistinctPerInstanceAndCannotCollideWithADistro() {
        XCTAssertNotEqual(InstanceDisk.storageKey(instance: "work"),
                          InstanceDisk.storageKey(instance: "play"))
        for distro in GuestDistro.allCases {
            XCTAssertNotEqual(InstanceDisk.storageKey(instance: "work"), distro.diskImageFilename)
        }
    }
}

/// Carrying an existing machine across without anyone losing data, and
/// without anyone inheriting somebody else's.
final class InstanceLayoutMigrationTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    func testEveryInstanceKeepsWhatTheSharedDiskHad() throws {
        try Data("shared state".utf8).write(to: GuestDistro.arch.baseImageURL(appSupport: support))
        let result = InstanceLayoutMigration.runIfNeeded(
            appSupport: support, instances: ["one": .arch, "two": .arch])

        XCTAssertEqual(Set(result.migrated), ["one", "two"])
        for name in ["one", "two"] {
            XCTAssertEqual(
                String(decoding: try Data(contentsOf: InstanceDisk.url(instance: name, appSupport: support)),
                       as: UTF8.self),
                "shared state", "\(name) lost the data it had")
        }
    }

    /// The tainted base must go, or a "fresh" instance arrives with the old
    /// instances' accounts already in it.
    func testTheOldSharedImageIsRemovedSoNewInstancesAreNotTainted() throws {
        try Data("shared state".utf8).write(to: GuestDistro.arch.baseImageURL(appSupport: support))
        let result = InstanceLayoutMigration.runIfNeeded(
            appSupport: support, instances: ["one": .arch])

        XCTAssertEqual(result.basesRemoved, [.arch])
        XCTAssertFalse(GuestDistro.arch.baseIsInstalled(appSupport: support))
    }

    /// A hibernated guest's memory describes the disk as it was. After two
    /// instances have written one image, restoring it onto either clone is
    /// the mismatch that corrupts a filesystem.
    func testSavedStateIsDiscardedOnlyWhereInstancesHadBeenSharing() throws {
        try Data("shared".utf8).write(to: GuestDistro.arch.baseImageURL(appSupport: support))
        try Data("solo".utf8).write(to: GuestDistro.debian.baseImageURL(appSupport: support))
        for name in ["one", "two", "solo"] {
            try Data("memory".utf8).write(to: support.appendingPathComponent("vm-\(name).state"))
        }

        let result = InstanceLayoutMigration.runIfNeeded(
            appSupport: support, instances: ["one": .arch, "two": .arch, "solo": .debian])

        XCTAssertEqual(Set(result.statesDiscarded), ["one", "two"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("vm-solo.state").path),
            "a distro with one instance never had the problem and should keep its state")
    }

    func testItDoesNotRunWhileAnInstanceIsUp() throws {
        try Data("shared".utf8).write(to: GuestDistro.arch.baseImageURL(appSupport: support))
        let result = InstanceLayoutMigration.runIfNeeded(
            appSupport: support, instances: ["one": .arch], isRunning: { $0 == "one" })

        XCTAssertTrue(result.migrated.isEmpty)
        XCTAssertTrue(GuestDistro.arch.baseIsInstalled(appSupport: support))
        XCTAssertFalse(InstanceLayoutMigration.isDone(appSupport: support), "it must try again next time")
    }

    func testItOnlyRunsOnce() throws {
        try Data("shared".utf8).write(to: GuestDistro.arch.baseImageURL(appSupport: support))
        _ = InstanceLayoutMigration.runIfNeeded(appSupport: support, instances: ["one": .arch])
        XCTAssertTrue(InstanceLayoutMigration.isDone(appSupport: support))

        // A second run must not touch a disk the instance has since changed.
        try Data("instance has moved on".utf8)
            .write(to: InstanceDisk.url(instance: "one", appSupport: support))
        let again = InstanceLayoutMigration.runIfNeeded(appSupport: support, instances: ["one": .arch])
        XCTAssertTrue(again.migrated.isEmpty)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: InstanceDisk.url(instance: "one", appSupport: support)),
                   as: UTF8.self),
            "instance has moved on")
    }

    /// Each instance inherits the account it was already using, and the
    /// per-distro entry is dropped so a *new* instance cannot inherit one.
    func testRememberedAccountsMoveOntoTheInstancesThatUsedThem() throws {
        let registryURL = support.appendingPathComponent("default-users.json")
        let registry = DefaultUserRegistry(path: registryURL)
        try Data("{\"debian\":\"abi\"}".utf8).write(to: registryURL)

        try registry.migrate(instances: ["work": .debian, "play": .debian, "other": .arch])

        XCTAssertEqual(registry.defaultUser(forInstance: "work"), "abi")
        XCTAssertEqual(registry.defaultUser(forInstance: "play"), "abi")
        XCTAssertNil(registry.defaultUser(forInstance: "other"))
        XCTAssertNil(registry.defaultUser(forInstance: "debian"),
                     "the per-distro entry must go, or a new instance inherits it")
    }
}

/// What removing things takes with it.
///
/// Two different promises: removing one instance must never cost the next
/// one a download, and removing a *distribution* must leave nothing of it
/// behind - neither the base nor any instance made from it.
final class DistroAndInstanceRemovalTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    private func base(_ distro: GuestDistro, _ contents: String = "base") throws {
        try Data(contents.utf8).write(to: distro.baseImageURL(appSupport: support))
    }

    func testRemovingOneInstanceKeepsTheDownloadForTheNextOne() throws {
        try base(.debian)
        try InstanceDisk.ensure(instance: "one", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "two", distro: .debian, appSupport: support)

        InstanceDisk.remove(instance: "one", appSupport: support)

        XCTAssertFalse(InstanceDisk.exists(instance: "one", appSupport: support))
        XCTAssertTrue(InstanceDisk.exists(instance: "two", appSupport: support),
                      "removing one instance took another instance's disk")
        XCTAssertTrue(DistroInstallation.isInstalled(.debian, in: support),
                      "removing an instance must never cost the next one a download")
    }

    func testRemovingADistroTakesTheBaseAndEveryInstanceOfIt() throws {
        try base(.debian)
        try base(.arch)
        try InstanceDisk.ensure(instance: "one", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "two", distro: .debian, appSupport: support)
        try InstanceDisk.ensure(instance: "keep", distro: .arch, appSupport: support)

        DistroInstallation.deleteFiles(for: .debian, in: support, instanceDisks: ["one", "two"])

        XCTAssertFalse(DistroInstallation.isInstalled(.debian, in: support))
        XCTAssertFalse(InstanceDisk.exists(instance: "one", appSupport: support))
        XCTAssertFalse(InstanceDisk.exists(instance: "two", appSupport: support))
        // Another distribution is untouched.
        XCTAssertTrue(DistroInstallation.isInstalled(.arch, in: support))
        XCTAssertTrue(InstanceDisk.exists(instance: "keep", appSupport: support))
    }

    /// The base is never booted, so nothing an instance does can reach it.
    func testWritingInAnInstanceNeverReachesTheBase() throws {
        try base(.debian, "pristine")
        try InstanceDisk.ensure(instance: "one", distro: .debian, appSupport: support)
        try Data("instance wrote this".utf8)
            .write(to: InstanceDisk.url(instance: "one", appSupport: support))

        let baseContents = String(
            decoding: try Data(contentsOf: GuestDistro.debian.baseImageURL(appSupport: support)),
            as: UTF8.self)
        XCTAssertEqual(baseContents, "pristine",
                       "the base was written through - every later instance would inherit it")
    }
}
