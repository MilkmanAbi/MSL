import XCTest
@testable import MSLCore

final class TextFileKindTests: XCTestCase {
    func testConfigFilesAreOffered() {
        for name in ["sshd_config", "fstab", ".bashrc", ".gitconfig", "10-msl.conf",
                     "shellinit.service", "app.desktop", "notes.md", "Makefile", "hosts"] {
            XCTAssertTrue(TextFileKind.looksEditable(name: name), name)
        }
    }

    func testBinariesAndMediaAreNot() {
        for name in ["rootfs.img", "photo.png", "archive.tar.xz", "libc.so.6", "video.mp4", "font.ttf"] {
            XCTAssertFalse(TextFileKind.looksEditable(name: name), name)
        }
    }

    /// Plenty of config files have no extension, so the bytes get the last
    /// word: a NUL means binary, whatever the name says.
    func testBytesDecide() {
        XCTAssertTrue(TextFileKind.isEditable(Data("PermitRootLogin no\n".utf8)))
        XCTAssertFalse(TextFileKind.isEditable(Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01])))
        XCTAssertFalse(TextFileKind.isEditable(Data([0xff, 0xfe, 0xfd])))
    }

    func testTooBigToEdit() {
        let big = Data(repeating: 0x41, count: TextFileKind.editableByteLimit + 1)
        XCTAssertFalse(TextFileKind.isEditable(big))
        XCTAssertTrue(TextFileKind.refusal(for: big)?.contains("too big") == true)
        XCTAssertNil(TextFileKind.refusal(for: Data("fine\n".utf8)))
    }

    func testRefusalsExplainThemselves() {
        XCTAssertTrue(TextFileKind.refusal(for: Data([0x00, 0x01]))?.contains("binary") == true)
        XCTAssertTrue(TextFileKind.refusal(for: Data([0xff, 0xfe]))?.contains("UTF-8") == true)
    }
}
