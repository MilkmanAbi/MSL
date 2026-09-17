import XCTest
@testable import MSLCore

/// The sandbox's gates.
///
/// The policy type is the only part of this feature that can be tested
/// without a booting guest, so it carries the invariants that would
/// otherwise only show up as a UI that lies: the wire form must survive a
/// round trip, and a malformed one must be refused outright rather than
/// applying half a sandbox.
final class SandboxPolicyTests: XCTestCase {

    // MARK: - Gates

    func testOpenIsTheDefault() {
        XCTAssertTrue(SandboxPolicy().isOpen)
        XCTAssertEqual(SandboxPolicy().closedGateCount, 0)
        XCTAssertEqual(SandboxPolicy().posture, .open)
    }

    func testSealedClosesEveryGate() {
        let sealedPolicy = SandboxPolicy.sealed
        XCTAssertEqual(sealedPolicy.closedGateCount, SandboxPolicy.Gate.allCases.count,
                       "a new gate must be added to `sealed` too, or the panic button stops sealing")
        for gate in SandboxPolicy.Gate.allCases {
            XCTAssertTrue(sealedPolicy.isClosed(gate), "\(gate) left open")
        }
        XCTAssertEqual(sealedPolicy.posture, .sealed)
    }

    func testOneClosedGateIsPartial() {
        var policy = SandboxPolicy()
        policy.set(.network, closed: true)
        XCTAssertEqual(policy.posture, .partial)
        XCTAssertFalse(policy.isOpen)
        XCTAssertFalse(policy.isSealed)
    }

    func testSetAndReadAgreeForEveryGate() {
        // Guards the hand-written switch pairs: it is easy to add a gate to
        // `set` and read the wrong stored property back out.
        for gate in SandboxPolicy.Gate.allCases {
            var policy = SandboxPolicy()
            policy.set(gate, closed: true)
            XCTAssertTrue(policy.isClosed(gate), "\(gate) did not read back as closed")
            XCTAssertEqual(policy.closedGateCount, 1, "\(gate) also changed another gate")
        }
    }

    func testEveryGateHasUserFacingText() {
        for gate in SandboxPolicy.Gate.allCases {
            XCTAssertFalse(gate.title.isEmpty)
            XCTAssertFalse(gate.symbol.isEmpty)
            XCTAssertGreaterThan(gate.closedDetail.count, 40,
                                 "\(gate) needs a real explanation of what closing it does")
        }
    }

    // MARK: - Wire form

    func testWireTokenRoundTripsForEveryCombination() {
        // All 16 states, because the token is positional and a transposed
        // pair would round-trip fine for the symmetric ones.
        for bits in 0..<16 {
            let policy = SandboxPolicy(networkCut: bits & 1 != 0,
                                       displayServerDisabled: bits & 2 != 0,
                                       inputFrozen: bits & 4 != 0,
                                       macHomeShareRevoked: bits & 8 != 0)
            XCTAssertEqual(SandboxPolicy.fromWireToken(policy.wireToken), policy,
                           "combination \(bits) did not survive the round trip")
        }
    }

    func testWireTokenIsPositionalAndStable() {
        // Pinning the order: the daemon protocol is text, and an older peer
        // reading a reordered token would silently apply the wrong gates.
        var policy = SandboxPolicy()
        policy.networkCut = true
        XCTAssertEqual(policy.wireToken, "1000")
        policy = SandboxPolicy(); policy.macHomeShareRevoked = true
        XCTAssertEqual(policy.wireToken, "0100")
        policy = SandboxPolicy(); policy.displayServerDisabled = true
        XCTAssertEqual(policy.wireToken, "0010")
        policy = SandboxPolicy(); policy.inputFrozen = true
        XCTAssertEqual(policy.wireToken, "0001")
        XCTAssertEqual(SandboxPolicy.sealed.wireToken, "1111")
    }

    func testMalformedTokensAreRefusedRatherThanPartlyApplied() {
        // Half a sandbox is worse than none: it looks closed and isn't.
        for bad in ["", "1", "111", "12ab", "abcd", "1x11"] {
            XCTAssertNil(SandboxPolicy.fromWireToken(bad), "'\(bad)' should not decode")
        }
    }

    func testExtraTrailingFlagsAreIgnoredNotRejected() {
        // Forward compatibility: a newer peer with a fifth gate must still
        // be understood by this build, for the four gates it knows.
        XCTAssertEqual(SandboxPolicy.fromWireToken("11111"), SandboxPolicy.sealed)
        XCTAssertEqual(SandboxPolicy.fromWireToken("1000zzz"),
                       SandboxPolicy(networkCut: true))
    }

    // MARK: - Protocol

    /// `ControlRequest` is not `Equatable`, so the round trip is checked by
    /// re-encoding what was parsed: encode -> parse -> encode must be
    /// stable, which catches a parser that drops or reorders an argument.
    func testSandboxCommandsRoundTripThroughTheDaemonProtocol() throws {
        for request in [DaemonProtocol.ControlRequest.sandboxGet(instance: "default"),
                        DaemonProtocol.ControlRequest.sandboxSet(instance: "work", token: "1010")] {
            let line = String(decoding: request.encode(), as: UTF8.self)
            let reparsed = try XCTUnwrap(DaemonProtocol.ControlRequest.parse(line),
                                         "did not parse: \(line)")
            XCTAssertEqual(String(decoding: reparsed.encode(), as: UTF8.self), line)
        }
    }

    func testMalformedSandboxCommandsDoNotParse() {
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("SANDBOX"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("SANDBOX GET"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("SANDBOX SET default"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("SANDBOX WIGGLE default 1111"))
    }

    /// Reading or changing the gates must never boot a VM. Sandboxing an
    /// instance *before* running it is the normal case, and a GET that
    /// started a VM would make the UI's own status poll boot everything.
    func testSandboxCommandsNeverStartAnInstance() {
        XCTAssertNil(DaemonProtocol.ControlRequest.sandboxGet(instance: "default").startsInstance)
        XCTAssertNil(DaemonProtocol.ControlRequest.sandboxSet(instance: "default", token: "1111").startsInstance)
    }

    // MARK: - Persistence

    func testPolicySurvivesEncodingToDiskFormat() throws {
        // A sandbox that forgets across a restart is not a sandbox, and the
        // stored form is what `applyStoredSandboxPolicy` reads on boot.
        let policy = SandboxPolicy(networkCut: true, inputFrozen: true)
        let decoded = try JSONDecoder().decode(SandboxPolicy.self,
                                               from: JSONEncoder().encode(policy))
        XCTAssertEqual(decoded, policy)
    }

    func testStoreIsPerInstance() {
        XCTAssertNotEqual(SandboxPolicyStore.file(for: "default"),
                          SandboxPolicyStore.file(for: "work"))
    }

    func testLoadingAnUnknownInstanceIsOpenNotAnError() {
        XCTAssertEqual(SandboxPolicyStore.load(instance: "no-such-instance-\(UUID().uuidString)"),
                       .open)
    }

    // MARK: - Input gate

    func testInputGateFailsOpenWithoutAnInstance() {
        // An `mslgui` app shim from an older build is started with no
        // `--instance`. Freezing every app whose provenance is unknown
        // would look exactly like the input system being broken.
        XCTAssertFalse(X11InputGate.shared.isFrozen(instance: nil))
    }

    func testInputGateReflectsAnExplicitSet() {
        let instance = "gate-test-\(UUID().uuidString)"
        X11InputGate.shared.setFrozen(true, instance: instance)
        XCTAssertTrue(X11InputGate.shared.isFrozen(instance: instance))
        X11InputGate.shared.setFrozen(false, instance: instance)
        XCTAssertFalse(X11InputGate.shared.isFrozen(instance: instance))
    }
}
