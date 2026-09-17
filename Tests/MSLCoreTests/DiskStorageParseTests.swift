import XCTest
@testable import MSLCore

/// `Double -> UInt64` traps rather than returning nil, so every rejection
/// has to happen before the conversion.
final class DiskStorageParseTests: XCTestCase {

    func testParsesNormalSizes() {
        XCTAssertEqual(DiskStorage.parseSize("32G"), 32 << 30)
        XCTAssertEqual(DiskStorage.parseSize("32GB"), 32 << 30)
        XCTAssertEqual(DiskStorage.parseSize("32g"), 32 << 30)
        XCTAssertEqual(DiskStorage.parseSize("512M"), 512 << 20)
        XCTAssertEqual(DiskStorage.parseSize("1T"), 1 << 40)
        XCTAssertEqual(DiskStorage.parseSize("1.5G"), UInt64(1.5 * Double(1 << 30)))
        XCTAssertEqual(DiskStorage.parseSize("  64G  "), 64 << 30)
        XCTAssertEqual(DiskStorage.parseSize("4294967296"), 4_294_967_296)
    }

    /// These crashed the CLI outright before - a fatal error, not an error
    /// message, because the range check ran after the conversion.
    func testRejectsValuesThatUsedToCrash() {
        XCTAssertNil(DiskStorage.parseSize("-5G"))
        XCTAssertNil(DiskStorage.parseSize("-1"))
        XCTAssertNil(DiskStorage.parseSize("nanG"))
        XCTAssertNil(DiskStorage.parseSize("infG"))
        XCTAssertNil(DiskStorage.parseSize("-infT"))
        // Above 2^64 once scaled.
        XCTAssertNil(DiskStorage.parseSize("99999999999T"))
    }

    func testRejectsGarbage() {
        for text in ["", "   ", "G", "abc", "1.2.3G", "12X", "0x10"] {
            XCTAssertNil(DiskStorage.parseSize(text), "should reject '\(text)'")
        }
    }

    /// A byte count above 2^53 must not be rounded by going through Double.
    func testLargeExactByteCountKeepsPrecision() {
        XCTAssertEqual(DiskStorage.parseSize("9007199254740993"), 9_007_199_254_740_993)
    }

    func testZeroIsParsedButRejectedByPolicyRange() {
        XCTAssertEqual(DiskStorage.parseSize("0"), 0)
        XCTAssertLessThan(UInt64(0), StoragePolicy.minimumSize)
    }
}
