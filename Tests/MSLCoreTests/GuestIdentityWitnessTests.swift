import XCTest
import CryptoKit
@testable import MSLCore

/// The guest-side provenance marker: what it catches, and the two things it
/// must never do.
final class GuestIdentityWitnessTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()
    private var keyID: String { MSLAPSigning.keyID(for: key.publicKey) }

    private func identity(lineage: String? = nil, generation: String = "0") -> InstanceIdentity {
        InstanceIdentity(lineage: lineage ?? InstanceIdentity.randomBase32(26),
                         generation: generation, serial: InstanceIdentity.randomBase32(13),
                         issuer: keyID, origin: "Company",
                         machine: String(repeating: "a", count: 16), born: 1_760_000_000)
    }

    // MARK: - Agreement

    func testIdenticalTokensAgree() throws {
        let token = try identity().signed(with: key)
        XCTAssertEqual(GuestIdentityWitness.compare(hostToken: token, guestContents: token,
                                                    everWritten: true), .consistent)
    }

    func testWhitespaceFromAFileReadDoesNotLookLikeAMismatch() throws {
        // `cat` through a shell adds a newline often enough that this would
        // otherwise report every single instance as inconsistent.
        let token = try identity().signed(with: key)
        for wrapped in ["\(token)\n", "  \(token)  ", "\(token)\r\n"] {
            XCTAssertEqual(GuestIdentityWitness.compare(hostToken: token, guestContents: wrapped,
                                                        everWritten: true),
                           .consistent, wrapped.debugDescription)
        }
    }

    // MARK: - New versus deleted, which is the distinction that matters

    func testAnEmptyGuestOnAFirstBootIsNotYetWritten() throws {
        let token = try identity().signed(with: key)
        for empty in [nil, "", "   ", "\n"] {
            XCTAssertEqual(GuestIdentityWitness.compare(hostToken: token, guestContents: empty,
                                                        everWritten: false),
                           .notYetWritten)
        }
    }

    func testAnEmptyGuestAfterOneWasWrittenIsMissingNotNew() throws {
        // **Without this distinction a first boot and a deleted marker are
        // identical** - and treating the second as the first means
        // rewriting it, which stamps this instance's identity onto
        // whatever disk is actually there.
        let token = try identity().signed(with: key)
        XCTAssertEqual(GuestIdentityWitness.compare(hostToken: token, guestContents: "",
                                                    everWritten: true),
                       .missing)
    }

    func testAMissingMarkerIsNeverRewritten() {
        // The tempting "self-healing" behaviour, and it destroys the
        // feature. A guest can make itself inconclusive; it must not be
        // able to make itself innocent.
        let action = GuestIdentityWitness.action(for: .missing, instance: "lab-1", managed: true)
        guard case .report(let detail) = action else {
            return XCTFail("a missing marker produced \(action), not a report")
        }
        XCTAssertTrue(detail.contains("not rewritten"), detail)
        XCTAssertNotEqual(action, .write)
    }

    func testAnUnreadableMarkerIsAlsoNeverRewritten() {
        let action = GuestIdentityWitness.action(for: .unreadable("junk"),
                                                 instance: "lab-1", managed: true)
        guard case .report = action else { return XCTFail("\(action)") }
    }

    // MARK: - The swap it exists to catch

    func testADiskFromAnotherLineageIsTheSwapAndStopsAManagedInstance() throws {
        // Swap `lab-1.img` for a copy of `Company.img`: every host-side
        // check passes, because the host record was never touched. Only the
        // disk knows.
        let host = try identity().signed(with: key)
        let intruder = try identity().signed(with: key)   // different lineage
        let finding = GuestIdentityWitness.compare(hostToken: host, guestContents: intruder,
                                                   everWritten: true)
        guard case .differentLineage = finding else {
            return XCTFail("a swapped disk was not detected: \(finding)")
        }
        guard case .stop(let why) = GuestIdentityWitness.action(
            for: finding, instance: "lab-1", managed: true) else {
            return XCTFail("a managed Mac did not stop a swapped disk")
        }
        XCTAssertTrue(why.contains("replaced with a copy"), why)
    }

    func testAnUnmanagedMacReportsTheSwapAndKeepsRunning() throws {
        // With no administrator there is no intent to serve, and the rule
        // the enforcement code already states applies: loud and working
        // beats silent and bricked.
        let host = try identity().signed(with: key)
        let intruder = try identity().signed(with: key)
        let finding = GuestIdentityWitness.compare(hostToken: host, guestContents: intruder,
                                                   everWritten: true)
        guard case .report(let detail) = GuestIdentityWitness.action(
            for: finding, instance: "mine", managed: false) else {
            return XCTFail("an unmanaged Mac stopped an instance over provenance")
        }
        XCTAssertTrue(detail.contains("not managed"), detail)
    }

    // MARK: - Why lineage and not serial

    func testAFreshCloneCarryingItsParentsMarkerIsNotCalledASwap() throws {
        // **A legitimate clone's disk starts as a byte copy of its
        // parent's**, so its marker says the parent's serial until the
        // first boot rewrites it. Comparing serials would call every
        // single fresh clone a swapped disk; comparing lineage asks the
        // question that matters.
        let parent = identity()
        let clone = try XCTUnwrap(parent.copy(index: 1, origin: "Copy",
                                              machine: parent.machine, issuer: keyID))
        let finding = GuestIdentityWitness.compare(
            hostToken: try clone.signed(with: key),
            guestContents: try parent.signed(with: key),
            everWritten: true)
        XCTAssertEqual(finding, .notYetWritten,
                       "a fresh clone was reported as a swapped disk")
        XCTAssertEqual(GuestIdentityWitness.action(for: finding, instance: "Copy", managed: true),
                       .write)
    }

    // MARK: - Nothing to compare

    func testNoHostIdentityMeansNoFinding() {
        for host in [nil, "", "nonsense"] {
            XCTAssertEqual(GuestIdentityWitness.compare(hostToken: host, guestContents: "anything",
                                                        everWritten: true),
                           .nothingToCompare, String(describing: host))
        }
        XCTAssertEqual(GuestIdentityWitness.action(for: .nothingToCompare, instance: "x",
                                                   managed: true), .nothing)
    }

    // MARK: - The command that writes it

    func testTheWriteCommandRefusesAnythingThatCouldEscapeItsQuoting() {
        // It is interpolated into a shell command run as root in the guest.
        for nasty in ["a'b", "a\nb", "a`b`", "a\\b", String(repeating: "x", count: 5000)] {
            XCTAssertNil(GuestIdentityWitness.writeCommand(token: nasty), nasty.prefix(12) + "…")
        }
    }

    func testTheWriteCommandAcceptsARealTokenAndMakesItReadOnly() throws {
        let token = try identity().signed(with: key)
        let command = try XCTUnwrap(GuestIdentityWitness.writeCommand(token: token))
        XCTAssertTrue(command.contains(GuestIdentityWitness.guestPath))
        XCTAssertTrue(command.contains("chmod 0444"),
                      "the marker is left writable by anything in the guest")
    }

    func testARealTokensAlphabetContainsNothingThatNeedsQuoting() throws {
        // The guard above would be useless if MSL's own tokens tripped it.
        for _ in 0..<100 {
            let token = try identity(generation: "0.1.2").signed(with: key)
            XCTAssertNotNil(GuestIdentityWitness.writeCommand(token: token), token)
        }
    }

    // MARK: - The host-side flag

    func testTheWitnessedFlagDefaultsToFalseForRecordsWrittenBeforeItExisted() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-witness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = InstanceIdentityStore.file(for: "Company", appSupport: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // No `witnessed` key at all, as every record written before this.
        try Data("{\"token\":\"x~y\"}".utf8).write(to: url)
        XCTAssertFalse(InstanceIdentityStore.hasBeenWitnessed("Company", appSupport: root))

        XCTAssertTrue(InstanceIdentityStore.markWitnessed("Company", appSupport: root))
        XCTAssertTrue(InstanceIdentityStore.hasBeenWitnessed("Company", appSupport: root))
    }

    func testReIssuingAnIdentityResetsTheFlagBecauseTheMarkerIsNowStale() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-witness2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = identity()
        XCTAssertTrue(InstanceIdentityStore.write(first, for: "Company",
                                                  signedWith: key, appSupport: root))
        InstanceIdentityStore.markWitnessed("Company", appSupport: root)
        XCTAssertTrue(InstanceIdentityStore.hasBeenWitnessed("Company", appSupport: root))

        // A rename re-signs, so the marker inside the guest holds the old
        // token and has to be written again.
        XCTAssertTrue(InstanceIdentityStore.write(identity(), for: "Company",
                                                  signedWith: key, appSupport: root))
        XCTAssertFalse(InstanceIdentityStore.hasBeenWitnessed("Company", appSupport: root),
                       "a re-issued identity still claims its stale marker is current")
    }
}
