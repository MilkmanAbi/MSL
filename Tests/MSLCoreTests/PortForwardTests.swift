import XCTest
@testable import MSLCore

/// Port forwarding: the parsing, the clash rules, and the two things that
/// are easy to get quietly wrong (port 0 and a privileged port).
final class PortForwardTests: XCTestCase {

    private var file: URL!

    override func setUp() {
        super.setUp()
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forwards-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    // MARK: - Parsing

    func testAPairParsesBothWays() {
        XCTAssertEqual(PortForward.parsePair("8080:3000").map { [$0.host, $0.guest] }, [8080, 3000])
        // One number means the same port both sides, which is what somebody
        // forwarding 3000 almost always wants.
        XCTAssertEqual(PortForward.parsePair("3000").map { [$0.host, $0.guest] }, [3000, 3000])
    }

    func testPortZeroIsRejected() {
        // **`bind` reads 0 as "any free port".** A forward asked for on
        // port 0 would land somewhere nobody could predict, and the address
        // MSL printed back would be wrong - so it is refused rather than
        // honoured as a surprise.
        XCTAssertNil(PortForward.parsePair("0:3000"))
        XCTAssertNil(PortForward.parsePair("8080:0"))
        XCTAssertNil(PortForward.parsePair("0"))
    }

    func testObviousRubbishIsRejected() {
        for text in ["", ":", "8080:", ":3000", "eighty:3000", "8080:3000:1", "-1:3000",
                     "70000:3000"] {
            XCTAssertNil(PortForward.parsePair(text), text)
        }
    }

    func testAPrivilegedPortIsExplainedRatherThanFailingAtBind() {
        // errno 13 on port 80 sends people to look at firewalls for an
        // hour. The note names the real reason and suggests a port.
        let note = PortForward.privilegedPortNote(80)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("8080"), note!)
        XCTAssertNil(PortForward.privilegedPortNote(8080))
        XCTAssertNotNil(PortForward.privilegedPortNote(1023))
        XCTAssertNil(PortForward.privilegedPortNote(1024))
    }

    // MARK: - Clashes

    func testOneHostPortCannotServeTwoInstances() {
        // Whichever registered first would win and the second would
        // silently do nothing, so the second is refused with the reason.
        let existing = [PortForward(instance: "work", hostPort: 8080, guestPort: 3000, route: .direct)]
        let clash = PortForward(instance: "other", hostPort: 8080, guestPort: 5000, route: .direct)
        let why = PortForwardStore.blocker(for: clash, existing: existing)
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("work"), why!)

        // The same instance asking twice gets a clearer message, naming
        // where that port already goes.
        let repeated = PortForward(instance: "work", hostPort: 8080, guestPort: 9000, route: .direct)
        XCTAssertTrue(PortForwardStore.blocker(for: repeated, existing: existing)!
            .contains("already goes to work:3000"))
    }

    func testTheSameGuestPortMayBeForwardedTwice() {
        // Only the HOST port has to be unique: forwarding 3000 to both 8080
        // and 8081 is odd but harmless, and refusing it would be a rule
        // with nothing behind it.
        let existing = [PortForward(instance: "work", hostPort: 8080, guestPort: 3000, route: .direct)]
        let second = PortForward(instance: "work", hostPort: 8081, guestPort: 3000, route: .direct)
        XCTAssertNil(PortForwardStore.blocker(for: second, existing: existing))
    }

    // MARK: - The store

    func testAddRemoveAndForgetRoundTrip() {
        let work = PortForward(instance: "work", hostPort: 8080, guestPort: 3000, route: .direct)
        let other = PortForward(instance: "other", hostPort: 9090, guestPort: 3000, route: .viaSSH)
        XCTAssertTrue(PortForwardStore.save([work, other], to: file))

        XCTAssertEqual(PortForwardStore.forInstance("work", from: file).map(\.pair), ["8080:3000"])
        XCTAssertEqual(PortForwardStore.remove(hostPort: 8080, instance: "work", from: file)?.pair,
                       "8080:3000")
        XCTAssertEqual(PortForwardStore.load(from: file).count, 1)

        // Forgetting an instance takes only its own.
        PortForwardStore.forget(instance: "other", from: file)
        XCTAssertTrue(PortForwardStore.load(from: file).isEmpty)
    }

    func testRemovingByPortWillNotTakeAnotherInstancesForward() {
        let work = PortForward(instance: "work", hostPort: 8080, guestPort: 3000, route: .direct)
        XCTAssertTrue(PortForwardStore.save([work], to: file))
        // Naming the wrong instance removes nothing, rather than removing
        // by port alone and surprising somebody.
        XCTAssertNil(PortForwardStore.remove(hostPort: 8080, instance: "other", from: file))
        XCTAssertEqual(PortForwardStore.load(from: file).count, 1)
        // With no instance named it matches on the port, which is what
        // `msl unforward 8080` wants - a host port is unique.
        XCTAssertNotNil(PortForwardStore.remove(hostPort: 8080, instance: nil, from: file))
    }

    func testAMissingFileIsNoForwardsRatherThanAFailure() {
        XCTAssertEqual(PortForwardStore.load(from: file), [])
        XCTAssertEqual(PortForwardStore.forInstance("work", from: file), [])
        XCTAssertNil(PortForwardStore.remove(hostPort: 8080, instance: nil, from: file))
    }

    func testTheDescriptionNamesTheRoute() {
        // The two routes have genuinely different reach, so a list that did
        // not distinguish them would hide the reason one of them cannot
        // see a loopback-bound server.
        XCTAssertEqual(PortForward(instance: "work", hostPort: 8080, guestPort: 3000,
                                   route: .direct).description,
                       "localhost:8080 -> work:3000")
        XCTAssertTrue(PortForward(instance: "work", hostPort: 8080, guestPort: 3000,
                                  route: .viaSSH).description.contains("through SSH"))
    }

    // MARK: - MSLAP

    func testOpeningAForwardIsGatedAndClosingOneIsNot() {
        // Lowercase: `MSLAPCapability.init` normalises every key, so a
        // policy written with either spelling matches.
        XCTAssertEqual(MSLAPEnforcement.requirements(
            for: .forwardAdd(instance: "work", hostPort: 8080, guestPort: 3000, viaSSH: false))
            .map(\.capability.key), ["network.portforward"])

        // **Never refused.** Closing one reduces what this Mac exposes, and
        // refusing it would trap a forward open: deny network.portForward
        // after somebody opened a port and they could not close it.
        XCTAssertEqual(MSLAPEnforcement.requirements(for: .forwardRemove(hostPort: 8080)).count, 0)
        XCTAssertEqual(MSLAPEnforcement.requirements(for: .forwardList(instance: "work")).count, 0)

        let policy = MSLAPPolicy(
            issued: Date(), issuer: "Test",
            scopes: [.init(match: "*", deny: [MSLAPCapability("network.portForward")],
                           reason: "no forwards here")],
            message: nil)
        XCTAssertNotNil(MSLAPEnforcement.check(
            .forwardAdd(instance: "work", hostPort: 8080, guestPort: 3000, viaSSH: false),
            policy: policy, issuer: "Test"))
        XCTAssertNil(MSLAPEnforcement.check(.forwardRemove(hostPort: 8080),
                                            policy: policy, issuer: "Test"))
    }

    // MARK: - The wire

    func testTheRequestsSurviveTheWire() {
        for request in [DaemonProtocol.ControlRequest
                            .forwardAdd(instance: "work", hostPort: 8080, guestPort: 3000, viaSSH: false),
                        .forwardAdd(instance: "work", hostPort: 8080, guestPort: 3000, viaSSH: true),
                        .forwardRemove(hostPort: 8080),
                        .forwardList(instance: "work")] {
            let line = String(decoding: request.encode(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("did not parse: \(line)")
            }
            XCTAssertEqual(String(decoding: parsed.encode(), as: UTF8.self),
                           String(decoding: request.encode(), as: UTF8.self))
        }
    }

    func testAnUnusablePortFailsToParse() {
        // Rejected at parse time, so a nonsense port never reaches the
        // handler as a zero - which `bind` would read as "any free port".
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("FORWARD_ADD work 0 3000 DIRECT"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("FORWARD_ADD work 8080 0 DIRECT"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("FORWARD_ADD work 99999 3000 DIRECT"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("FORWARD_ADD --shutdown 8080 3000 DIRECT"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("FORWARD_REMOVE 0"))
    }

    func testAForwardNeverCountsAsStartingAnInstance() {
        // It REQUIRES a running guest and refuses when there is not one, so
        // counting it as a start would be a contradiction - and would make
        // the idle timer treat a listed forward as a reason to boot.
        for request in [DaemonProtocol.ControlRequest
                            .forwardAdd(instance: "work", hostPort: 8080, guestPort: 3000, viaSSH: false),
                        .forwardRemove(hostPort: 8080), .forwardList(instance: "work")] {
            XCTAssertNil(request.startsInstance, "\(request)")
        }
    }
}
