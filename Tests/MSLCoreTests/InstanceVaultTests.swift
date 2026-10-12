import XCTest
import CryptoKit
@testable import MSLCore

/// The encrypted container: the passphrase derivation, and a real
/// create/attach/write/detach cycle.
///
/// The cycle test touches `hdiutil` and so the real filesystem, but never
/// `/Users/Shared` - it points the container at a temporary directory.
/// It is here rather than left to manual testing because the one thing that
/// must not regress is that **a container does not open without its
/// passphrase**, and nothing short of running it proves that.
final class InstanceVaultTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()

    private func identity(lineage: String? = nil, serial: String? = nil,
                          origin: String = "Company") -> InstanceIdentity {
        InstanceIdentity(lineage: lineage ?? InstanceIdentity.randomBase32(26),
                         generation: "0", serial: serial ?? InstanceIdentity.randomBase32(13),
                         issuer: MSLAPSigning.keyID(for: key.publicKey), origin: origin,
                         machine: String(repeating: "a", count: 16), born: 1_760_000_000)
    }

    // MARK: - The passphrase is derived, which is what ties this to plan 31

    func testThePassphraseIsStableForOneIdentity() throws {
        let one = identity()
        XCTAssertEqual(try InstanceVault.passphrase(for: one),
                       try InstanceVault.passphrase(for: one),
                       "the same identity derived two different passphrases")
    }

    func testEveryFieldThePassphraseDependsOnChangesIt() throws {
        // **A container copied elsewhere or re-registered under a different
        // identity must derive a different passphrase and not open.** That
        // is the whole link between the two plans, so each input is
        // checked rather than assumed.
        let base = identity(lineage: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
                            serial: "bbbbbbbbbbbbb", origin: "Company")
        let reference = try InstanceVault.passphrase(for: base)

        let otherLineage = identity(lineage: "cccccccccccccccccccccccccc",
                                    serial: "bbbbbbbbbbbbb", origin: "Company")
        let otherSerial = identity(lineage: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
                                   serial: "ddddddddddddd", origin: "Company")
        let otherOrigin = identity(lineage: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
                                   serial: "bbbbbbbbbbbbb", origin: "Other")
        for (label, other) in [("lineage", otherLineage), ("serial", otherSerial),
                               ("origin", otherOrigin)] {
            XCTAssertNotEqual(try InstanceVault.passphrase(for: other), reference,
                              "changing the \(label) did not change the passphrase")
        }
    }

    func testThePassphraseIsSafeToHandToATool() throws {
        // It goes to `diskutil` on stdin, so it must not contain a newline
        // - which would terminate the read early and silently use a
        // shorter passphrase.
        for _ in 0..<50 {
            let value = try InstanceVault.passphrase(for: identity())
            XCTAssertFalse(value.contains(where: \.isNewline), value)
            XCTAssertFalse(value.isEmpty)
            XCTAssertGreaterThan(value.count, 32)
        }
    }

    func testGenerationDeliberatelyDoesNotChangeThePassphrase() throws {
        // A clone shares its parent's container - they are the same
        // lineage, and the container is named by lineage so a rename
        // cannot orphan it. Including the generation would mean every
        // clone needed a container of its own.
        let parent = identity(lineage: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
                              serial: "bbbbbbbbbbbbb")
        var child = parent
        child = InstanceIdentity(lineage: parent.lineage, generation: "0.1",
                                 serial: parent.serial, issuer: parent.issuer,
                                 origin: parent.origin, machine: parent.machine,
                                 born: parent.born)
        XCTAssertEqual(try InstanceVault.passphrase(for: child),
                       try InstanceVault.passphrase(for: parent))
    }

    // MARK: - Naming

    func testTwoInstancesOfOneLineageGetTheirOwnContainers() {
        // **The bug this replaced.** Containers were first named by
        // LINEAGE, and a clone shares its parent's - so protecting both an
        // image and a copy of it would have had them fighting over one
        // container, each wanting `rootfs.img` inside it. Found while
        // setting up the VM-level test, which would have hit it.
        let parent = identity(lineage: "aaaaaaaaaaaaaaaaaaaaaaaaaa", serial: "bbbbbbbbbbbbb")
        let clone = InstanceIdentity(lineage: parent.lineage, generation: "0.1",
                                     serial: "ccccccccccccc", issuer: parent.issuer,
                                     origin: "Copy", machine: parent.machine, born: parent.born)
        XCTAssertNotEqual(InstanceVault.url(serial: parent.serial),
                          InstanceVault.url(serial: clone.serial),
                          "an image and a copy of it share one container")
    }

    func testARenameCannotOrphanAContainer() {
        // `InstanceIdentityStore.reSign` keeps the serial deliberately, so
        // the container a renamed instance looks for is the one it had.
        let one = identity(origin: "Company")
        let renamed = InstanceIdentity(lineage: one.lineage, generation: one.generation,
                                       serial: one.serial, issuer: one.issuer,
                                       origin: one.origin, machine: one.machine, born: one.born)
        XCTAssertEqual(InstanceVault.url(serial: one.serial),
                       InstanceVault.url(serial: renamed.serial))
        XCTAssertTrue(InstanceVault.url(serial: one.serial).lastPathComponent
            .hasSuffix(".sparsebundle"))
    }

    func testContainersLiveOutsideTheGuestsViewOfTheMac() {
        // `mac_home` shares NSHomeDirectory() into every guest, writable.
        // A container in the home folder would be readable by any Linux
        // terminal in any instance, which is most of what this is for.
        XCTAssertFalse(InstanceVault.directory.path.hasPrefix(NSHomeDirectory()),
                       "containers are inside the folder shared into every guest")
        XCTAssertTrue(InstanceVault.directory.path.hasPrefix("/Users/Shared"))
    }

    func testTheMountPointParserHandlesRealMountOutput() {
        let line = "/dev/disk7s1 on /Volumes/MSL-abcd1234 (apfs, local, nodev, nosuid, journaled)"
        XCTAssertEqual(InstanceVault.mountPoint(inOutput: line), "/Volumes/MSL-abcd1234")
        XCTAssertNil(InstanceVault.mountPoint(inOutput: "/dev/disk1 on / (apfs, local)"))
    }

    // MARK: - A real cycle

    func testARealContainerRefusesTheWrongPassphraseAndKeepsItsContents() throws {
        // The property that must never regress, and only running it proves
        // it. Everything stays in a temporary directory.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("test.sparsebundle")
        let right = "correct-passphrase-for-this-test"
        _ = try InstanceVault.run("/usr/bin/hdiutil",
                                  ["create", "-type", "SPARSEBUNDLE", "-encryption", "AES-256",
                                   "-stdinpass", "-size", "1g", "-fs", "APFS",
                                   "-volname", "MSLTEST", "-quiet", bundle.path],
                                  passphrase: right)

        // Wrong passphrase: refused.
        XCTAssertThrowsError(try InstanceVault.run(
            "/usr/bin/hdiutil",
            ["attach", "-stdinpass", "-nobrowse", "-noverify", bundle.path],
            passphrase: "definitely-not-it")) { error in
            XCTAssertTrue("\(error)".lowercased().contains("auth"), "\(error)")
        }

        // Right passphrase: attaches, holds what is written, survives a
        // detach and re-attach.
        let attached = try InstanceVault.run(
            "/usr/bin/hdiutil",
            ["attach", "-stdinpass", "-nobrowse", "-noverify", bundle.path],
            passphrase: right)
        let mount = try XCTUnwrap(attached.split(separator: "\n")
            .compactMap { line -> String? in
                guard let r = line.range(of: "/Volumes/MSLTEST") else { return nil }
                return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }.first)
        let payload = URL(fileURLWithPath: mount).appendingPathComponent("rootfs.img")
        try Data(repeating: 0x42, count: 4096).write(to: payload)
        _ = try? InstanceVault.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"],
                                   passphrase: nil)

        let again = try InstanceVault.run(
            "/usr/bin/hdiutil",
            ["attach", "-stdinpass", "-nobrowse", "-noverify", bundle.path],
            passphrase: right)
        let mount2 = try XCTUnwrap(again.split(separator: "\n")
            .compactMap { line -> String? in
                guard let r = line.range(of: "/Volumes/MSLTEST") else { return nil }
                return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }.first)
        defer { _ = try? InstanceVault.run("/usr/bin/hdiutil", ["detach", mount2, "-quiet"],
                                           passphrase: nil) }
        let read = try Data(contentsOf: URL(fileURLWithPath: mount2)
            .appendingPathComponent("rootfs.img"))
        XCTAssertEqual(read, Data(repeating: 0x42, count: 4096),
                       "the container lost what was written into it")
    }
}

/// The lifecycle rules, which are where a container turns into data loss if
/// they are wrong.
final class InstanceVaultLifecycleTests: XCTestCase {

    /// The rules are asserted against the source, because the failure they
    /// prevent cannot be provoked in a unit test without a real VM - and
    /// the thing most likely to break them is a later tidy-up that moves a
    /// call somewhere it looks neater.
    private func vmManagerSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MSLCore/VMManager.swift"), encoding: .utf8)
    }

    func testNothingReadsTheRawDiskPathAnyMore() throws {
        // For a protected instance the image is inside the container, so
        // anything still reading `configuration.diskImagePath` would find
        // nothing there - or worse, find a stale plaintext copy under the
        // old name and boot it.
        let source = try vmManagerSource()
        let uses = source.components(separatedBy: "configuration.diskImagePath").count - 1
        XCTAssertEqual(uses, 2, """
            `configuration.diskImagePath` should appear exactly twice - once in the \
            accessor's own doc comment and once in its body. Every other reader must \
            use the `diskImagePath` accessor, which returns the in-container path \
            when a protected instance's container is open.
            """)
    }

    func testTheDetachGuardLivesWithTheDetachRatherThanTheCallers() throws {
        // There are a dozen places a VM reaches `.stopped`. Trusting every
        // call site to be on a settled path is how a detach ends up
        // happening under a live guest, which is guaranteed corruption -
        // so the check is inside `closeVaultIfOpen`.
        let source = try vmManagerSource()
        guard let range = source.range(of: "func closeVaultIfOpen() {") else {
            return XCTFail("closeVaultIfOpen has been renamed; this test needs updating")
        }
        let body = source[range.upperBound...].prefix(1200)
        XCTAssertTrue(body.contains("virtualMachine?.state"),
                      "the detach no longer checks whether the VM is actually stopped")
        XCTAssertTrue(body.contains("state != .stopped"), String(body.prefix(400)))
    }

    func testTheContainerOpensBeforeTheDiskAttachmentIsBuilt() throws {
        // `VZDiskImageStorageDeviceAttachment` reads the file where it is
        // constructed, so a container opened afterwards would be attached
        // to nothing.
        let source = try vmManagerSource()
        guard let open = source.range(of: "guard openVaultIfNeeded() else {"),
              let attachment = source.range(of: "VZDiskImageStorageDeviceAttachment(") else {
            return XCTFail("the boot path has changed shape; this test needs updating")
        }
        XCTAssertLessThan(open.lowerBound, attachment.lowerBound,
                          "the container is opened after the disk attachment is built")
    }

    func testAFailureToOpenStopsTheBootRatherThanFallingBack() throws {
        // Carrying on would mean booting whatever plaintext disk is still
        // under the old path, which is the one outcome worse than not
        // starting.
        let source = try vmManagerSource()
        XCTAssertTrue(source.contains("VMManagerError.vaultUnavailable"))
        let message = "\(VMManagerError.vaultUnavailable("Company"))"
        XCTAssertTrue(message.contains("Nothing was started from an unencrypted copy"), message)
    }

    func testClosingIsWiredToTheStopCompletionNotTheStopCall() throws {
        // `vm.stop` is asynchronous. Closing the container on the line
        // after the call would detach it while the guest was still winding
        // down - the corruption case all of this is arranged to avoid.
        // Anchored on the function first: there are several `vm.stop`
        // sites in this file, and the first one is not this one.
        let source = try vmManagerSource()
        guard let function = source.range(of: "func stopAfterGuestShutdown"),
              let stop = source.range(of: "vm.stop { error in",
                                      range: function.upperBound..<source.endIndex) else {
            return XCTFail("stopAfterGuestShutdown has changed shape")
        }
        let handler = source[stop.upperBound...].prefix(900)
        XCTAssertTrue(handler.contains("closeVaultIfOpen"),
                      "the container is not closed in the stop completion handler")
    }
}

/// Saved guest memory, which is the part of a protected instance it would
/// be easiest to leave unprotected.
final class ProtectedSavedStateTests: XCTestCase {

    private func vmManagerSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MSLCore/VMManager.swift"), encoding: .utf8)
    }

    func testSavedMemoryGoesInsideTheContainer() throws {
        // A `.state` file is the guest's ENTIRE RAM, written whole - every
        // secret the instance had in memory. Encrypting the disk and
        // leaving that beside it in the clear would protect the filing
        // cabinet and photocopy its contents onto the desk.
        let source = try vmManagerSource()
        for property in ["private var snapshotURL: URL {",
                         "private func namedSnapshotURL(_ name: String) -> URL {"] {
            guard let range = source.range(of: property) else {
                return XCTFail("\(property) has changed shape; this test needs updating")
            }
            let body = source[range.upperBound...].prefix(200)
            XCTAssertTrue(body.contains("stateDirectory"),
                          "\(property) writes to Application Support, not into the container")
        }
    }

    func testTheMachineIdentifierDeliberatelyStaysOnTheHost() throws {
        // An opaque VZ identifier, not guest data, and it is needed to
        // BUILD the VM - which is when the container is opened. Putting it
        // inside would be a circular dependency for no benefit.
        let source = try vmManagerSource()
        guard let range = source.range(of: "private var machineIdentifierURL: URL {") else {
            return XCTFail("machineIdentifierURL has changed shape")
        }
        let body = source[range.upperBound...].prefix(200)
        XCTAssertTrue(body.contains("appSupportDir"))
        XCTAssertFalse(body.contains("stateDirectory"))
    }

    func testSnapshotListingLooksWhereTheSnapshotsActuallyAre() throws {
        let source = try vmManagerSource()
        guard let range = source.range(of: "public func snapshotList() -> [String] {") else {
            return XCTFail("snapshotList has changed shape")
        }
        let body = source[range.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("stateDirectory"))
    }

    func testTheStaticChecksLookInsideAContainerToo() throws {
        // Otherwise `InstanceRename` would see no saved memory for a
        // protected instance and allow a rename that invalidates it - the
        // guest's address comes from its name, and macOS refuses to
        // restore a saved VM whose address changed.
        let source = try vmManagerSource()
        for function in ["public static func hasSavedState(",
                         "public static func snapshotNames("] {
            guard let range = source.range(of: function) else {
                return XCTFail("\(function) has changed shape")
            }
            let body = source[range.upperBound...].prefix(1400)
            XCTAssertTrue(body.contains("withProtectedState"),
                          "\(function) only looks in Application Support")
        }
    }

    func testLookingInsideLeavesTheContainerAsItWasFound() throws {
        // A container somebody else opened - a running instance - must not
        // be closed underneath them, and one that was shut must not be
        // left open afterwards, which would defeat the encryption for as
        // long as the Mac stayed up.
        let source = try vmManagerSource()
        guard let range = source.range(of: "static func withProtectedState") else {
            return XCTFail("withProtectedState has changed shape")
        }
        let body = source[range.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("wasOpen"), String(body.prefix(400)))
        XCTAssertTrue(body.contains("if !wasOpen"), String(body.prefix(600)))
    }

    func testNoContainerIsDistinguishableFromAnEmptyOne() {
        // nil means "nothing to look in", which is not the same as
        // "looked and found nothing" - a caller that could not tell them
        // apart would treat an unprotected instance as having no saved
        // state even when it has.
        XCTAssertNil(VMManager.withProtectedState(
            instance: "definitely-not-an-instance",
            appSupport: URL(fileURLWithPath: NSTemporaryDirectory())) { _ in true })
    }
}

/// Moving a disk in and out, which is the operation that touches somebody's
/// only copy of their machine.
final class InstanceVaultMoveTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testCopyingReturnsTheHashOfWhatItWroteAndReportsProgress() throws {
        let source = root.appendingPathComponent("in.img")
        let destination = root.appendingPathComponent("out.img")
        // Larger than the 64 MiB progress threshold, so progress is
        // actually exercised rather than only the final call.
        let payload = Data((0..<(80 * 1024 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: source)

        var reports: [UInt64] = []
        let written = try InstanceVault.copy(from: source.path, to: destination.path,
                                             total: UInt64(payload.count)) { reports.append($0) }

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(written, try InstanceVault.sha256(of: destination.path))
        XCTAssertEqual(written, try InstanceVault.sha256(of: source.path),
                       "the hash does not describe what was copied")
        XCTAssertGreaterThan(reports.count, 1, "progress was only reported once")
        XCTAssertEqual(reports.last, UInt64(payload.count),
                       "the last progress report is not the full size")
    }

    func testCopyingAnEmptyFileIsNotAFailure() throws {
        let source = root.appendingPathComponent("empty.img")
        let destination = root.appendingPathComponent("copy.img")
        try Data().write(to: source)
        let written = try InstanceVault.copy(from: source.path, to: destination.path, total: 0) { _ in }
        XCTAssertEqual(written, try InstanceVault.sha256(of: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCopyingFromSomethingThatIsNotThereThrowsRatherThanWritingNothing() {
        XCTAssertThrowsError(try InstanceVault.copy(
            from: root.appendingPathComponent("missing").path,
            to: root.appendingPathComponent("out").path, total: 0) { _ in })
    }

    func testAPlainDiskInTheWayHasItsOwnMessage() {
        // Its own error case rather than a reuse of `alreadyExists`, whose
        // wording is "a container for lineage X already exists" - passing
        // it a sentence produced "a container for lineage a plain disk is
        // already at /Users/… already exists", which is the kind of
        // message that makes somebody distrust everything else the tool
        // says. Caught by reading the live output.
        let message = "\(InstanceVault.VaultError.plainDiskInTheWay("/tmp/x.img"))"
        XCTAssertTrue(message.hasPrefix("there is already a plain disk at /tmp/x.img"), message)
        XCTAssertFalse(message.contains("lineage"), message)
        XCTAssertTrue(message.contains("destroy whatever is in it"), message)
    }

    func testTheProgressDescriptionReadsSensiblyAtBothEnds() {
        XCTAssertEqual(InstanceVault.Progress(copied: 0, total: 0, stage: "making the container")
            .description, "making the container")
        let half = InstanceVault.Progress(copied: 512, total: 1024, stage: "copying the disk in")
        XCTAssertEqual(half.fraction, 0.5)
        XCTAssertTrue(half.description.contains("of"), half.description)
        // Never past 100%, which a sparse file's reported size can cause.
        XCTAssertEqual(InstanceVault.Progress(copied: 2048, total: 1024, stage: "x").fraction, 1)
    }

    // MARK: - The policy direction

    func testProtectingIsNeverRefusedAndUnprotectingIs() {
        // Protecting makes the disk unreadable, which is the safe
        // direction. Taking it back OUT is the one that needs permission:
        // an administrator who denied copying meant the bytes to stay
        // sealed, and moving them into a plain file beside everything else
        // would quietly undo that.
        XCTAssertEqual(MSLAPEnforcement.requirements(
            for: .protectInstance(instance: "Company", enable: true)).count, 0)
        XCTAssertEqual(MSLAPEnforcement.requirements(
            for: .protectInstance(instance: "Company", enable: false))
            .map(\.capability.key), ["instance.clone"])

        let policy = MSLAPPolicy(
            issued: Date(), issuer: "Test",
            scopes: [.init(match: "*", deny: [MSLAPCapability("instance.clone")],
                           reason: "sealed image")],
            message: nil)
        XCTAssertNil(MSLAPEnforcement.check(.protectInstance(instance: "Company", enable: true),
                                            policy: policy, issuer: "Test"))
        XCTAssertNotNil(MSLAPEnforcement.check(.protectInstance(instance: "Company", enable: false),
                                               policy: policy, issuer: "Test"))
    }

    func testBothDirectionsSurviveTheWire() {
        for request in [DaemonProtocol.ControlRequest.protectInstance(instance: "Company", enable: true),
                        .protectInstance(instance: "Company", enable: false)] {
            let line = String(decoding: request.encode(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("did not parse: \(line)")
            }
            XCTAssertEqual(String(decoding: parsed.encode(), as: UTF8.self),
                           String(decoding: request.encode(), as: UTF8.self))
        }
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("PROTECT Company MAYBE"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("PROTECT --shutdown ON"))
    }

    func testProtectingNeverCountsAsStartingAnInstance() {
        // It needs the instance stopped - the whole disk is being copied.
        for enable in [true, false] {
            XCTAssertNil(DaemonProtocol.ControlRequest
                .protectInstance(instance: "Company", enable: enable).startsInstance)
        }
    }
}

/// Admin-held keys: the rung where nothing on the Mac can open a container.
final class AdminHeldVaultKeyTests: XCTestCase {

    func testWrappingIsDeterministicForOnePassphraseAndSalt() {
        let salt = Data(repeating: 7, count: 32)
        let a = InstanceVault.wrappingKey(passphrase: "hunter2", salt: salt, iterations: 2000)
        let b = InstanceVault.wrappingKey(passphrase: "hunter2", salt: salt, iterations: 2000)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testEveryInputChangesTheWrappingKey() {
        let salt = Data(repeating: 7, count: 32)
        let reference = InstanceVault.wrappingKey(passphrase: "hunter2", salt: salt,
                                                   iterations: 2000)
            .withUnsafeBytes { Data($0) }
        let otherPassphrase = InstanceVault.wrappingKey(passphrase: "hunter3", salt: salt,
                                                        iterations: 2000)
            .withUnsafeBytes { Data($0) }
        let otherSalt = InstanceVault.wrappingKey(passphrase: "hunter2",
                                                   salt: Data(repeating: 8, count: 32),
                                                   iterations: 2000)
            .withUnsafeBytes { Data($0) }
        let otherCount = InstanceVault.wrappingKey(passphrase: "hunter2", salt: salt,
                                                    iterations: 2001)
            .withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(otherPassphrase, reference, "the passphrase does not affect the key")
        XCTAssertNotEqual(otherSalt, reference, "the salt does not affect the key")
        XCTAssertNotEqual(otherCount, reference, "the iteration count does not affect the key")
    }

    func testAWrongPassphraseIsDetectedRatherThanProducingGarbage() throws {
        // AES-GCM authenticates, so this is a real check. Without that, a
        // wrong passphrase would "succeed" and hand `diskutil` nonsense,
        // and the failure would surface as an unexplained attach error.
        let salt = Data(repeating: 3, count: 32)
        let right = InstanceVault.wrappingKey(passphrase: "right", salt: salt, iterations: 1000)
        let wrong = InstanceVault.wrappingKey(passphrase: "wrong", salt: salt, iterations: 1000)
        let sealed = try AES.GCM.seal(Data("the-real-passphrase".utf8), using: right)
        let combined = try XCTUnwrap(sealed.combined)

        let box = try AES.GCM.SealedBox(combined: combined)
        XCTAssertEqual(try AES.GCM.open(box, using: right), Data("the-real-passphrase".utf8))
        XCTAssertThrowsError(try AES.GCM.open(try AES.GCM.SealedBox(combined: combined),
                                               using: wrong))
    }

    func testTheIterationCountMatchesTheOneTheAdminPasswordSettledOn() {
        // One figure, chosen once, for the same reason: high enough to
        // make guessing expensive, low enough that unlocking still feels
        // like typing a password.
        XCTAssertEqual(WrappedVaultKey.defaultIterations, MSLAPAdminPassword.iterations)
    }

    func testAnUnprotectedLineageReportsTheMachineModeAndNeedsNoUnlock() {
        // No key file means this Mac's own key, which is always available -
        // so `isUnlocked` must be true or every ordinary container would
        // read as locked.
        let unknown = InstanceIdentity.randomBase32(InstanceIdentity.lineageLength)
        XCTAssertEqual(InstanceVault.keyMode(serial: unknown), .machine)
        XCTAssertTrue(InstanceVault.isUnlocked(serial: unknown))
    }

    func testLockingAndUnlockingAnUnknownLineageIsSafe() {
        let unknown = InstanceIdentity.randomBase32(InstanceIdentity.lineageLength)
        XCTAssertFalse(InstanceVault.unlock(serial: unknown, adminPassphrase: "anything"),
                       "unlocking a lineage with no wrapped key appeared to succeed")
        InstanceVault.lock(serial: unknown)   // must not crash
    }

    // MARK: - Policy

    func testSupplyingOrForgettingAKeyIsNeverRefusedButAdoptingIs() {
        // `unlock` is somebody proving they are entitled to open the
        // image; `lock` makes the Mac safer. **`adopt` changes who can
        // open it from then on**, which on a managed Mac is the
        // administrator's decision.
        for action in ["unlock", "lock", "status"] {
            XCTAssertEqual(MSLAPEnforcement.requirements(
                for: .vaultKey(instance: "Company", action: action, passphrase: "p")).count, 0,
                action)
        }
        XCTAssertEqual(MSLAPEnforcement.requirements(
            for: .vaultKey(instance: "Company", action: "adopt", passphrase: "p"))
            .map(\.capability.key), ["instance.clone"])
    }

    func testAPassphraseWithSpacesSurvivesTheWire() {
        // The wire format splits on spaces, so the passphrase has to be
        // the remainder of the line - and people use spaces.
        let request = DaemonProtocol.ControlRequest.vaultKey(
            instance: "Company", action: "unlock", passphrase: "three word passphrase")
        let line = String(decoding: request.encode(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .vaultKey(_, _, let parsed)? = DaemonProtocol.ControlRequest.parse(line) else {
            return XCTFail("did not parse: \(line)")
        }
        XCTAssertEqual(parsed, "three word passphrase")
    }

    func testThePassphraseIsNotInTheActivityDescription() {
        // That string is what the activity monitor records.
        let described = DaemonProtocol.ControlRequest.vaultKey(
            instance: "Company", action: "unlock", passphrase: "s3cret").monitorSummary
        XCTAssertNotNil(described)
        XCTAssertFalse(described!.contains("s3cret"), described!)
    }

    func testAnUnknownActionFailsToParse() {
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("VAULT_KEY Company destroy x"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("VAULT_KEY --shutdown unlock x"))
    }
}
