import XCTest
@testable import MSLCore

/// The wait that sets up a user session inside a guest.
///
/// It runs before **every** guest command, so anything it waits for in vain
/// is paid by every app launch. It once waited for `/run/user/$uid/bus` while
/// deciding the outcome from `/run/user/$uid`, and on Fedora those never
/// agree: the directory is there and that socket never appears, so each
/// command sat for the full five seconds and then succeeded anyway.
/// Measured: 5.25s per command on Fedora against 0.12s on Alpine.
final class GuestSessionWaitTests: XCTestCase {

    private var script: String { GuestIntegration.userSessionCommand(user: "abi") }

    /// **The regression.** Waiting on the session bus socket is what cost the
    /// five seconds, and nothing needed it - MSL supplies the session bus.
    func testItDoesNotWaitForASessionBusSocket() {
        XCTAssertFalse(script.contains("/bus\" ]"),
                       "waiting for /run/user/$uid/bus costs five seconds on Fedora and buys nothing")
        XCTAssertFalse(script.contains("-S \"/run/user/$msl_uid/bus\""))
    }

    /// What it waits for and what it reports must be the same thing, or the
    /// wait can never end on a guest that is already fine.
    func testItWaitsForTheSameThingItJudgesOn() {
        XCTAssertTrue(script.contains("! -d \"/run/user/$msl_uid\""),
                      "the loop should wait for the runtime directory")
        XCTAssertTrue(script.contains("if [ -d \"/run/user/$msl_uid\" ]; then echo \"MSL-SESSION-OK\""))
    }

    /// A guest that already has its runtime directory must not wait at all.
    func testThereIsNoWaitWhenTheDirectoryIsAlreadyThere() {
        guard let loop = script.range(of: "while [ $msl_i") else {
            return XCTFail("no wait loop at all")
        }
        let before = script[..<loop.lowerBound]
        XCTAssertTrue(before.contains("if [ ! -d \"/run/user/$msl_uid\" ]; then"),
                      "the loop must sit inside a check that the directory is missing")
    }

    /// The wait is still there for the case it was written for: a first start
    /// where logind has not made the directory yet.
    func testTheWaitStillExistsForAFirstStart() {
        XCTAssertTrue(script.contains("loginctl enable-linger"))
        XCTAssertTrue(script.contains("sleep 0.2"))
    }

    /// A guest with no logind says so immediately rather than waiting.
    func testAGuestWithoutLogindExitsAtOnce() {
        XCTAssertTrue(script.contains("command -v loginctl >/dev/null 2>&1 || { echo \"MSL-SESSION-NONE\"; exit 0; }"))
    }
}
