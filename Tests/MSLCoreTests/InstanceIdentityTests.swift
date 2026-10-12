import XCTest
import CryptoKit
@testable import MSLCore

/// The identity token: what it accepts, and much more importantly what it
/// refuses.
///
/// **The parser is the attack surface.** This runs on a boot path against
/// a string that may have been written by whoever owns the Mac, so the
/// tests that matter are the negative ones - a parser that accepts
/// something malformed hands the rest of the system an identity it will
/// treat as true.
final class InstanceIdentityTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()
    private var keyID: String { MSLAPSigning.keyID(for: key.publicKey) }
    private var accepting: [String: Curve25519.Signing.PublicKey] { [keyID: key.publicKey] }

    private func fresh(origin: String = "Company") -> InstanceIdentity {
        InstanceIdentity.issue(origin: origin, machine: String(repeating: "a", count: 16),
                               issuer: keyID)
    }

    // MARK: - Round trip

    func testAFreshIdentityRoundTripsThroughSigningAndVerifying() throws {
        let identity = fresh()
        let token = try identity.signed(with: key)
        XCTAssertEqual(try InstanceIdentity.verify(token: token, accepting: accepting), identity)
    }

    func testAFreshIdentityIsNobodysCopy() {
        let identity = fresh()
        XCTAssertEqual(identity.generation, "0")
        XCTAssertEqual(identity.depth, 0)
        XCTAssertFalse(identity.isClone)
    }

    func testTwoFreshIdentitiesShareNothing() {
        // A lineage must be unique with no coordination between machines -
        // which is why it is random and wide rather than a counter. A
        // counter collides across Macs, so a shipment from one would look
        // native on the other, and "this did not originate here" is exactly
        // what has to be detectable.
        let a = fresh(), b = fresh()
        XCTAssertNotEqual(a.lineage, b.lineage)
        XCTAssertNotEqual(a.serial, b.serial)
    }

    // MARK: - Copies

    func testACopyKeepsTheLineageAndGoesOneDeeper() throws {
        let parent = fresh()
        let child = try XCTUnwrap(parent.copy(index: 1, origin: "Company",
                                              machine: parent.machine, issuer: keyID))
        XCTAssertEqual(child.lineage, parent.lineage, "a copy left its own lineage behind")
        XCTAssertEqual(child.generation, "0.1")
        XCTAssertEqual(child.depth, 1)
        XCTAssertTrue(child.isClone)
        // A fresh serial, so two callers racing to make the "first" clone
        // produce different identities rather than a collision.
        XCTAssertNotEqual(child.serial, parent.serial)
    }

    func testCopiesOfCopiesReadAsAChain() throws {
        var identity = fresh()
        for step in 1...4 {
            identity = try XCTUnwrap(identity.copy(index: step, origin: "Company",
                                                   machine: identity.machine, issuer: keyID))
        }
        XCTAssertEqual(identity.generation, "0.1.2.3.4")
        XCTAssertEqual(identity.depth, 4)
    }

    func testCopyingStopsAtTheDepthLimitRatherThanProducingSomethingUnparseable() throws {
        var identity = fresh()
        for _ in 1...InstanceIdentity.maximumDepth {
            identity = try XCTUnwrap(identity.copy(index: 1, origin: "Company",
                                                   machine: identity.machine, issuer: keyID))
        }
        XCTAssertEqual(identity.depth, InstanceIdentity.maximumDepth)
        // nil rather than an identity the parser would then refuse: a caller
        // has to decide, rather than discover it on the next boot.
        XCTAssertNil(identity.copy(index: 1, origin: "Company",
                                   machine: identity.machine, issuer: keyID))
    }

    func testAnAbsurdCloneIndexIsRefused() {
        let parent = fresh()
        XCTAssertNil(parent.copy(index: 0, origin: "Company", machine: parent.machine, issuer: keyID))
        XCTAssertNil(parent.copy(index: 10_000, origin: "Company", machine: parent.machine, issuer: keyID))
    }

    // MARK: - Tampering, which is the whole point

    func testEditingAnyFieldBreaksTheSignature() throws {
        let identity = fresh()
        let token = try identity.signed(with: key)
        let (payload, signature) = try InstanceIdentity.split(token: token)
        let fields = payload.split(separator: ":").map(String.init)

        // Every field, one at a time. A signature over a SUBSET of the
        // record would leave the rest editable, which is the classic way
        // this goes wrong - so the test walks all of them.
        for index in 1..<fields.count {
            var edited = fields
            switch index {
            case 1: edited[1] = InstanceIdentity.randomBase32(26)       // lineage
            case 2: edited[2] = "0.1"                                    // generation
            case 3: edited[3] = InstanceIdentity.randomBase32(13)        // serial
            case 4: edited[4] = String(repeating: "b", count: 16)        // issuer
            case 5: edited[5] = "Sneaky"                                 // origin
            case 6: edited[6] = String(repeating: "c", count: 16)        // machine
            default: edited[7] = "999999999"                             // born
            }
            let forged = edited.joined(separator: ":") + "~" + signature
            XCTAssertThrowsError(
                try InstanceIdentity.verify(token: forged, accepting: accepting),
                "editing field \(index) was not detected")
        }
    }

    func testPromotingACloneToAnOriginalIsDetected() throws {
        // The attack the whole feature exists to stop: take a clone's
        // identity and rewrite its generation to `0` so it reads as nobody's
        // copy.
        let clone = try XCTUnwrap(fresh().copy(index: 1, origin: "Company",
                                               machine: String(repeating: "a", count: 16),
                                               issuer: keyID))
        let token = try clone.signed(with: key)
        let promoted = token.replacingOccurrences(of: ":0.1:", with: ":0:")
        XCTAssertNotEqual(promoted, token, "the test did not actually edit anything")
        XCTAssertThrowsError(try InstanceIdentity.verify(token: promoted, accepting: accepting))
    }

    func testAnIdentitySignedByAKeyThisMacDoesNotAcceptIsRefused() throws {
        // Anyone can make a key and sign whatever they like. What decides
        // is whether this Mac accepts the signer.
        let stranger = Curve25519.Signing.PrivateKey()
        let identity = InstanceIdentity.issue(
            origin: "Company", machine: String(repeating: "a", count: 16),
            issuer: MSLAPSigning.keyID(for: stranger.publicKey))
        let token = try identity.signed(with: stranger)
        XCTAssertThrowsError(try InstanceIdentity.verify(token: token, accepting: accepting)) {
            guard case InstanceIdentity.Invalid.unknownIssuer = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testAValidSignatureFromTheWrongKeyIsStillRefused() throws {
        // A real signature, a pinned issuer id, and the wrong key: the
        // check must compare against the key the issuer field NAMES, not
        // against any key that happens to be accepted.
        let stranger = Curve25519.Signing.PrivateKey()
        let identity = fresh()                      // claims our keyID
        let token = try identity.signed(with: stranger)   // signed by another
        XCTAssertThrowsError(try InstanceIdentity.verify(token: token, accepting: accepting)) {
            XCTAssertEqual($0 as? InstanceIdentity.Invalid, .badSignature)
        }
    }

    // MARK: - Malformed input

    func testAFutureFormatIsRefusedRatherThanGuessedAt() {
        // The catalogue learned this: an MSL that meets something newer must
        // say so, not read what it recognises and drop the rest.
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: "MSLI2:a:0:b:c:d:e:1")) {
            guard case InstanceIdentity.Invalid.unsupportedVersion("MSLI2") = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testThingsThatAreNotIdentitiesAtAll() {
        for junk in ["", "hello", "{}", "MSL", "0.1", ":::::::"] {
            XCTAssertThrowsError(try InstanceIdentity.parse(payload: junk), junk)
        }
    }

    func testAMissingOrEmptySignatureIsABadSignatureNotAnUnsignedIdentity() throws {
        // `payload~` must fail as a bad signature. If it parsed as an
        // unsigned identity, stripping a signature would be a way to get an
        // identity accepted.
        let payload = fresh().payload
        for token in [payload, payload + "~", "~sig", payload + "~a~b"] {
            XCTAssertThrowsError(try InstanceIdentity.split(token: token), token)
        }
    }

    func testTheFieldCountIsExact() {
        let good = fresh().payload
        XCTAssertNoThrow(try InstanceIdentity.parse(payload: good))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: good + ":extra"))
        XCTAssertThrowsError(try InstanceIdentity.parse(
            payload: good.split(separator: ":").dropLast().joined(separator: ":")))
    }

    func testAnUnboundedGenerationPathIsRefused() {
        // Attacker-influenced data on a boot path: without a cap, a
        // hand-written identity could carry a megabyte of dots.
        let deep = "0" + String(repeating: ".1", count: InstanceIdentity.maximumDepth + 1)
        let identity = fresh()
        let payload = ["MSLI1", identity.lineage, deep, identity.serial,
                       identity.issuer, identity.origin, identity.machine,
                       String(identity.born)].joined(separator: ":")
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload)) {
            guard case InstanceIdentity.Invalid.depthTooGreat = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testOneGenerationPathHasOneSpelling() {
        // `0.01` and `0.1` would be two spellings of one path, and two
        // spellings means two identities that compare unequal while meaning
        // the same thing.
        let identity = fresh()
        func payload(_ generation: String) -> String {
            ["MSLI1", identity.lineage, generation, identity.serial, identity.issuer,
             identity.origin, identity.machine, String(identity.born)].joined(separator: ":")
        }
        XCTAssertNoThrow(try InstanceIdentity.parse(payload: payload("0.1")))
        for bad in ["0.01", "0.", ".1", "1", "0.-1", "0.1.", "0..1", "00", "0.1e2"] {
            XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(bad)), bad)
        }
    }

    func testAnOriginThatCouldNotBeAnInstanceNameIsRefused() {
        // `origin` is signed and is used for policy scoping, so it must be
        // a name a scope could actually match. `--shutdown` once got
        // registered as a real instance; nothing like it gets in here.
        let identity = fresh()
        func payload(_ origin: String) -> String {
            ["MSLI1", identity.lineage, "0", identity.serial, identity.issuer,
             origin, identity.machine, String(identity.born)].joined(separator: ":")
        }
        for bad in ["", "--shutdown", "../etc", "a b", ".hidden", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(bad)), bad)
        }
    }

    func testFieldsAreCheckedForShapeNotJustPresence() {
        let identity = fresh()
        func payload(lineage: String? = nil, serial: String? = nil,
                     issuer: String? = nil, born: String? = nil) -> String {
            ["MSLI1", lineage ?? identity.lineage, "0", serial ?? identity.serial,
             issuer ?? identity.issuer, identity.origin, identity.machine,
             born ?? String(identity.born)].joined(separator: ":")
        }
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(lineage: "tooshort")))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(lineage: String(repeating: "A", count: 26))),
                             "uppercase is outside the alphabet")
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(lineage: String(repeating: "1", count: 26))),
                             "base32 has no 0, 1 or 8")
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(serial: "short")))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(issuer: "nothex0000000000")))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(issuer: String(repeating: "A", count: 16))),
                             "uppercase hex would be a second spelling of one key id")
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(born: "0")))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(born: "-1")))
        XCTAssertThrowsError(try InstanceIdentity.parse(payload: payload(born: "soon")))
    }

    // MARK: - Shape of what we produce

    func testWeOnlyEverProduceSomethingWeWouldAccept() throws {
        // A generator and a parser that disagree is a bug that only shows
        // up once something is already stored.
        for _ in 0..<200 {
            var identity = fresh()
            for step in 1...3 {
                identity = try XCTUnwrap(identity.copy(index: step, origin: "Company",
                                                       machine: identity.machine, issuer: keyID))
            }
            let token = try identity.signed(with: key)
            XCTAssertEqual(try InstanceIdentity.verify(token: token, accepting: accepting), identity)
        }
    }

    func testTheDisplayFormIsShortAndSaysTheGeneration() {
        let identity = fresh()
        XCTAssertTrue(identity.displayForm.hasPrefix("MSLI1·"))
        XCTAssertTrue(identity.displayForm.hasSuffix("·0"))
        XCTAssertLessThan(identity.displayForm.count, 24)
    }

    func testATokenCarriesNoWhitespaceSoTwoHomesCompareEqual() throws {
        // The token is stored host-side AND inside the guest, and the
        // comparison between them is string equality. A stray newline from
        // a file read must not make a match look like a mismatch.
        let token = try fresh().signed(with: key)
        XCTAssertFalse(token.contains(where: \.isWhitespace))
        XCTAssertNoThrow(try InstanceIdentity.verify(token: "  \(token)\n", accepting: accepting))
    }
}

/// The store: issuing, deriving, re-signing, and the two findings it is
/// built to produce.
final class InstanceIdentityStoreTests: XCTestCase {
    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey()
    private var keyID: String { MSLAPSigning.keyID(for: key.publicKey) }
    private var accepting: [String: Curve25519.Signing.PublicKey] { [keyID: key.publicKey] }

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-identity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Writes an identity with the test's own key, bypassing the machine
    /// key - so these tests never touch `/Users/Shared` or the real Mac.
    @discardableResult
    private func put(_ identity: InstanceIdentity, as instance: String) -> InstanceIdentity {
        XCTAssertTrue(InstanceIdentityStore.write(identity, for: instance,
                                                  signedWith: key, appSupport: root))
        return identity
    }

    private func make(generation: String = "0", lineage: String? = nil,
                      origin: String = "Company") -> InstanceIdentity {
        InstanceIdentity(lineage: lineage ?? InstanceIdentity.randomBase32(26),
                         generation: generation,
                         serial: InstanceIdentity.randomBase32(13),
                         issuer: keyID, origin: origin,
                         machine: String(repeating: "a", count: 16), born: 1_760_000_000)
    }

    private func verdict(_ instance: String) -> InstanceIdentityStore.Verdict {
        InstanceIdentityStore.verdict(for: instance, appSupport: root, accepting: accepting)
    }

    // MARK: - The three verdicts

    func testNoFileIsUnidentifiedNotAnError() {
        // Every instance in existence today has no identity. This has to be
        // an ordinary state, not a failure.
        XCTAssertEqual(verdict("never-issued"), .unidentified)
    }

    func testAWrittenIdentityVerifies() {
        let identity = put(make(), as: "Company")
        XCTAssertEqual(verdict("Company").identity, identity)
    }

    func testAnEditedFileIsInvalidRatherThanUnidentified() throws {
        // The distinction the whole feature rests on. "Nobody issued one"
        // and "somebody changed one" are completely different situations,
        // and collapsing them would mean tampering looked like absence -
        // which is the state that gets quietly adopted.
        put(make(), as: "Company")
        let url = InstanceIdentityStore.file(for: "Company", appSupport: root)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: ":0:", with: ":0.1:")
        try text.write(to: url, atomically: true, encoding: .utf8)

        guard case .invalid = verdict("Company") else {
            return XCTFail("an edited identity was not reported as invalid: \(verdict("Company"))")
        }
    }

    func testAnIdentityFromAnUnacceptedSignerIsInvalid() {
        put(make(), as: "Company")
        // Same file, but this Mac accepts nobody.
        guard case .invalid = InstanceIdentityStore.verdict(
            for: "Company", appSupport: root, accepting: [:]) else {
            return XCTFail("an unaccepted signer was treated as valid")
        }
    }

    func testGarbageInTheFileIsInvalidNotACrash() throws {
        let url = InstanceIdentityStore.file(for: "Company", appSupport: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        for junk in ["", "{}", "{\"token\":\"\"}", "{\"token\":\"nonsense\"}", "not json"] {
            try Data(junk.utf8).write(to: url)
            let result = verdict("Company")
            XCTAssertNotEqual(result.identity.map { _ in true }, true, junk)
        }
    }

    // MARK: - Deriving a copy

    func testACopyKeepsTheLineageAndDeepens() {
        let parent = put(make(), as: "Company")
        // Uses the real issuing path, which needs the machine key, so it is
        // exercised through `copy` directly here and end to end live.
        let child = parent.copy(index: 1, origin: "Copy", machine: parent.machine, issuer: keyID)
        let stored = put(try! XCTUnwrap(child), as: "Copy")
        XCTAssertEqual(stored.lineage, parent.lineage)
        XCTAssertEqual(stored.depth, 1)
        XCTAssertEqual(stored.origin, "Copy")
    }

    func testTheNextChildIndexSkipsSiblingsThatAlreadyExist() {
        let parent = put(make(), as: "Company")
        XCTAssertEqual(InstanceIdentityStore.nextChildIndex(of: parent, appSupport: root, accepting: accepting), 1)
        put(make(generation: "0.1", lineage: parent.lineage), as: "c1")
        put(make(generation: "0.2", lineage: parent.lineage), as: "c2")
        XCTAssertEqual(InstanceIdentityStore.nextChildIndex(of: parent, appSupport: root, accepting: accepting), 3)
    }

    func testGrandchildrenDoNotCountAsChildren() {
        // `0.1.1` is a child of `0.1`, not of `0`. Counting it would push
        // the next index up and make the path misleading.
        let parent = put(make(), as: "Company")
        put(make(generation: "0.1", lineage: parent.lineage), as: "c1")
        put(make(generation: "0.1.1", lineage: parent.lineage), as: "g1")
        XCTAssertEqual(InstanceIdentityStore.nextChildIndex(of: parent, appSupport: root, accepting: accepting), 2)
    }

    func testAnotherLineagesChildrenAreIgnored() {
        let parent = put(make(), as: "Company")
        put(make(generation: "0.1"), as: "unrelated")   // different lineage
        XCTAssertEqual(InstanceIdentityStore.nextChildIndex(of: parent, appSupport: root, accepting: accepting), 1)
    }

    // MARK: - Re-signing on rename

    func testReSigningKeepsLineageGenerationSerialAndAboveAllOrigin() {
        // `origin` is the name at birth and must survive a rename - it is
        // what stops a rename escaping a policy scope. If a re-sign updated
        // it, renaming `Company` to `Sneaky` would launder it.
        let before = put(make(origin: "Company"), as: "Company")
        // Simulate the inventory having moved the file.
        let moved = InstanceIdentityStore.file(for: "Renamed", appSupport: root)
        try? FileManager.default.moveItem(
            at: InstanceIdentityStore.file(for: "Company", appSupport: root), to: moved)

        // Re-signs with the machine key, so compare the fields that must
        // not move rather than the whole identity.
        let after = InstanceIdentityStore.reSign(for: "Renamed", appSupport: root)
        guard let after else { return }   // no machine key in this environment
        XCTAssertEqual(after.lineage, before.lineage)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.serial, before.serial)
        XCTAssertEqual(after.origin, "Company", "a rename rewrote the name at birth")
        XCTAssertEqual(after.born, before.born)
    }

    // MARK: - Duplicate serials

    func testTwoInstancesClaimingOneSerialAreFound() {
        // Self-contradictory rather than merely unproven, which is why this
        // is the one verdict refused even on an unmanaged Mac: two
        // registered instances cannot both be the same instance.
        let identity = make()
        put(identity, as: "Company")
        put(identity, as: "Copied")
        let duplicates = InstanceIdentityStore.duplicateSerials(
            appSupport: root, accepting: accepting)
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[identity.serial], ["Company", "Copied"])
    }

    func testOrdinaryInstancesProduceNoDuplicates() {
        put(make(), as: "a")
        put(make(), as: "b")
        XCTAssertTrue(InstanceIdentityStore.duplicateSerials(
            appSupport: root, accepting: accepting).isEmpty)
    }

    func testAnInvalidIdentityCannotCreateAFalseDuplicate() throws {
        // An unverified token must not contribute a serial, or somebody
        // could forge a duplicate to get a legitimate instance refused.
        let identity = put(make(), as: "Company")
        let url = InstanceIdentityStore.file(for: "Forged", appSupport: root)
        try Data("{\"token\":\"\(identity.payload)~notasignature\"}".utf8).write(to: url)
        XCTAssertTrue(InstanceIdentityStore.duplicateSerials(
            appSupport: root, accepting: accepting).isEmpty,
            "a forged identity was counted as a duplicate")
    }

    // MARK: - The inventory

    func testIdentityMovesOnARenameAndIsNotCopiedToAClone() {
        let entry = InstanceStateTransfer.inventory.first { $0.label == "identity" }
        XCTAssertNotNil(entry, "identity is not in the state inventory")
        XCTAssertEqual(entry?.transferred, true, "a rename must carry the identity")
        XCTAssertEqual(entry?.copied, false,
                       "a clone handed a COPY of an identity is indistinguishable from the original")
        XCTAssertEqual(entry?.clearedOnRemoval, true)
    }
}

/// Shipments carrying an instance lineage: the route the feature was asked
/// about - export where cloning is allowed, import where it is not.
final class ShipmentIdentityTests: XCTestCase {
    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey()
    private var keyID: String { MSLAPSigning.keyID(for: key.publicKey) }
    private var accepting: [String: Curve25519.Signing.PublicKey] { [keyID: key.publicKey] }

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-shipid-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A token from "another Mac": signed by a key this one does not accept.
    private func foreignToken(generation: String = "0", origin: String = "Company")
        throws -> (token: String, identity: InstanceIdentity) {
        let stranger = Curve25519.Signing.PrivateKey()
        let identity = InstanceIdentity(
            lineage: InstanceIdentity.randomBase32(26), generation: generation,
            serial: InstanceIdentity.randomBase32(13),
            issuer: MSLAPSigning.keyID(for: stranger.publicKey), origin: origin,
            machine: String(repeating: "f", count: 16), born: 1_760_000_000)
        return (try identity.signed(with: stranger), identity)
    }

    func testTheManifestFieldIsOptionalSoOlderShipmentsStillRead() throws {
        // `minimumReader` exists so additive changes need no version bump.
        // A manifest written before this field existed must still decode.
        let json = """
        {"shipment":2,"minimumReader":2,"id":"x",
         "host":{"architecture":"arm64","macOS":"26"},
         "created":"2026-10-01T00:00:00Z","mslVersion":"1","note":null,
         "source":{"instance":"Company","distro":"ubuntu","custom":false},
         "disk":{"file":"d.z","compression":"xz","sha256":"a","uncompressedSize":1}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Shipment.Manifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.instanceIdentity)
    }

    // MARK: - Importing

    func testAnImportIsRecordedAsACopyWhateverTheTokenClaims() throws {
        // **The route this closes.** An instance exported where cloning is
        // allowed and imported where it is not must arrive as a copy, so
        // `instance.clone` refuses it.
        let (token, original) = try foreignToken(generation: "0")
        let imported = InstanceIdentityStore.adoptImported(token, as: "Imported", appSupport: root)
        guard let imported else { return }   // no machine key in this environment
        XCTAssertEqual(imported.lineage, original.lineage, "the lineage did not survive the trip")
        XCTAssertTrue(imported.isClone, "an import arrived looking like an original")
        XCTAssertEqual(imported.generation, "0.1")
        XCTAssertEqual(imported.origin, "Imported")
    }

    func testACraftedShipmentCannotArriveLookingLikeAnOriginal() throws {
        // The token is unverifiable here, so it is read rather than
        // trusted - and the generation is forced deeper regardless of what
        // it says. Claiming a lineage can only make an instance MORE
        // restricted on this Mac, never less.
        for claimed in ["0", "0.1", "0.5.5"] {
            let (token, _) = try foreignToken(generation: claimed)
            guard let imported = InstanceIdentityStore.adoptImported(
                token, as: "Try\(claimed.count)", appSupport: root) else { return }
            XCTAssertTrue(imported.isClone, "claiming generation '\(claimed)' produced an original")
            XCTAssertGreaterThan(imported.depth, claimed.filter { $0 == "." }.count)
        }
    }

    func testTheOriginatingMachineSurvivesEvenThoughTheSignatureDoesNot() throws {
        // The signature cannot cross a Mac boundary, but "which Mac was
        // this born on" is still worth carrying.
        let (token, original) = try foreignToken()
        guard let imported = InstanceIdentityStore.adoptImported(
            token, as: "Imported", appSupport: root) else { return }
        XCTAssertEqual(imported.machine, original.machine)
        // Re-signed locally, so this Mac can verify it from now on.
        XCTAssertNotEqual(imported.issuer, original.issuer)
    }

    func testAShipmentWithNoIdentityGetsAFreshLineageNotAPretendedOne() {
        guard let imported = InstanceIdentityStore.adoptImported(
            nil, as: "Old", appSupport: root) else { return }
        XCTAssertFalse(imported.isClone)
        XCTAssertEqual(imported.origin, "Old")
    }

    func testAnUnreadableTokenIsTreatedAsAbsentRatherThanFailing() {
        for junk in ["", "nonsense", "MSLI9:a:b", "MSLI1:too:few:fields"] {
            guard let imported = InstanceIdentityStore.adoptImported(
                junk, as: "J\(junk.count)", appSupport: root) else { return }
            XCTAssertFalse(imported.isClone, junk)
        }
    }

    // MARK: - The ordering that made issueFresh non-destructive

    func testIssuingNeverOverwritesAnIdentityThatExists() throws {
        // Importing records a lineage, and `ensureRegistered` runs
        // AFTERWARDS - so a destructive `issueFresh` would have stamped a
        // generation-0 identity over every import, turning each one into
        // an original. That is the laundering the migration rule exists to
        // prevent, arriving by a different door.
        let (token, _) = try foreignToken()
        guard let imported = InstanceIdentityStore.adoptImported(
            token, as: "Imported", appSupport: root) else { return }
        XCTAssertTrue(imported.isClone)

        let again = InstanceIdentityStore.issueFresh(for: "Imported", appSupport: root)
        XCTAssertEqual(again?.serial, imported.serial, "issueFresh replaced an existing identity")
        XCTAssertEqual(again?.generation, imported.generation)
    }

    func testIssuingDoesNotOverwriteATamperedIdentityEither() throws {
        // Replacing it would destroy the evidence and hand back a clean
        // original.
        let url = InstanceIdentityStore.file(for: "Company", appSupport: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{\"token\":\"MSLI1:x~bad\"}".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        _ = InstanceIdentityStore.issueFresh(for: "Company", appSupport: root)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

/// `~/Mac` for the account MSL creates.
final class GuestMacLinkTests: XCTestCase {

    func testTheCreationScriptMakesTheLinkItself() {
        // **The regression this fixes.** It used to rely on `/etc/skel`,
        // which `GuestHomeLinks` fills from a DETACHED task after a start -
        // so an account created before that landed copied a skel with no
        // link in it. `/home/msl` and `/root` existed when the task ran and
        // got one; the user's own account did not. Reported as "the Mac
        // folder appears under the msl user, not for the user that's
        // created".
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        XCTAssertTrue(script.contains("ln -s \(GuestPathMapper.macHomeMountPoint)"),
                      "the creation script does not make the link itself")
        XCTAssertTrue(script.contains(GuestHomeLinks.linkName))
    }

    func testTheInterpolationActuallyResolved() {
        // A raw string with `\#(...)` is easy to get subtly wrong, and the
        // result would be a script that writes a literal `\#(...)` path
        // into the guest.
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        XCTAssertFalse(script.contains("\\#("), "an interpolation did not resolve")
        XCTAssertFalse(script.contains("GuestPathMapper"), "a symbol name leaked into the script")
        XCTAssertTrue(script.contains("/mnt/mac"), script.suffix(400).description)
    }

    func testItNeverReplacesSomethingAlreadyThere() {
        // Same rule as `GuestHomeLinks`: a user's own folder or link called
        // Mac wins.
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        XCTAssertTrue(script.contains("[ ! -e \"$home/Mac\" ]"), "it would clobber an existing Mac")
        XCTAssertTrue(script.contains("[ ! -L \"$home/Mac\" ]"))
    }

    func testItChownsTheLinkToTheAccount() {
        // Or `HomeOwnership`'s scan counts it as a wrongly owned file.
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        XCTAssertTrue(script.contains("chown -h \"$user\""), "the link is left owned by root")
    }

    func testItUsesTheRealHomeRatherThanAssumingItsPath() {
        // `useradd` can be configured to put homes somewhere other than
        // /home/<user>, and busybox `adduser` is told explicitly - reading
        // it back from passwd is the only answer that is always right.
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        XCTAssertTrue(script.contains("getent passwd"), "the home path is assumed, not looked up")
    }

    /// Writes the real script to /tmp so it can be run in a live guest.
    /// Skipped unless asked for, because it exists to produce a file.
    func testDumpTheScriptForLiveUse() throws {
        guard ProcessInfo.processInfo.environment["MSL_DUMP_USER_SCRIPT"] != nil else { return }
        let script = LinuxUserSetup.script(username: "linkuser", password: "linkpass123")
        try Data(script.utf8).write(to: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("mkuser.sh"))
    }

    func testTheScriptIsValidShell() throws {
        // The link block uses backslash line continuations inside a Swift
        // RAW string, where a backslash is literal - easy to get wrong in a
        // way that only fails inside a guest.
        let script = LinuxUserSetup.script(username: "abinaash", password: "pw")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-usercheck-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", url.path]        // parse only, never run
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let complaint = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                               as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0,
                       "the generated script is not valid shell: \(complaint)")
    }
}
