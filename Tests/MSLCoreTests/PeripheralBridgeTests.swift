import XCTest
@testable import MSLCore

/// mslps: the wire between a Linux application's sound and the Mac's
/// speakers.
final class PeripheralBridgeTests: XCTestCase {
    private func hello(_ text: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array(text.utf8).prefix(16).enumerated() { bytes[index] = byte }
        return bytes
    }

    /// "MSLPS1 audio-out" is exactly 16 characters, which is how the first
    /// version broke: the guest built it with `snprintf` into a 16 byte
    /// buffer, which keeps a byte for its terminator and sent
    /// "MSLPS1 audio-ou". The field is fixed width and carries no
    /// terminator, so a full 16 characters has to parse.
    func testFullWidthHelloParses() {
        XCTAssertEqual(PeripheralBridge.stream(fromHello: hello("MSLPS1 audio-out")), .audioOut)
        XCTAssertEqual(PeripheralBridge.stream(fromHello: hello("MSLPS1 audio-in")), .audioIn)
        XCTAssertEqual(PeripheralBridge.stream(fromHello: hello("MSLPS1 camera")), .camera)
    }

    /// A truncated hello - the actual bug - must be refused rather than
    /// guessed at.
    func testTruncatedHelloIsRefused() {
        XCTAssertNil(PeripheralBridge.stream(fromHello: hello("MSLPS1 audio-ou")))
        XCTAssertNil(PeripheralBridge.stream(fromHello: hello("hello")))
        XCTAssertNil(PeripheralBridge.stream(fromHello: []))
        XCTAssertNil(PeripheralBridge.stream(fromHello: [UInt8](repeating: 0, count: 16)))
    }

    /// Signed 16-bit little endian to float, the one conversion in the path.
    func testSampleConversion() {
        // 0, +full scale, -full scale, and a mid value.
        let bytes: [UInt8] = [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x40]
        let samples = GuestAudioOutput.floats(fromS16LE: bytes)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 1, accuracy: 0.001)
        XCTAssertEqual(samples[2], -1, accuracy: 0.001)
        XCTAssertEqual(samples[3], 0.5, accuracy: 0.001)
    }

    func testOddByteCountIsNotACrash() {
        XCTAssertEqual(GuestAudioOutput.floats(fromS16LE: [0x01]).count, 0)
        XCTAssertEqual(GuestAudioOutput.floats(fromS16LE: []).count, 0)
    }

    /// The peak is what makes a silent stream distinguishable from a working
    /// one in the log - a stream of zeroes connects and reads exactly like
    /// music.
    func testPeakSeparatesSilenceFromSound() {
        XCTAssertEqual(GuestAudioOutput.peak(ofS16LE: [UInt8](repeating: 0, count: 64)), 0)
        XCTAssertEqual(GuestAudioOutput.peak(ofS16LE: [0x00, 0x40]), 0.5, accuracy: 0.001)
    }

    /// The buffer is a fixed window onto a live stream: when the Mac cannot
    /// keep up, the oldest audio goes, rather than latency growing without
    /// limit.
    func testBufferDropsOldestRatherThanGrowing() {
        let output = GuestAudioOutput()
        let oneSecond = [UInt8](repeating: 0x10, count: Int(PeripheralBridge.sampleRate) * 2 * 2)
        output.enqueue(bytes: oneSecond)
        XCTAssertLessThanOrEqual(output.bufferedSamplesForTesting,
                                 Int(PeripheralBridge.sampleRate * 0.06) * 2,
                                 "a second of audio must not sit in a 60 ms buffer")
    }

    /// 10 ms frames at the fixed format, which both sides hardcode.
    func testFrameSizeMatchesTenMilliseconds() {
        let bytesPerSecond = Int(PeripheralBridge.sampleRate) * Int(PeripheralBridge.channels) * 2
        XCTAssertEqual(PeripheralBridge.frameBytes, bytesPerSecond / 100)
    }
}
