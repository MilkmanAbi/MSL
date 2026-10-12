import XCTest
@testable import MSLCore

/// An event's sequence must never land ahead of a reply a client is waiting
/// on. The arithmetic is 16-bit and wraps, which is where a plain `max`
/// goes wrong, so the wrap cases are pinned here.
final class WireStampTests: XCTestCase {
    func testTheProcessedSequenceWinsWhenItIsAhead() {
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 100, processed: 105), 105)
    }

    func testTheWireValueStandsWhenProcessedIsBehind() {
        // Stamping 100 here would put the event behind what the client has
        // already seen, and xcb reads a backward step as a wrap.
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 105, processed: 100), 105)
    }

    func testEqualSequencesAreLeftAlone() {
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 42, processed: 42), 42)
    }

    func testJustAfterAWrapTheNewSmallSequenceIsStillAhead() {
        // This is the case a plain `max` gets wrong: it would answer 65530
        // and stamp events ~65k ahead of every pending reply.
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 65530, processed: 5), 5)
        XCTAssertNotEqual(X11Connection.wireStamp(lastWire: 65530, processed: 5), 65530)
    }

    func testAGenuinelyStaleValueNearAWrapDoesNotWin() {
        // 65530 is behind 5 only if you read it as pre-wrap; a value half
        // the space away is treated as stale, not as a wrap.
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 5, processed: 65530), 5)
    }

    func testTheHalfwayBoundaryIsTreatedAsBehind() {
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 0, processed: 0x8000), 0)
        XCTAssertEqual(X11Connection.wireStamp(lastWire: 0, processed: 0x7FFF), 0x7FFF)
    }
}
