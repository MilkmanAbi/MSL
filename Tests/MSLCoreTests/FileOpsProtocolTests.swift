import XCTest
@testable import MSLCore

/// The macOS↔Linux file bridge's wire parsing.
///
/// Worth testing precisely because the failure mode was invisible: a single
/// awkwardly-named file used to make `parseListResponse` throw for the whole
/// payload, `WebDAVServer` swallowed that, and Finder drew a folder full of
/// files as empty. Nothing logged, nothing errored.
final class FileOpsProtocolTests: XCTestCase {

    /// Builds a LIST payload the way `fileopsd`'s `snprintf` does, but from
    /// raw bytes so a name can be invalid UTF-8.
    private func listPayload(_ entries: [(name: [UInt8], size: UInt64, mtime: UInt64, mode: UInt32)]) -> [UInt8] {
        var out: [UInt8] = []
        for e in entries {
            out += e.name
            out += Array("\t\(e.size)\t\(e.mtime)\t\(e.mode)\n".utf8)
        }
        return out
    }

    private func file(_ name: String, size: UInt64 = 10) -> (name: [UInt8], size: UInt64, mtime: UInt64, mode: UInt32) {
        (Array(name.utf8), size, 1_700_000_000, 0o100644)
    }

    // MARK: - The bug that hid whole directories

    func testOneUndecodableNameCostsOnlyThatEntry() {
        // 0xFF is not valid UTF-8 in any position. A real case: a file
        // copied off a latin-1 filesystem.
        let broken: (name: [UInt8], size: UInt64, mtime: UInt64, mode: UInt32) =
            ([0x62, 0xFF, 0x61, 0x64], 1, 1, 0o100644)
        let payload = listPayload([file("alpha.txt"), broken, file("omega.txt")])

        let result = FileOpsProtocol.parseList(payload)
        XCTAssertEqual(result.entries.map(\.name), ["alpha.txt", "omega.txt"],
                       "a name that won't decode must not take the rest of the directory with it")
        XCTAssertEqual(result.skipped, 1, "the gap should be reported, not silent")
    }

    func testUndecodableNameNoLongerThrows() {
        let payload = listPayload([file("keep.txt"), ([0xC3, 0x28], 1, 1, 0o100644)])
        XCTAssertNoThrow(try FileOpsProtocol.parseListResponse(payload),
                         "this used to throw and Finder rendered the folder as empty")
    }

    // MARK: - Ordinary parsing still works

    func testParsesAPlainListing() throws {
        let payload = listPayload([
            (Array("notes.txt".utf8), 4096, 1_700_000_000, 0o100644),
            (Array("projects".utf8), 0, 1_700_000_001, 0o040755),
        ])
        let entries = try FileOpsProtocol.parseListResponse(payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "notes.txt")
        XCTAssertEqual(entries[0].size, 4096)
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isDirectory, "0o040755 is a directory")
    }

    func testNonAsciiNamesSurvive() throws {
        let entries = try FileOpsProtocol.parseListResponse(
            listPayload([file("café.txt"), file("日本語"), file("emoji 🍈.md")]))
        XCTAssertEqual(entries.map(\.name), ["café.txt", "日本語", "emoji 🍈.md"])
    }

    func testEmptyListingIsEmptyNotAnError() throws {
        XCTAssertEqual(try FileOpsProtocol.parseListResponse([]).count, 0)
    }

    // MARK: - Malformed lines

    func testShortAndLongLinesAreSkippedIndividually() {
        var payload = listPayload([file("good-one.txt")])
        payload += Array("missing-fields\t123\n".utf8)          // 2 fields
        payload += Array("too\tmany\t1\t2\t3\t4\n".utf8)         // 6 fields
        payload += Array("bad-size\tNOTANUMBER\t1\t420\n".utf8)  // unparseable
        payload += listPayload([file("good-two.txt")])

        let result = FileOpsProtocol.parseList(payload)
        XCTAssertEqual(result.entries.map(\.name), ["good-one.txt", "good-two.txt"])
        XCTAssertEqual(result.skipped, 3)
    }

    /// A name with a tab splits into too many fields and is dropped. After
    /// the next image rebuild `fileopsd` filters these guest-side, but the
    /// host must not be the thing that falls over.
    func testTabInNameIsSkippedRatherThanCorruptingTheRest() {
        var payload = listPayload([file("before.txt")])
        payload += Array("has\ttab\t10\t1\t420\n".utf8)
        payload += listPayload([file("after.txt")])

        let result = FileOpsProtocol.parseList(payload)
        XCTAssertEqual(result.entries.map(\.name), ["before.txt", "after.txt"],
                       "entries after the bad one must still parse")
        XCTAssertEqual(result.skipped, 1)
    }

    // MARK: - Encoders refuse rather than trap

    func testOverlongPathThrowsInsteadOfCrashing() {
        // The wire format gives a path 16 bits of length. `UInt16(count)`
        // would trap; a thrown error is recoverable.
        let tooLong = String(repeating: "a", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(try FileOpsProtocol.encodeList(path: tooLong)) { error in
            guard case FileOpsProtocol.FileOpsError.pathTooLong = error else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }

    func testPathAtTheLimitStillEncodes() {
        let atLimit = String(repeating: "a", count: Int(UInt16.max))
        XCTAssertNoThrow(try FileOpsProtocol.encodeList(path: atLimit))
    }

    func testEncodersRoundTripThroughTheHeader() throws {
        let frame = try FileOpsProtocol.encodeRead(path: "/etc/hostname", offset: 512, length: 4096)
        XCTAssertEqual(frame[0], 0x03, "opcode")
        let pathLen = Int(frame[1]) | (Int(frame[2]) << 8)
        XCTAssertEqual(pathLen, Array("/etc/hostname".utf8).count)
        XCTAssertEqual(Array(frame[3..<(3 + pathLen)]), Array("/etc/hostname".utf8))
    }

    // MARK: - Stat

    func testStatRejectsAShortPayload() {
        XCTAssertThrowsError(try FileOpsProtocol.parseStatResponse([UInt8](repeating: 0, count: 19)))
    }

    func testStatParsesLittleEndianFields() throws {
        var payload = [UInt8](repeating: 0, count: 20)
        payload[0] = 0x00; payload[1] = 0x04            // size = 1024
        payload[8] = 0x01                                // mtime = 1
        payload[16] = 0xED; payload[17] = 0x41           // mode = 0o040755
        let entry = try FileOpsProtocol.parseStatResponse(payload)
        XCTAssertEqual(entry.size, 1024)
        XCTAssertEqual(entry.mtime, 1)
        XCTAssertTrue(entry.isDirectory)
    }

    // MARK: - LIST2

    /// Builds a LIST2 payload the way `fileopsd`'s `emit_binary` does.
    private func list2Payload(_ entries: [(name: [UInt8], size: UInt64, mtime: UInt64, mode: UInt32)]) -> [UInt8] {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var out: [UInt8] = []
        for e in entries {
            out += le(UInt16(e.name.count)) + e.name + le(e.size) + le(e.mtime) + le(e.mode)
        }
        return out
    }

    func testList2KeepsNamesThatBreakLIST() throws {
        let payload = list2Payload([
            file("before.txt"),
            (Array("has\ttab".utf8), 10, 1, 0o100644),
            (Array("has\nnewline".utf8), 20, 2, 0o100600),
            (Array("projects".utf8), 0, 3, 0o040755),
        ])
        let result = try FileOpsProtocol.parseList2(payload)
        XCTAssertEqual(result.entries.map(\.name), ["before.txt", "has\ttab", "has\nnewline", "projects"],
                       "the names LIST has to skip are ordinary entries in LIST2")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.entries[2].size, 20)
        XCTAssertEqual(result.entries[2].mode, 0o100600)
        XCTAssertTrue(result.entries[3].isDirectory)
    }

    func testList2UndecodableNameCostsOnlyThatEntry() throws {
        let payload = list2Payload([file("alpha"), ([0x62, 0xFF], 1, 1, 0o100644), file("omega")])
        let result = try FileOpsProtocol.parseList2(payload)
        XCTAssertEqual(result.entries.map(\.name), ["alpha", "omega"])
        XCTAssertEqual(result.skipped, 1)
    }

    func testList2EmptyListingIsEmpty() throws {
        XCTAssertEqual(try FileOpsProtocol.parseList2([]).entries.count, 0)
    }

    func testList2TruncatedFrameThrows() {
        let payload = list2Payload([file("whole.txt"), file("cut-short.txt")])
        XCTAssertThrowsError(try FileOpsProtocol.parseList2(Array(payload.dropLast(5))),
                             "a length that runs past the end means the frame is damaged")
        XCTAssertThrowsError(try FileOpsProtocol.parseList2([0x05]), "half a length prefix")
    }

    func testNewOpcodesEncode() throws {
        let chmod = try FileOpsProtocol.encodeChmod(path: "/tmp/x", mode: 0o755)
        XCTAssertEqual(chmod[0], 0x08)
        XCTAssertEqual(Array(chmod.suffix(4)), [0xED, 0x01, 0x00, 0x00], "mode, little-endian, after the path")
        XCTAssertEqual(try FileOpsProtocol.encodeList2(path: "/tmp")[0], 0x09)
    }

    func testOnlyEINVALMeansUnsupported() {
        XCTAssertTrue(FileOpsProtocol.FileOpsError.remote(errno: EINVAL).isUnsupportedOperation,
                      "fileopsd answers an unknown opcode with EINVAL")
        XCTAssertFalse(FileOpsProtocol.FileOpsError.remote(errno: ENOENT).isUnsupportedOperation)
        XCTAssertFalse(FileOpsProtocol.FileOpsError.connectionClosed.isUnsupportedOperation)
    }
}
