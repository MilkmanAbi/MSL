import XCTest
import CryptoKit
@testable import MSLCore

/// Whether an instance may start, given what its identity says.
///
/// This decides on the boot path of every instance on every Mac, so the
/// tests are about one thing above all: **it must not strand anybody.**
/// Almost every state has to allow, and the few refusals have to be ones
/// an administrator asked for or ones that are self-contradictory.
final class InstanceAdmissionTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()
    private var keyID: String { MSLAPSigning.keyID(for: key.publicKey) }

    private func identity(generation: String = "0", origin: String = "Company") -> InstanceIdentity {
        InstanceIdentity(lineage: InstanceIdentity.randomBase32(26), generation: generation,
                         serial: InstanceIdentity.randomBase32(13), issuer: keyID,
                         origin: origin, machine: String(repeating: "a", count: 16),
                         born: 1_760_000_000)
    }

    private func policy(denying keys: [String], forScope match: String = "*") -> MSLAPPolicy {
        MSLAPPolicy(issued: Date(), issuer: "Test",
                    scopes: [.init(match: match, deny: keys.map(MSLAPCapability.init),
                                   reason: "protected image")],
                    message: nil)
    }

    private func decide(_ instance: String = "Company",
                        _ verdict: InstanceIdentityStore.Verdict,
                        duplicates: [String] = [],
                        policy: MSLAPPolicy? = nil,
                        duplicatesClaimOrigin: Bool = false) -> InstanceAdmission.Decision {
        InstanceAdmission.decide(.init(instance: instance, verdict: verdict,
                                       duplicates: duplicates, policy: policy,
                                       duplicatesClaimOrigin: duplicatesClaimOrigin))
    }

    // MARK: - Not stranding anybody

    func testAnUnmanagedMacStartsEverythingItCan() {
        // Enforcement exists to serve an administrator's stated intent.
        // With no policy there is none to serve, so the answer is a loud
        // report rather than a refusal - the rule `MSLAPEnforcement.check`
        // already states: loud and working beats silent and bricked.
        XCTAssertEqual(decide("Company", .unidentified), .allow)
        XCTAssertEqual(decide("Company", .valid(identity())), .allow)
        XCTAssertEqual(decide("Company", .valid(identity(generation: "0.1"))), .allow)
        guard case .allowWithNote(let note) = decide("Company", .invalid("edited")) else {
            return XCTFail("an unmanaged Mac refused a tampered identity")
        }
        XCTAssertTrue(note.contains("not managed"), note)
    }

    func testEveryExistingInstanceStartsOnAManagedMacToo() {
        // Every instance in existence before this feature has no identity.
        // If that were refused by default, shipping this would brick every
        // managed Mac at once.
        XCTAssertEqual(decide("Company", .unidentified,
                              policy: policy(denying: ["instance.clone"])), .allow)
    }

    func testAnOriginalStartsEvenWhereCopyingIsForbidden() {
        // Denying `instance.clone` must not stop the thing being protected
        // from running - that would make protecting an image mean losing it.
        XCTAssertEqual(decide("Company", .valid(identity()),
                              policy: policy(denying: ["instance.clone"])), .allow)
    }

    // MARK: - The refusal that was asked for

    func testACopyIsRefusedWhereCopyingIsForbidden() {
        // One switch blocks the button AND refuses a copy that arrived some
        // other way, which is exactly the request.
        let decision = decide("Copy", .valid(identity(generation: "0.1", origin: "Copy")),
                              policy: policy(denying: ["instance.clone"]))
        guard case .refuse(let why) = decision else {
            return XCTFail("a copy started where copying is forbidden: \(decision)")
        }
        XCTAssertTrue(why.contains("instance.clone"), why)
        XCTAssertTrue(why.contains("0.1"), "the refusal does not say how deep a copy it is: \(why)")
        XCTAssertTrue(why.contains("Set by Test"), "the refusal does not name the issuer: \(why)")
    }

    func testTheRefusalNamesTheReasonTheAdministratorWrote() {
        guard case .refuse(let why) = decide(
            "Copy", .valid(identity(generation: "0.1", origin: "Copy")),
            policy: policy(denying: ["instance.clone"])) else { return XCTFail() }
        XCTAssertTrue(why.contains("protected image"), why)
    }

    // MARK: - The escape route, closed by `origin`

    func testRenamingACopyDoesNotEscapeAScopeWrittenAboutTheOriginal() {
        // **The check this rests on.** MSLAP scopes match by instance name,
        // so a copy of `Company` renamed `Sneaky` is not matched by a scope
        // on `Company*`. Checking only the current name would make renaming
        // a copy the way around every rule written about the original.
        let decision = decide("Sneaky",
                              .valid(identity(generation: "0.1", origin: "Company")),
                              policy: policy(denying: ["instance.clone"], forScope: "Company*"))
        guard case .refuse(let why) = decision else {
            return XCTFail("a renamed copy escaped its origin's scope: \(decision)")
        }
        XCTAssertTrue(why.contains("Company"), "the refusal does not name the origin: \(why)")
        XCTAssertTrue(why.contains("created under") || why.contains("created as"), why)
    }

    func testAnInstanceOutsideTheScopeEntirelyIsUnaffected() {
        // The origin check must not drag in instances the scope never
        // mentioned, or a narrow rule would quietly become a broad one.
        XCTAssertEqual(
            decide("mine", .valid(identity(generation: "0.1", origin: "mine")),
                   policy: policy(denying: ["instance.clone"], forScope: "Company*")),
            .allow)
    }

    // MARK: - The one refusal with no policy at all

    func testTheCopyIsRefusedAndTheOriGinalStartsRatherThanBothBeingRefused() {
        // **`origin` decides which is which.** It is the name the instance
        // was created under and it is signed, so copying an identity file
        // onto a second instance cannot make that second name match it.
        //
        // Before this, the refusal was symmetric - both refused, neither
        // startable - which punished the person for a copy they may not
        // have made and left them with nothing running. Measured as
        // symmetric on a live Mac, which is how it was found.
        let shared = identity(origin: "Company")

        // The copy, under a name the identity does not claim.
        let copy = decide("Sneaky", .valid(shared), duplicates: ["Company"])
        guard case .refuse(let why) = copy else {
            return XCTFail("the copy started: \(copy)")
        }
        XCTAssertTrue(why.contains("Company"), why)
        XCTAssertTrue(why.contains("this one is the copy") || why.contains("This one is the copy"), why)
        XCTAssertTrue(why.contains("msl identity"), "the refusal does not say how to look: \(why)")

        // The original, which the identity does claim.
        guard case .allowWithNote(let note) = decide(
            "Company", .valid(shared), duplicates: ["Sneaky"]) else {
            return XCTFail("the original was refused alongside its copy")
        }
        XCTAssertTrue(note.contains("Sneaky"), note)
    }

    func testAnAmbiguousDuplicateRefusesEveryOneOfThem() {
        // If two of the conflicting instances are both named by `origin` -
        // which takes deliberate work - there is no honest tiebreak left.
        XCTAssertTrue(decide("Company", .valid(identity(origin: "Company")),
                             duplicates: ["Company"], duplicatesClaimOrigin: true).isRefusal)
    }

    func testADuplicateWithNoIdentityToJudgeByIsRefused() {
        // No `origin` to compare against, so nothing says which is the
        // original and the safe answer is to refuse.
        XCTAssertTrue(decide("Sneaky", .unidentified, duplicates: ["Company"]).isRefusal)
    }

    func testADuplicateOutranksEverythingElse() {
        // Checked first, so a duplicate is reported as a duplicate rather
        // than as whatever else happens to be true about it.
        guard case .refuse(let why) = decide(
            "Sneaky", .unidentified, duplicates: ["Company"],
            policy: policy(denying: ["instance.acceptUnidentified"])) else { return XCTFail() }
        XCTAssertTrue(why.contains("same instance"), why)
    }

    // MARK: - Tampering

    func testAnEditedIdentityIsRefusedOnAManagedMac() {
        let decision = decide("Company", .invalid("the signature does not match"),
                              policy: policy(denying: []))
        guard case .refuse(let why) = decision else {
            return XCTFail("a managed Mac started an instance whose provenance was edited")
        }
        XCTAssertTrue(why.contains("does not verify"), why)
        XCTAssertTrue(why.contains("msl identity"), why)
    }

    func testAnEmptyPolicyStillCountsAsManaged() {
        // A policy that denies nothing is still an administrator saying
        // "this Mac is managed", and tampering is refused on it.
        XCTAssertTrue(decide("Company", .invalid("edited"), policy: policy(denying: [])).isRefusal)
    }

    // MARK: - Unidentified, when a fleet asks for it

    func testAFleetCanRefuseInstancesWithNoProvenance() {
        let decision = decide("Company", .unidentified,
                              policy: policy(denying: ["instance.acceptUnidentified"]))
        guard case .refuse(let why) = decision else {
            return XCTFail("instance.acceptUnidentified was denied and did nothing")
        }
        XCTAssertTrue(why.contains("no provenance"), why)
    }

    func testThatCapabilityDefaultsToAllowedAndIsInTheCatalogue() {
        let entry = MSLAPCapability.entry(for: MSLAPCapability("instance.acceptUnidentified"))
        XCTAssertNotNil(entry, "the capability is not in the catalogue")
        XCTAssertEqual(entry?.enforced, true)
        XCTAssertEqual(entry?.unavailable, false)
        // Allowed unless denied, like every capability - which is what
        // makes shipping this safe for every existing instance.
        XCTAssertEqual(decide("Company", .unidentified, policy: policy(denying: [])), .allow)
    }
}

/// **Every path that can start a VM, enumerated.**
///
/// The pattern is `DaemonProtocol.ControlRequest.everyCaseForAudit` plus a
/// mapping with no `default` arm: adding a start path should be a decision,
/// not an accident. It caught a real gap in the port-forwarding work this
/// month, and the gap here would be worse - a refused instance that
/// something can still wake is not refused.
final class StartPathAuditTests: XCTestCase {

    /// Every call to `VMManager.ensureRunning()` in the tree, as of the
    /// commit that added provenance checking.
    ///
    /// Two of these were the reason the check sits in `ensureRunning`
    /// rather than in `DaemonServer.ensureRunningWithinCap`, which is the
    /// obvious place and the wrong one.
    static let knownStartPaths: Set<String> = [
        // The ordinary route: a session, a GUI app, `msl <instance>`.
        "DaemonServer.ensureRunningWithinCap",
        // **Finder touching the WebDAV mount wakes a paused guest.** This
        // bypasses the cap check entirely.
        "FileOpsClient.wake",
        // **Restoring instances after a power event.** Also bypasses it.
        "SystemResilienceMonitor.restore",
    ]

    func testEveryEnsureRunningCallerIsAccountedFor() throws {
        // Greps the real sources rather than trusting a list, so a new
        // caller appears here as a failure with its file named.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MSLCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MSL
            .appendingPathComponent("Sources")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-rn", "--include=*.swift", "\\.ensureRunning()", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let hits = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.contains("func ensureRunning") && !$0.contains("DaemonClient") }

        XCTAssertEqual(hits.count, Self.knownStartPaths.count, """
            The number of places that start a VM has changed. Each one must be \
            checked against `InstanceAdmission`, which is why the check lives in \
            `VMManager.ensureRunning()` - a refused instance that something can \
            still wake is not refused. Found:
            \(hits.joined(separator: "\n"))
            """)
    }

    func testTheCheckIsInsideEnsureRunningRatherThanItsCallers() throws {
        // A placement test, because moving it "somewhere tidier" is exactly
        // the change that would silently reopen the two bypasses.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MSLCore/VMManager.swift"),
            encoding: .utf8)
        guard let range = source.range(of: "public func ensureRunning() async throws {") else {
            return XCTFail("ensureRunning has been renamed; this test needs updating")
        }
        let body = source[range.upperBound...].prefix(3000)
        XCTAssertTrue(body.contains("InstanceAdmission.decide"),
                      "the provenance check is no longer inside ensureRunning")
        // And after the maintenance check, so a refused instance can still
        // be repaired.
        let maintenanceFirst = body.range(of: "maintenanceInProgress")
        let checkAfter = body.range(of: "InstanceAdmission.decide")
        XCTAssertNotNil(maintenanceFirst)
        XCTAssertNotNil(checkAfter)
        if let m = maintenanceFirst, let c = checkAfter {
            XCTAssertLessThan(m.lowerBound, c.lowerBound,
                              "the provenance check now runs before the maintenance check, "
                              + "so a refused instance could not be repaired")
        }
    }
}

/// The one-shot migration, and the laundering it exists to stop.
final class InstanceIdentityMigrationTests: XCTestCase {
    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey()
    private var accepting: [String: Curve25519.Signing.PublicKey] {
        [MSLAPSigning.keyID(for: key.publicKey): key.publicKey]
    }

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-migration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Writes a record signed with this test's key, so nothing touches the
    /// real machine key store.
    private func writeRecord(instances: [String], at date: Date = Date(),
                             signed: Bool = true) throws {
        var record = InstanceIdentityMigration.Record(
            completed: date, instances: instances.sorted(), signature: nil)
        if signed {
            record.signature = try key.signature(for: Data(record.payload.utf8))
                .base64EncodedString()
        } else {
            record.signature = "bm90YXNpZ25hdHVyZQ=="
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = InstanceIdentityMigration.file(appSupport: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url)
    }

    // MARK: - The rule

    func testAdoptionIsAllowedBeforeThePassHasRun() {
        // Whatever is on the Mac predates the feature and there is nothing
        // better to say about it.
        XCTAssertTrue(InstanceIdentityMigration.mayAdopt(appSupport: root, managed: true, accepting: accepting))
        XCTAssertTrue(InstanceIdentityMigration.mayAdopt(appSupport: root, managed: false, accepting: accepting))
    }

    func testAfterThePassAManagedMacStopsAdopting() throws {
        // **The anti-laundering rule.** "Issue one whenever it is missing"
        // means `cp Company.img Sneaky.img`, add a registry line, start it,
        // and the copy is handed a brand-new generation-0 identity -
        // blessed by us as an original, with every later check agreeing.
        try writeRecord(instances: ["Company"])
        XCTAssertTrue(InstanceIdentityMigration.hasRun(appSupport: root, accepting: accepting))
        XCTAssertFalse(InstanceIdentityMigration.mayAdopt(appSupport: root, managed: true, accepting: accepting),
                       "a managed Mac is still adopting after the pass - copies can be laundered")
    }

    func testAfterThePassAnUnmanagedMacKeepsAdopting() throws {
        // No administrator to protect, and the alternative is an instance
        // that reports a problem for ever for nobody's benefit.
        try writeRecord(instances: ["Company"])
        XCTAssertTrue(InstanceIdentityMigration.mayAdopt(appSupport: root, managed: false, accepting: accepting))
    }

    // MARK: - The record

    func testAnUnsignedOrEditedRecordCountsAsNotRun() throws {
        // Conservative in the direction that matters: MSL keeps adopting
        // rather than refusing instances because a file was corrupted. The
        // tampering is reported separately.
        try writeRecord(instances: ["Company"], signed: false)
        XCTAssertFalse(InstanceIdentityMigration.hasRun(appSupport: root, accepting: accepting))
        XCTAssertTrue(InstanceIdentityMigration.mayAdopt(appSupport: root, managed: true, accepting: accepting))
    }

    func testTheRecordCannotBeBackDatedWithoutBreakingItsSignature() throws {
        // Back-dating would make a later arrival look like an old resident.
        try writeRecord(instances: ["Company"], at: Date())
        let url = InstanceIdentityMigration.file(appSupport: root)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"2026", with: "\"2020")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(InstanceIdentityMigration.hasRun(appSupport: root, accepting: accepting))
    }

    func testTheRecordedInstanceListIsSignedToo() throws {
        // Adding a name would claim an instance was present at the pass
        // when it was not.
        try writeRecord(instances: ["Company"])
        let url = InstanceIdentityMigration.file(appSupport: root)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"Company\"", with: "\"Company\",\n    \"Sneaky\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(InstanceIdentityMigration.hasRun(appSupport: root, accepting: accepting))
    }

    func testNoRecordAtAllIsSimplyNotRun() {
        XCTAssertFalse(InstanceIdentityMigration.hasRun(appSupport: root, accepting: accepting))
        XCTAssertNil(InstanceIdentityMigration.record(appSupport: root, accepting: accepting))
    }

    // MARK: - Adoption never overwrites evidence

    func testAdoptionLeavesATamperedIdentityExactlyAsItIs() throws {
        // **The worst thing this code could do** is overwrite an identity
        // that does not verify with a clean new one - destroying the
        // evidence of tampering and replacing it with a pristine original.
        let identity = InstanceIdentity(
            lineage: InstanceIdentity.randomBase32(26), generation: "0",
            serial: InstanceIdentity.randomBase32(13),
            issuer: MSLAPSigning.keyID(for: key.publicKey), origin: "Company",
            machine: String(repeating: "a", count: 16), born: 1_760_000_000)
        let url = InstanceIdentityStore.file(for: "Company", appSupport: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"token\":\"\(identity.payload)~notasignature\"}".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        InstanceAdmission.adoptIfAllowed(instance: "Company", appSupport: root)

        XCTAssertEqual(try Data(contentsOf: url), before,
                       "adoption overwrote a tampered identity, destroying the evidence")
    }
}
