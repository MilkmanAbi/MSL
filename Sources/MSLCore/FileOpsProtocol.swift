import Foundation

/// Wire encode/decode for `fileopsd`'s vsock protocol - see
/// `Guest/init/fileopsd.c`'s doc comment for the authoritative wire
/// format. Pure data marshaling only, no networking - `FileOpsClient`
/// pairs this with an actual connection.
public enum FileOpsProtocol {
    public struct Entry: Equatable {
        public let name: String
        public let size: UInt64
        public let mtime: UInt64
        public let mode: UInt32

        private static let modeFormatMask: UInt32 = 0o170000
        private static let dirModeBits: UInt32 = 0o040000
        public var isDirectory: Bool { (mode & Self.modeFormatMask) == Self.dirModeBits }

        public init(name: String, size: UInt64, mtime: UInt64, mode: UInt32) {
            self.name = name
            self.size = size
            self.mtime = mtime
            self.mode = mode
        }
    }

    public enum FileOpsError: Error, CustomStringConvertible {
        case connectionClosed
        case malformedResponse
        case remote(errno: Int32)
        case pathTooLong(Int)
        case payloadTooLarge(Int)
        case frameTooLarge(UInt32)

        public var description: String {
            switch self {
            case .connectionClosed: return "fileopsd connection closed unexpectedly"
            case .malformedResponse: return "fileopsd sent a malformed response frame"
            case .remote(let code): return "fileopsd error: \(String(cString: strerror(code))) (errno \(code))"
            case .pathTooLong(let n): return "path is \(n) bytes; the wire format allows 65535"
            case .payloadTooLarge(let n): return "write payload is \(n) bytes; the wire format allows 4 GiB"
            case .frameTooLarge(let n): return "fileopsd announced a \(n)-byte frame, past the sanity limit"
            }
        }
    }

    private static func appendU16LE(_ v: UInt16, _ buf: inout [UInt8]) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendU32LE(_ v: UInt32, _ buf: inout [UInt8]) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
    }
    private static func appendU64LE(_ v: UInt64, _ buf: inout [UInt8]) {
        appendU32LE(UInt32(v & 0xFFFF_FFFF), &buf)
        appendU32LE(UInt32(v >> 32), &buf)
    }
    /// The wire format gives a path a 16-bit length, so a path longer than
    /// 65535 bytes cannot be represented. `UInt16(bytes.count)` would *trap*
    /// on one - a crash rather than an error - so it is checked. Linux caps
    /// a path at 4096, so this is unreachable in practice and is here
    /// precisely because unreachable code is where crashes hide.
    private static func appendPath(_ path: String, _ buf: inout [UInt8]) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw FileOpsError.pathTooLong(bytes.count) }
        appendU16LE(UInt16(bytes.count), &buf)
        buf.append(contentsOf: bytes)
    }

    public static func encodeList(path: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x01]
        try appendPath(path, &buf)
        return buf
    }
    public static func encodeStat(path: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x02]
        try appendPath(path, &buf)
        return buf
    }
    public static func encodeRead(path: String, offset: UInt64, length: UInt32) throws -> [UInt8] {
        var buf: [UInt8] = [0x03]
        try appendPath(path, &buf)
        appendU64LE(offset, &buf)
        appendU32LE(length, &buf)
        return buf
    }
    public static func encodeWrite(path: String, offset: UInt64, data: Data) throws -> [UInt8] {
        var buf: [UInt8] = [0x04]
        try appendPath(path, &buf)
        appendU64LE(offset, &buf)
        // Same reasoning as `appendPath`: `UInt32(data.count)` traps above
        // 4 GiB. Callers chunk long before this, so it is a guard, not a
        // limit anyone should reach.
        guard data.count <= Int(UInt32.max) else { throw FileOpsError.payloadTooLarge(data.count) }
        appendU32LE(UInt32(data.count), &buf)
        buf.append(contentsOf: data)
        return buf
    }
    public static func encodeMkdir(path: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x05]
        try appendPath(path, &buf)
        return buf
    }
    public static func encodeRename(src: String, dst: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x06]
        try appendPath(src, &buf)
        try appendPath(dst, &buf)
        return buf
    }
    public static func encodeUnlink(path: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x07]
        try appendPath(path, &buf)
        return buf
    }
    /// CHMOD: sets the permission bits (`mode & 0o7777`) of `path`. Images
    /// built from 2026-09-14 understand it; older ones answer EINVAL.
    public static func encodeChmod(path: String, mode: UInt32) throws -> [UInt8] {
        var buf: [UInt8] = [0x08]
        try appendPath(path, &buf)
        appendU32LE(mode, &buf)
        return buf
    }
    /// LIST2: a directory listing as length-prefixed binary entries - see
    /// `parseList2`. Images built from 2026-09-14 understand it; older ones
    /// answer EINVAL, and `FileOpsClient` falls back to LIST.
    public static func encodeList2(path: String) throws -> [UInt8] {
        var buf: [UInt8] = [0x09]
        try appendPath(path, &buf)
        return buf
    }

    private static func readU32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func readU64LE(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(readU32LE(b, i)) | (UInt64(readU32LE(b, i + 4)) << 32)
    }

    /// Parses a LIST response body - zero or more
    /// "name\tsize\tmtime\tmode\n" entries.
    ///
    /// Deliberately byte-oriented and per-entry tolerant, because the old
    /// version decoded the *whole* payload with
    /// `String(bytes:encoding:.utf8)` first and threw if that returned nil.
    /// A Linux filename is an arbitrary byte string (anything but `/` and
    /// NUL), so it need not be valid UTF-8 - and one latin-1 filename made
    /// the entire directory unparseable. `WebDAVServer` then swallowed the
    /// error and returned an empty multistatus, so **Finder showed a folder
    /// full of files as empty, with no error at all.** Now a name that will
    /// not decode costs that one entry.
    ///
    /// `skipped` is reported rather than swallowed so the gap is
    /// diagnosable instead of just puzzling.
    ///
    /// Still a real limitation: a filename containing a tab or a newline
    /// breaks the delimiters and is skipped here (and, after the next image
    /// rebuild, filtered guest-side rather than corrupting the stream).
    /// Fixing it properly needs a length-prefixed listing opcode - see
    /// IMAGE-REBUILD-SG.md.
    public static func parseListResponse(_ payload: [UInt8]) throws -> [Entry] {
        parseList(payload).entries
    }

    public static func parseList(_ payload: [UInt8]) -> (entries: [Entry], skipped: Int) {
        var entries: [Entry] = []
        var skipped = 0

        for line in payload.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let fields = line.split(separator: 0x09, omittingEmptySubsequences: false)
            guard fields.count == 4 else { skipped += 1; continue }
            // The name is the only field that can hold arbitrary bytes; the
            // other three are ASCII digits written by `snprintf`.
            guard let name = String(bytes: fields[0], encoding: .utf8), !name.isEmpty,
                  let size = UInt64(String(decoding: fields[1], as: UTF8.self)),
                  let mtime = UInt64(String(decoding: fields[2], as: UTF8.self)),
                  let mode = UInt32(String(decoding: fields[3], as: UTF8.self))
            else { skipped += 1; continue }
            entries.append(Entry(name: name, size: size, mtime: mtime, mode: mode))
        }
        return (entries, skipped)
    }

    public static func parseStatResponse(_ payload: [UInt8]) throws -> Entry {
        guard payload.count == 20 else { throw FileOpsError.malformedResponse }
        return Entry(
            name: "",
            size: readU64LE(payload, 0),
            mtime: readU64LE(payload, 8),
            mode: readU32LE(payload, 16)
        )
    }

    /// Parses an error response body (present only when the response's
    /// leading status byte was 0x01) into the guest's raw errno.
    public static func parseErrorResponse(_ payload: [UInt8]) throws -> Int32 {
        guard payload.count == 4 else { throw FileOpsError.malformedResponse }
        return Int32(bitPattern: readU32LE(payload, 0))
    }

    /// Parses a LIST2 response body - zero or more binary entries, each
    /// `namelen u16, name, size u64, mtime u64, mode u32`, little-endian.
    ///
    /// The fix for LIST's delimiter problem: a name is its own length, so a
    /// tab or a newline in it is just another byte. A name that isn't valid
    /// UTF-8 still costs only that entry (reported in `skipped`, as with
    /// LIST) - Swift's `String` can't hold it, so it couldn't be opened by
    /// name afterwards anyway.
    ///
    /// Unlike LIST, a structural error throws: lengths that run past the end
    /// mean the frame itself is damaged, and nothing after that point can be
    /// trusted to line up.
    public static func parseList2(_ payload: [UInt8]) throws -> (entries: [Entry], skipped: Int) {
        var entries: [Entry] = []
        var skipped = 0
        var i = 0
        while i < payload.count {
            guard i + 2 <= payload.count else { throw FileOpsError.malformedResponse }
            let nameLength = Int(payload[i]) | (Int(payload[i + 1]) << 8)
            let fields = i + 2 + nameLength
            guard fields + 20 <= payload.count else { throw FileOpsError.malformedResponse }
            if nameLength > 0, let name = String(bytes: payload[(i + 2)..<fields], encoding: .utf8) {
                entries.append(Entry(name: name,
                                     size: readU64LE(payload, fields),
                                     mtime: readU64LE(payload, fields + 8),
                                     mode: readU32LE(payload, fields + 16)))
            } else {
                skipped += 1
            }
            i = fields + 20
        }
        return (entries, skipped)
    }
}

extension FileOpsProtocol.FileOpsError {
    /// The guest's `fileopsd` doesn't know the opcode: an image older than
    /// the operation. Unknown opcodes are answered with EINVAL, which is
    /// what the host probes for before falling back.
    public var isUnsupportedOperation: Bool {
        if case .remote(let code) = self, code == EINVAL { return true }
        return false
    }
}
