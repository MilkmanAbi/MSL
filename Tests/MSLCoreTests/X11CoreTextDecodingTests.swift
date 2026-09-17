import XCTest
@testable import MSLCore

final class X11CoreTextDecodingTests: XCTestCase {
    func testHighBytesAreLatin1NotReplacementCharacters() {
        // xcalc's x² and ÷ labels, straight from its app-defaults.
        let r = X11ByteReader([0x78, 0xB2, 0xF7], littleEndian: true)
        let text = r.readLatin1String8(3)
        XCTAssertEqual(text, "x\u{B2}\u{F7}")
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    func testAsciiIsUnchangedAndLengthIsExact() {
        let r = X11ByteReader(Array("CE/C".utf8) + [0xFF], littleEndian: true)
        XCTAssertEqual(r.readLatin1String8(4), "CE/C")
        XCTAssertEqual(r.remaining, 1)
    }

    func testEveryByteMapsToOneCharacter() {
        let bytes = (0...255).map { UInt8($0) }
        let text = X11ByteReader(bytes, littleEndian: true).readLatin1String8(256)
        XCTAssertEqual(text.unicodeScalars.count, 256)
        XCTAssertEqual(text.unicodeScalars.map { $0.value }, bytes.map { UInt32($0) })
    }
}
