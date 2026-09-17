import XCTest
@testable import MSLCore

final class X11ExtensionBaseTests: XCTestCase {
    /// Core events end at GenericEvent (35); core errors at BadImplementation (17).
    private let lastCoreEvent = 35
    private let lastCoreError = 17

    func testEventBlocksClearCoreCodesAndEachOther() {
        let blocks: [(name: String, base: Int, count: Int)] = [
            ("SHAPE", Int(X11ExtensionBase.shapeFirstEvent), X11ExtensionBase.shapeEventCount),
            ("XInputExtension", Int(X11ExtensionBase.xinputFirstEvent), X11ExtensionBase.xinputEventCount),
            ("XKEYBOARD", Int(XKBEventCode.eventBase), X11ExtensionBase.xkbEventCount),
        ]
        var used = Set<Int>()
        for block in blocks {
            XCTAssertGreaterThan(block.base, lastCoreEvent, "\(block.name) overlaps core events")
            XCTAssertLessThanOrEqual(block.base + block.count, 128, "\(block.name) runs into the send_event bit")
            for code in block.base..<(block.base + block.count) {
                XCTAssertTrue(used.insert(code).inserted, "\(block.name) overlaps another extension at \(code)")
            }
        }
    }

    func testXInputErrorBlockClearsCoreErrors() {
        XCTAssertGreaterThan(Int(X11ExtensionBase.xinputFirstError), lastCoreError)
        XCTAssertLessThanOrEqual(Int(X11ExtensionBase.xinputFirstError) + X11ExtensionBase.xinputErrorCount, 256)
    }
}
