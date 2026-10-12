import XCTest
@testable import MSLCore

/// CL2 — INCR for incoming selections.
///
/// A value too large for one property arrives as type `INCR`, format 32,
/// then in chunks. `decode`'s `guard format == 8` rejected that handshake
/// outright and nothing retried, so **a large copy out of a Linux app
/// silently did nothing**. GTK uses INCR for any sizeable text.
final class X11IncrSelectionTests: XCTestCase {
    /// The handshake is not text and must not be decoded as text - that
    /// rejection is what used to end the transfer.
    func testTheIncrHandshakeIsNotMistakenForAValue() {
        // Format 32 with a size in it, not bytes of text.
        let size: [UInt8] = [0x00, 0x00, 0x10, 0x00]
        XCTAssertNil(X11Clipboard.decode(type: 999, format: 32, data: size, utf8Atom: 1))
    }

    /// Chunks are format 8 and carry the real target type, so the
    /// accumulated buffer decodes exactly as a single-shot value would.
    func testAccumulatedChunksDecodeAsOneValue() {
        let utf8: UInt32 = 42
        let whole = Array("hello, clipboard".utf8)
        let first = Array(whole.prefix(6))
        let rest = Array(whole.dropFirst(6))

        var accumulated: [UInt8] = []
        accumulated += first
        accumulated += rest
        XCTAssertEqual(X11Clipboard.decode(type: utf8, format: 8, data: accumulated, utf8Atom: utf8),
                       "hello, clipboard")
    }

    /// An empty chunk is the end marker, and an empty *value* is not text -
    /// both fall out of the same guard, which is why the end of a transfer
    /// is detected before decoding rather than by decoding.
    func testAnEmptyChunkDecodesToNothing() {
        XCTAssertNil(X11Clipboard.decode(type: 42, format: 8, data: [], utf8Atom: 42))
    }

    /// A transfer cannot grow this process without bound one chunk at a
    /// time. The cap is far past any plausible clipboard text.
    func testTheTransferIsBounded() {
        XCTAssertEqual(X11Clipboard.maxIncrBytes, 32 * 1024 * 1024)
        XCTAssertGreaterThan(X11Clipboard.maxIncrBytes, 1_000_000, "a megabyte of text must still fit")
    }

    /// Latin-1 chunks decode too - the fallback path a client that refuses
    /// UTF8_STRING lands on.
    func testLatin1ChunksDecode() {
        let bytes: [UInt8] = [0xE9, 0x74, 0xE9] // "été" in Latin-1
        XCTAssertEqual(X11Clipboard.decode(type: X11Clipboard.stringAtom, format: 8,
                                           data: bytes, utf8Atom: 42), "été")
    }
}
