import XCTest
@testable import MSLCore

/// The daemon encodes this line and the app decodes it. Both sides use the
/// same code precisely so they cannot drift, and these tests are what make
/// that shared code trustworthy - particularly the reason field, which is
/// the only value containing spaces in a space-separated format.
final class BalloonWireTests: XCTestCase {
    func testFullStateRoundTrips() {
        var state = BalloonGovernor.State()
        state.availability = .active
        state.target = 3_221_225_472
        state.guestTotalBytes = 6_442_450_944
        state.guestInUseBytes = 1_234_567_890
        state.stallPercent = 4.25
        state.guestHasSwap = true
        state.adjustments = 17
        state.lastReason = .guestUnderPressure(stallPercent: 4.25)

        let decoded = BalloonGovernor.State.fromWireLine(state.wireLine)
        XCTAssertEqual(decoded.state.availability, .active)
        XCTAssertEqual(decoded.state.target, state.target)
        XCTAssertEqual(decoded.state.guestTotalBytes, state.guestTotalBytes)
        XCTAssertEqual(decoded.state.guestInUseBytes, state.guestInUseBytes)
        XCTAssertEqual(decoded.state.stallPercent, 4.25)
        XCTAssertTrue(decoded.state.guestHasSwap)
        XCTAssertEqual(decoded.state.adjustments, 17)
    }

    /// Every reason renders to prose containing spaces, and the last one on
    /// the line must survive intact rather than being chopped at the first
    /// space like every other field.
    func testReasonTextWithSpacesSurvives() {
        let reasons: [BalloonDecision.Reason] = [
            .guestUnderPressure(stallPercent: 12.5), .guestDemandRose,
            .guestIdle, .hostUnderPressure, .protectingGuest,
        ]
        // Not every reason is multi-word ("raised" is one), but the format
        // is only interesting because some are - so assert that up front
        // rather than letting this quietly become a test of single tokens.
        XCTAssertTrue(reasons.contains { BalloonGovernor.describe($0).contains(" ") },
                      "no reason contains a space, so this test proves nothing")

        for reason in reasons {
            var state = BalloonGovernor.State()
            state.availability = .active
            state.adjustments = 1
            state.lastReason = reason
            let decoded = BalloonGovernor.State.fromWireLine(state.wireLine)
            XCTAssertEqual(decoded.reasonText, BalloonGovernor.describe(reason),
                           "reason text was mangled by the round trip")
            // The fields before it must still decode.
            XCTAssertEqual(decoded.state.adjustments, 1)
            XCTAssertEqual(decoded.state.availability, .active)
        }
    }

    /// A guest that has not answered yet has no figures at all, which has to
    /// stay distinguishable from having zero of everything.
    func testAbsentFieldsStayAbsent() {
        var state = BalloonGovernor.State()
        state.availability = .guestAgentMissing
        let line = state.wireLine
        XCTAssertFalse(line.contains("total="))
        XCTAssertFalse(line.contains("inuse="))
        XCTAssertFalse(line.contains("stall="))
        XCTAssertFalse(line.contains("swap="))

        let decoded = BalloonGovernor.State.fromWireLine(line)
        XCTAssertEqual(decoded.state.availability, .guestAgentMissing)
        XCTAssertNil(decoded.state.target)
        XCTAssertNil(decoded.state.guestTotalBytes)
        XCTAssertNil(decoded.state.stallPercent)
        XCTAssertNil(decoded.reasonText)
    }

    func testEveryAvailabilityRoundTrips() {
        for availability in [BalloonGovernor.State.Availability.active, .guestAgentMissing, .notStarted] {
            XCTAssertEqual(BalloonGovernor.State.Availability(wireName: availability.wireName),
                           availability)
        }
    }

    /// An older app reading a newer daemon must degrade, not break.
    func testUnknownKeysAreIgnored() {
        let decoded = BalloonGovernor.State.fromWireLine(
            "availability=active adjustments=3 somethingNew=42 target=1048576")
        XCTAssertEqual(decoded.state.availability, .active)
        XCTAssertEqual(decoded.state.adjustments, 3)
        XCTAssertEqual(decoded.state.target, 1_048_576)
    }

    func testGarbageDecodesToASafeDefault() {
        let decoded = BalloonGovernor.State.fromWireLine("complete nonsense ===== ")
        XCTAssertEqual(decoded.state.availability, .notStarted)
        XCTAssertNil(decoded.state.target)
    }
}
