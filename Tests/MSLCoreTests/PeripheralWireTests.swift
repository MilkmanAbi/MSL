import XCTest
@testable import MSLCore

/// The formats mslpsd (C, in the guest), mslhd and MSL Peripherals share.
/// The C side is not linked into these tests, so its byte layout is written
/// out literally here - a change on either side has to change this too.
final class PeripheralWireTests: XCTestCase {
    func testControlMessagesMatchTheGuestsLayout() {
        XCTAssertEqual(PeripheralWire.encode(.inUse(application: "cheese")),
                       [1, 6] + Array("cheese".utf8))
        XCTAssertEqual(PeripheralWire.encode(.released), [2, 0])
    }

    /// Socket reads split messages anywhere; nothing may be lost or invented.
    func testControlMessagesSurviveArbitrarySplits() {
        let wire = PeripheralWire.encode(.inUse(application: "v4l2_camera_node"))
                 + PeripheralWire.encode(.released)
                 + PeripheralWire.encode(.inUse(application: "discord"))
        for split in 0...wire.count {
            var parser = PeripheralWire.ControlParser()
            let got = parser.feed(Array(wire[..<split])) + parser.feed(Array(wire[split...]))
            XCTAssertEqual(got, [.inUse(application: "v4l2_camera_node"), .released, .inUse(application: "discord")],
                           "split at \(split)")
        }
    }

    /// A newer guest may send a message type this build doesn't know.
    func testUnknownControlTypesAreSkippedNotFatal() {
        var parser = PeripheralWire.ControlParser()
        let got = parser.feed([9, 3, 0xAA, 0xBB, 0xCC] + PeripheralWire.encode(.released))
        XCTAssertEqual(got, [.released])
    }

    func testFrameHeaderRoundTripsAndMatchesTheGuest() {
        let header = PeripheralWire.frameHeader(payloadBytes: PeripheralWire.cameraFrameBytes)
        // 1280*720*2 = 1843200 = 0x001C2000, little endian.
        XCTAssertEqual(header, [0x4D, 0x46, 1, 0, 0x00, 0x20, 0x1C, 0x00])
        XCTAssertEqual(PeripheralWire.payloadLength(ofFrameHeader: header), 1_843_200)
    }

    func testAMisalignedHeaderIsRefused() {
        XCTAssertNil(PeripheralWire.payloadLength(ofFrameHeader: [0, 0x20, 0x1C, 0, 0x4D, 0x46, 1, 0]))
        XCTAssertNil(PeripheralWire.payloadLength(ofFrameHeader: [0x4D, 0x46, 2, 0, 0, 0, 0, 0]),
                     "a different version is not this format")
    }

    func testHelperHelloRoundTrips() {
        let line = String(decoding: PeripheralWire.helperHello(stream: "camera", instance: "Milk"), as: UTF8.self)
        XCTAssertEqual(line, "camera Milk\n")
        let parsed = PeripheralWire.parseHelperHello(line)
        XCTAssertEqual(parsed?.stream, "camera")
        XCTAssertEqual(parsed?.instance, "Milk")
        XCTAssertNil(PeripheralWire.parseHelperHello("camera\n"))
    }

    /// Camera buffers are padded; reading by width would shear the picture.
    func testPackingDropsRowPadding() {
        let width = 2, height = 2, stride = 8
        var padded = [UInt8](repeating: 0xEE, count: stride * height)
        padded.replaceSubrange(0..<4, with: [1, 2, 3, 4])
        padded.replaceSubrange(8..<12, with: [5, 6, 7, 8])
        let packed = padded.withUnsafeBytes {
            PeripheralWire.packedYUYV(from: $0.baseAddress!, width: width, height: height, bytesPerRow: stride)
        }
        XCTAssertEqual(packed, [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
