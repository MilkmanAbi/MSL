import XCTest
@testable import MSLCore

/// `LinuxFileMode` is what makes MSL Files show real Linux permissions instead
/// of the WebDAV mount's faked `rwx------`. It's pure integer work over a
/// `st_mode`, so it's checked directly against `ls -l`'s own output.
final class LinuxFileModeTests: XCTestCase {
    // A regular file, 0644.
    func testRegularFilePermissions() {
        let mode: UInt32 = 0o100644
        XCTAssertEqual(LinuxFileMode.lsString(mode), "-rw-r--r--")
        XCTAssertEqual(LinuxFileMode.octalString(mode), "644")
        XCTAssertEqual(LinuxFileMode.kind(mode), .regular)
        XCTAssertTrue(LinuxFileMode.isRegularFile(mode))
        XCTAssertFalse(LinuxFileMode.isExecutable(mode))
    }

    // A 0755 script - the executable case "Make Executable" produces.
    func testExecutableScript() {
        let mode: UInt32 = 0o100755
        XCTAssertEqual(LinuxFileMode.lsString(mode), "-rwxr-xr-x")
        XCTAssertEqual(LinuxFileMode.octalString(mode), "755")
        XCTAssertTrue(LinuxFileMode.isExecutable(mode))
    }

    func testDirectory() {
        let mode: UInt32 = 0o040755
        XCTAssertEqual(LinuxFileMode.lsString(mode), "drwxr-xr-x")
        XCTAssertEqual(LinuxFileMode.kind(mode), .directory)
    }

    // Every S_IFMT type maps to the character `ls -l` prints for it.
    func testFileTypeChars() {
        let cases: [(UInt32, Character, LinuxFileMode.Kind)] = [
            (0o100000, "-", .regular),
            (0o040000, "d", .directory),
            (0o120000, "l", .symlink),
            (0o010000, "p", .fifo),
            (0o140000, "s", .socket),
            (0o060000, "b", .blockDevice),
            (0o020000, "c", .charDevice),
        ]
        for (mode, char, kind) in cases {
            XCTAssertEqual(LinuxFileMode.kind(mode | 0o644), kind)
            XCTAssertEqual(LinuxFileMode.lsString(mode | 0o644).first, char)
        }
    }

    // A symlink is always "rwxrwxrwx" on disk; the type char is the tell.
    func testSymlink() {
        let mode: UInt32 = 0o120777
        XCTAssertEqual(LinuxFileMode.lsString(mode), "lrwxrwxrwx")
        XCTAssertTrue(LinuxFileMode.isSymlink(mode))
        XCTAssertEqual(LinuxFileMode.kind(mode).badgeSymbol, "arrow.up.forward")
    }

    // setuid/setgid/sticky replace the execute slot, upper-case when the
    // execute bit under them is clear - exactly as `ls` renders them.
    func testSpecialBits() {
        XCTAssertEqual(LinuxFileMode.lsString(0o104755), "-rwsr-xr-x")  // setuid, x set
        XCTAssertEqual(LinuxFileMode.lsString(0o104644), "-rwSr--r--")  // setuid, x clear
        XCTAssertEqual(LinuxFileMode.lsString(0o041777), "drwxrwxrwt")  // sticky, /tmp
        XCTAssertEqual(LinuxFileMode.lsString(0o042755), "drwxr-sr-x")  // setgid, x set
    }
}

/// The `FILE_LIST` relay hands the app raw LIST2 bytes re-encoded from entries
/// mslhd parsed. This proves that round trip is lossless for the fields MSL
/// Files reads.
final class FileOpsList2ReencodeTests: XCTestCase {
    func testEntriesSurviveReencode() throws {
        let entries = [
            FileOpsProtocol.Entry(name: "hostname", size: 7, mtime: 1_700_000_000, mode: 0o100644),
            FileOpsProtocol.Entry(name: "a name with spaces", size: 0, mtime: 1, mode: 0o040755),
            FileOpsProtocol.Entry(name: "café", size: 42, mtime: 999, mode: 0o120777),
        ]
        let bytes = FileOpsProtocol.encodeEntriesAsList2(entries)
        let decoded = try FileOpsProtocol.parseList2(bytes)
        XCTAssertEqual(decoded.skipped, 0)
        XCTAssertEqual(decoded.entries, entries)
    }

    func testEmptyListingRoundTrips() throws {
        let bytes = FileOpsProtocol.encodeEntriesAsList2([])
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertEqual(try FileOpsProtocol.parseList2(bytes).entries, [])
    }
}

/// The daemon wire line for the file relay must survive a path with spaces
/// (the whole reason it's base64'd) through encode and parse.
final class FileOpsDaemonWireTests: XCTestCase {
    func testFileListPathWithSpacesRoundTrips() {
        let request = DaemonProtocol.ControlRequest.fileList(
            instance: "Milk", guestPath: "/home/me/My Documents/notes.txt")
        let line = String(decoding: request.encode(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard case .fileList(let instance, let path)? = DaemonProtocol.ControlRequest.parse(line) else {
            return XCTFail("didn't parse back to .fileList")
        }
        XCTAssertEqual(instance, "Milk")
        XCTAssertEqual(path, "/home/me/My Documents/notes.txt")
    }

    func testFileChmodRoundTrips() {
        let request = DaemonProtocol.ControlRequest.fileChmod(
            instance: "Milk", guestPath: "/usr/local/bin/deploy", mode: 0o755)
        let line = String(decoding: request.encode(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard case .fileChmod(let instance, let path, let mode)? = DaemonProtocol.ControlRequest.parse(line) else {
            return XCTFail("didn't parse back to .fileChmod")
        }
        XCTAssertEqual(instance, "Milk")
        XCTAssertEqual(path, "/usr/local/bin/deploy")
        XCTAssertEqual(mode, 0o755)
    }

    // A file relay request must never be one that starts or logs a VM.
    func testFileRequestsAreInertToLifecycle() {
        let list = DaemonProtocol.ControlRequest.fileList(instance: "Milk", guestPath: "/")
        XCTAssertNil(list.startsInstance)
        XCTAssertNil(list.monitorSummary)
    }
}
