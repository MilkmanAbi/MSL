import XCTest
@testable import MSLCore

final class X11PropertyReadTests: XCTestCase {
    /// The sizing read: every toolkit's first `XGetWindowProperty` on a
    /// property of unknown length. It must come back "nothing yet, and N
    /// bytes follow" - answering "nothing, and nothing follows" is what
    /// made pasting into Linux apps silently do nothing.
    func testSizingReadReportsTheWholeSize() {
        let read = X11PropertyRead(total: 21, longOffset: 0, longLength: 0, delete: false)
        XCTAssertTrue(read.range.isEmpty)
        XCTAssertEqual(read.bytesAfter, 21)
    }

    func testSecondReadReturnsEverything() {
        let read = X11PropertyRead(total: 21, longOffset: 0, longLength: 6, delete: false)
        XCTAssertEqual(read.range, 0..<21)
        XCTAssertEqual(read.bytesAfter, 0)
    }

    /// Reading in chunks, which is how a large property (an icon, a long
    /// clipboard) actually arrives.
    func testChunkedReadsWalkTheValue() {
        let first = X11PropertyRead(total: 100, longOffset: 0, longLength: 10, delete: false)
        XCTAssertEqual(first.range, 0..<40)
        XCTAssertEqual(first.bytesAfter, 60)
        let second = X11PropertyRead(total: 100, longOffset: 10, longLength: 10, delete: false)
        XCTAssertEqual(second.range, 40..<80)
        XCTAssertEqual(second.bytesAfter, 20)
        let last = X11PropertyRead(total: 100, longOffset: 20, longLength: 10, delete: false)
        XCTAssertEqual(last.range, 80..<100)
        XCTAssertEqual(last.bytesAfter, 0)
    }

    /// Delete-on-read only fires at the end. Deleting on the sizing read
    /// would destroy the value before anyone read it.
    func testDeleteWaitsForTheEnd() {
        XCTAssertFalse(X11PropertyRead(total: 21, longOffset: 0, longLength: 0, delete: true).deletes)
        XCTAssertTrue(X11PropertyRead(total: 21, longOffset: 0, longLength: 6, delete: true).deletes)
        XCTAssertFalse(X11PropertyRead(total: 21, longOffset: 0, longLength: 6, delete: false).deletes)
    }

    /// An offset past the end is a client error in the protocol; answering
    /// with an empty range is kinder than a crash and never wrong.
    func testOffsetPastTheEndIsEmpty() {
        let read = X11PropertyRead(total: 8, longOffset: 99, longLength: 4, delete: false)
        XCTAssertTrue(read.range.isEmpty)
        XCTAssertEqual(read.bytesAfter, 0)
    }

    func testEmptyProperty() {
        let read = X11PropertyRead(total: 0, longOffset: 0, longLength: 0, delete: true)
        XCTAssertTrue(read.range.isEmpty)
        XCTAssertEqual(read.bytesAfter, 0)
        XCTAssertTrue(read.deletes, "an empty property has been fully read already")
    }
}
