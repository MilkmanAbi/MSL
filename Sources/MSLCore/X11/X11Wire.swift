import Foundation

/// Low-level X11 wire-format primitives - byte-order-aware CARD8/16/32
/// read/write and the protocol's 4-byte padding rule (every variable-
/// length field - STRING8 lists, LISTofBYTE, etc. - is padded to a
/// multiple of 4 bytes; `X11Wire.pad(_:)` is that single rule, reused
/// everywhere a length needs rounding). Kept separate from the actual
/// request/reply logic (`X11Server.swift`) so the "get every byte exactly
/// right" concern lives in one small, carefully-reasoned-about place -
/// see the archived `msl-vgpu.md` design's Phase 2.
public enum X11Wire {
    /// Rounds `n` up to the next multiple of 4 - the padding every
    /// variable-length list/string field in the protocol requires.
    public static func pad(_ n: Int) -> Int {
        (n + 3) & ~3
    }
}

/// Builds a byte-order-aware reply/event/setup-response buffer. X11
/// requires the SERVER to reply in whatever byte order the CLIENT declared
/// in its connection request (the leading 'B'/0x42 or 'l'/0x6C byte) - not
/// a fixed order - so every multi-byte write here respects `littleEndian`
/// rather than assuming one.
public final class X11ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public let littleEndian: Bool

    public init(littleEndian: Bool) {
        self.littleEndian = littleEndian
    }

    public func writeU8(_ v: UInt8) {
        bytes.append(v)
    }

    public func writeU16(_ v: UInt16) {
        if littleEndian {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        } else {
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
    }

    public func writeI16(_ v: Int16) {
        writeU16(UInt16(bitPattern: v))
    }

    public func writeU32(_ v: UInt32) {
        if littleEndian {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 24) & 0xFF))
        } else {
            bytes.append(UInt8((v >> 24) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
    }

    public func writeI32(_ v: Int32) {
        writeU32(UInt32(bitPattern: v))
    }

    /// Writes raw bytes with no interpretation - for an already-encoded
    /// STRING8 or a nested pre-built structure.
    public func writeBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    /// `count` zero bytes - the standard way to fill both "unused" fixed
    /// padding fields and the trailing pad after a variable-length field.
    public func writePadding(_ count: Int) {
        guard count > 0 else { return }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    /// Writes `s` as STRING8 (raw UTF8 bytes, not length-prefixed - the
    /// caller already wrote the length as its own CARD8/16 field per the
    /// surrounding structure's definition) followed by padding to a
    /// 4-byte boundary.
    public func writeString8Padded(_ s: String) {
        let raw = Array(s.utf8)
        writeBytes(raw)
        writePadding(X11Wire.pad(raw.count) - raw.count)
    }
}

/// Reads a client-sent request/connection-setup buffer, honoring whatever
/// byte order that specific client declared.
public final class X11ByteReader {
    private let bytes: [UInt8]
    private var offset: Int
    public let littleEndian: Bool

    public init(_ bytes: [UInt8], littleEndian: Bool, offset: Int = 0) {
        self.bytes = bytes
        self.littleEndian = littleEndian
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public func readU8() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    public func readU16() -> UInt16 {
        guard offset + 2 <= bytes.count else { offset = bytes.count; return 0 }
        let a = bytes[offset], b = bytes[offset + 1]
        offset += 2
        return littleEndian ? (UInt16(b) << 8 | UInt16(a)) : (UInt16(a) << 8 | UInt16(b))
    }

    public func readI16() -> Int16 {
        Int16(bitPattern: readU16())
    }

    public func readU32() -> UInt32 {
        guard offset + 4 <= bytes.count else { offset = bytes.count; return 0 }
        let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2], d = bytes[offset + 3]
        offset += 4
        if littleEndian {
            return UInt32(d) << 24 | UInt32(c) << 16 | UInt32(b) << 8 | UInt32(a)
        } else {
            return UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
        }
    }

    public func readI32() -> Int32 {
        Int32(bitPattern: readU32())
    }

    public func skip(_ count: Int) {
        offset = min(bytes.count, offset + count)
    }

    public func readBytes(_ count: Int) -> [UInt8] {
        guard count > 0, offset < bytes.count else { return [] }
        let end = min(bytes.count, offset + count)
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    public func readString8(_ length: Int) -> String {
        String(decoding: readBytes(length), as: UTF8.self)
    }

    /// Core-protocol TEXT bytes (`ImageText8`/`PolyText8`): each byte is a
    /// glyph index into an 8-bit font, which for the usual iso8859-1 fonts
    /// is Latin-1 - not UTF-8. Decoding them as UTF-8 turned xcalc's
    /// `x\262` (x²) into a replacement-character box.
    public func readLatin1String8(_ length: Int) -> String {
        String(readBytes(length).map { Character(Unicode.Scalar($0)) })
    }
}
