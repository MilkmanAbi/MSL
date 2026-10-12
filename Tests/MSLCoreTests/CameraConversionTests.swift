import XCTest
@testable import MSLCore

/// The camera's one piece of real arithmetic: macOS's NV12 frames into the
/// YUYV that every V4L2 application understands.
///
/// Tested against a hand-built buffer because a U/V mix-up is not a crash -
/// it is a perfectly good picture of someone with the wrong skin tone, which
/// is exactly the kind of bug that ships.
final class CameraConversionTests: XCTestCase {
    func testTwoByTwoBlockConvertsInOrder() {
        // 2x2 luma, one chroma pair for the block.
        let luma: [UInt8] = [10, 20,
                             30, 40]
        let chroma: [UInt8] = [100, 200]   // U, V
        let out = CameraSourceConversion.yuyv(fromNV12: luma, chroma: chroma,
                                              width: 2, height: 2,
                                              lumaStride: 2, chromaStride: 2)
        // Row 0: Y0 U Y1 V, row 1 shares the same chroma.
        XCTAssertEqual(Array(out[0..<4]), [10, 100, 20, 200])
        XCTAssertEqual(Array(out[4..<8]), [30, 100, 40, 200])
    }

    /// Camera buffers are padded: the stride is wider than the picture, and
    /// reading by width would shear the image.
    func testStridePaddingIsSkipped() {
        let luma: [UInt8] = [1, 2, 99, 99,
                             3, 4, 99, 99]
        let chroma: [UInt8] = [128, 129, 99, 99]
        let out = CameraSourceConversion.yuyv(fromNV12: luma, chroma: chroma,
                                              width: 2, height: 2,
                                              lumaStride: 4, chromaStride: 4)
        XCTAssertEqual(Array(out[0..<4]), [1, 128, 2, 129])
        XCTAssertEqual(Array(out[4..<8]), [3, 128, 4, 129])
    }

    func testOutputIsExactlyTwoBytesPerPixel() {
        let width = 8, height = 4
        let out = CameraSourceConversion.yuyv(
            fromNV12: [UInt8](repeating: 128, count: width * height),
            chroma: [UInt8](repeating: 128, count: width * height / 2),
            width: width, height: height, lumaStride: width, chromaStride: width)
        XCTAssertEqual(out.count, width * height * 2)
    }

    /// A short chroma plane must not read past the end: a truncated frame is
    /// a grey picture, not a crash.
    func testMissingChromaFallsBackToGrey() {
        let out = CameraSourceConversion.yuyv(fromNV12: [5, 6], chroma: [],
                                              width: 2, height: 1,
                                              lumaStride: 2, chromaStride: 2)
        XCTAssertEqual(out, [5, 128, 6, 128])
    }
}
