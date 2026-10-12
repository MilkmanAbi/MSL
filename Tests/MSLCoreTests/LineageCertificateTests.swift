import XCTest
import CryptoKit
@testable import MSLCore

/// Lineage certificates: the one tier a local user cannot forge.
///
/// The tests that matter are about *where the authority comes from*. An
/// instance identity is signed by a key `mslhd` can read, so it is
/// tamper-evident. A certificate is signed by the MSLAP key, which a fleet
/// keeps off the machine - so nobody holding only this Mac can mint one,
/// and nothing here may accidentally accept a signer that weakens that.
final class LineageCertificateTests: XCTestCase {

    private let admin = Curve25519.Signing.PrivateKey()
    private var pinned: [String: Curve25519.Signing.PublicKey] {
        [MSLAPSigning.keyID(for: admin.publicKey): admin.publicKey]
    }
    private let lineage = InstanceIdentity.randomBase32(InstanceIdentity.lineageLength)

    private func certificate(trust: LineageCertificate.Trust = .certified,
                             lineage: String? = nil) -> LineageCertificate {
        LineageCertificate(lineage: lineage ?? self.lineage, trust: trust,
                           label: "Acme Standard Image 2026", issuer: "Acme IT")
    }

    // MARK: - Signing

    func testASignedCertificateVerifies() throws {
        let signed = try certificate().signed(with: admin)
        XCTAssertNil(signed.verify(pinned: pinned))
    }

    func testAnUnsignedCertificateIsRefused() {
        XCTAssertEqual(certificate().verify(pinned: pinned), .unsigned)
    }

    func testEditingAnyFieldBreaksIt() throws {
        let signed = try certificate().signed(with: admin)
        var edited = signed

        edited.label = "Something Else"
        XCTAssertEqual(edited.verify(pinned: pinned), .mismatch, "the label is not signed")
        edited = signed
        edited.trust = .revoked
        XCTAssertEqual(edited.verify(pinned: pinned), .mismatch, "the trust level is not signed")
        edited = signed
        edited.lineage = InstanceIdentity.randomBase32(InstanceIdentity.lineageLength)
        XCTAssertEqual(edited.verify(pinned: pinned), .mismatch, "the lineage is not signed")
        edited = signed
        edited.issuer = "Someone Else"
        XCTAssertEqual(edited.verify(pinned: pinned), .mismatch, "the issuer is not signed")
        edited = signed
        edited.reason = "made up"
        XCTAssertEqual(edited.verify(pinned: pinned), .mismatch, "the reason is not signed")
    }

    func testACertificateFromAKeyThisMacDoesNotPinIsRefused() throws {
        // **This is the whole tier.** Anyone can make a key and sign
        // whatever they like; what decides is whether the deployment
        // pinned the signer.
        let stranger = Curve25519.Signing.PrivateKey()
        let signed = try certificate().signed(with: stranger)
        guard case .unknownKey(let id) = signed.verify(pinned: pinned) else {
            return XCTFail("a certificate from an unpinned key verified")
        }
        XCTAssertEqual(id, MSLAPSigning.keyID(for: stranger.publicKey))
    }

    func testTheAuthorityIsTheAdminKeyNotTheMachineKey() throws {
        // Accepting an identity signer here would let the machine key -
        // which the person using the Mac can read - certify its own
        // lineages, which is the one thing this tier exists not to allow.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MSLCore/LineageCertificate.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("MSLAPKeyStore.pinned()"))
        XCTAssertFalse(source.contains("InstanceIdentityKey.accepted()"),
                       "a certificate is being checked against the identity signers, which "
                       + "would let the machine key certify its own lineages")
    }

    func testAMalformedLineageIsRefusedBeforeAnythingElse() throws {
        for bad in ["", "short", String(repeating: "z", count: 26) + "x",
                    String(repeating: "1", count: 26)] {
            let signed = try certificate(lineage: bad).signed(with: admin)
            XCTAssertEqual(signed.verify(pinned: pinned), .malformedLineage, bad)
        }
    }

    func testAFutureFormatIsRefusedRatherThanGuessedAt() throws {
        var future = try certificate().signed(with: admin)
        future.format = LineageCertificate.formatVersion + 1
        guard case .unsupportedFormat = future.verify(pinned: pinned) else {
            return XCTFail("a newer format was not refused")
        }
    }

    // MARK: - Decoding

    func testACertificateWithUnknownFieldsStillDecodes() throws {
        // The lesson the capability catalogue and the shipment manifest
        // both learned: a file written by a newer MSL must not fail to
        // read because of a field this build has never heard of.
        let json = """
        {"format":1,"lineage":"\(lineage)","trust":"certified",
         "label":"Acme","issued":"2026-10-01T00:00:00Z",
         "somethingFromTheFuture":{"nested":true}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LineageCertificate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.lineage, lineage)
        XCTAssertEqual(decoded.trust, .certified)
    }

    func testAMinimalCertificateDecodesWithSensibleDefaults() throws {
        let json = "{\"lineage\":\"\(lineage)\"}"
        let decoded = try JSONDecoder().decode(LineageCertificate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.trust, .certified)
        XCTAssertFalse(decoded.label.isEmpty)
        XCTAssertNil(decoded.signature)
        // And with no signature it is refused, so a minimal file is
        // readable without being trusted.
        XCTAssertEqual(decoded.verify(pinned: pinned), .unsigned)
    }

    // MARK: - Admission

    private func decide(_ certificate: LineageCertificateStore.Verdict,
                        identity: InstanceIdentity? = nil,
                        policy: MSLAPPolicy? = nil) -> InstanceAdmission.Decision {
        let used = identity ?? InstanceIdentity(
            lineage: lineage, generation: "0", serial: InstanceIdentity.randomBase32(13),
            issuer: "0000000000000000", origin: "Company",
            machine: "0000000000000000", born: 1_760_000_000)
        return InstanceAdmission.decide(.init(instance: "Company", verdict: .valid(used),
                                               policy: policy, certificate: certificate))
    }

    private func policy(denying keys: [String]) -> MSLAPPolicy {
        MSLAPPolicy(issued: Date(), issuer: "Acme IT",
                    scopes: [.init(match: "*", deny: keys.map(MSLAPCapability.init),
                                   reason: "fleet rule")],
                    message: nil)
    }

    func testARevocationRefusesEvenWithNoPolicyAtAll() {
        // **It outranks everything.** A revocation is an administrator's
        // signed statement that an image is retired or has leaked, signed
        // off this machine - so a capability that could override it would
        // make it no revocation at all.
        let decision = decide(.revoked(label: "Acme Image 2025", reason: "leaked"))
        guard case .refuse(let why) = decision else {
            return XCTFail("a revoked image started: \(decision)")
        }
        XCTAssertTrue(why.contains("Acme Image 2025"), why)
        XCTAssertTrue(why.contains("leaked"), why)
        XCTAssertTrue(why.contains("No capability can set a revocation aside"), why)
        // And **no claim about where the key is.** An earlier draft said
        // "signed by a key held off this Mac", which is true of a fleet
        // and false in local admin mode - where the key is right here.
        // A refusal is the worst possible moment for a feature to
        // overstate itself, so it points at `msl admin status` instead.
        XCTAssertFalse(why.contains("held off this Mac"), why)
        XCTAssertTrue(why.contains("msl admin status"), why)
    }

    func testARevocationOutranksAPolicyThatAllowsEverything() {
        XCTAssertTrue(decide(.revoked(label: "x", reason: nil),
                             policy: policy(denying: [])).isRefusal)
    }

    func testACertifiedImageStartsNormally() {
        XCTAssertEqual(decide(.certified(label: "Acme", issuer: "IT", rootOwned: true)), .allow)
        XCTAssertEqual(decide(.certified(label: "Acme", issuer: "IT", rootOwned: true),
                              policy: policy(denying: ["instance.clone"])), .allow)
    }

    func testAFleetCanRequireACertificate() {
        // Denied `instance.acceptUncertified`: only images the
        // administrator signed for may run.
        let decision = decide(.none, policy: policy(denying: ["instance.acceptUncertified"]))
        guard case .refuse(let why) = decision else {
            return XCTFail("an uncertified image started where that is denied: \(decision)")
        }
        XCTAssertTrue(why.contains("no certificate"), why)
    }

    func testThatCapabilityDefaultsToAllowedSoNothingBreaksToday() {
        // No Mac has a certificate yet. If this defaulted to refusing,
        // shipping it would stop every instance everywhere.
        XCTAssertEqual(decide(.none), .allow)
        XCTAssertEqual(decide(.none, policy: policy(denying: [])), .allow)
        let entry = MSLAPCapability.entry(for: MSLAPCapability("instance.acceptUncertified"))
        XCTAssertEqual(entry?.enforced, true)
        XCTAssertEqual(entry?.unavailable, false)
    }

    func testACertificateThatDoesNotVerifyIsRefusedNotIgnored() {
        // Ignoring it would make deleting a signature a way to get past a
        // revocation.
        guard case .refuse(let why) = decide(.invalid("the signature does not match")) else {
            return XCTFail("an unverifiable certificate was ignored")
        }
        XCTAssertTrue(why.contains("does not verify"), why)
    }

    func testTheCheckComesBeforeTheCopyRule() {
        // "This is not our image at all" is a more basic objection than
        // "this is a copy of one", so it is the reason reported.
        let clone = InstanceIdentity(lineage: lineage, generation: "0.1",
                                     serial: InstanceIdentity.randomBase32(13),
                                     issuer: "0000000000000000", origin: "Company",
                                     machine: "0000000000000000", born: 1_760_000_000)
        guard case .refuse(let why) = decide(
            .none, identity: clone,
            policy: policy(denying: ["instance.acceptUncertified", "instance.clone"]))
        else { return XCTFail() }
        XCTAssertTrue(why.contains("no certificate"), why)
    }

    // MARK: - The store's precedence

    func testASystemCertificateIsPreferredToAUserWritableOne() {
        // A user-owned copy must never shadow an administrator's, or
        // installing one locally would be a way to overwrite a revocation.
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MSLCore/LineageCertificate.swift"),
            encoding: .utf8)
        guard let source, let range = source.range(of: "public static func file(for lineage") else {
            return XCTFail("file(for:) has changed shape")
        }
        let body = source[range.upperBound...].prefix(400)
        guard let system = body.range(of: "systemDirectory"),
              let user = body.range(of: "userDirectory") else {
            return XCTFail("both locations are no longer consulted")
        }
        XCTAssertLessThan(system.lowerBound, user.lowerBound,
                          "the user location is searched first, so a local copy can shadow "
                          + "an administrator's certificate")
    }
}
