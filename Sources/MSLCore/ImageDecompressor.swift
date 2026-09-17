// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Compression
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Turns a downloaded, compressed disk image back into the image itself -
/// **sparse**, the way it was built.
///
/// Why xz: the images are published xz-compressed (`xz -9e`), because the
/// Compression framework that ships with macOS decodes xz and nothing
/// better-suited (zstd) ships with the OS. No bundled library, no helper
/// binary. Decoding measured at about 7 s per GiB of image on an M-series
/// Mac, most of it spent producing the zeros of a mostly-empty filesystem.
///
/// Why sparse: an image is a 4 GiB ext4 filesystem holding well under 1 GiB
/// of files. Writing every decompressed byte would allocate the full 4 GiB
/// on the Mac for nothing. Instead every all-zero 1 MiB block is skipped
/// with a seek, into a freshly created file where unwritten ranges read as
/// zero - so the result is byte-identical to the original and occupies
/// roughly what the guest has actually written.
public enum ImageDecompressor {
    public enum Format: String, Codable, Sendable {
        case xz
    }

    public enum DecompressError: Error, CustomStringConvertible {
        case cannotOpen(String, Int32)
        case decoderInitFailed
        case corrupt(afterBytes: UInt64)
        case truncated(afterBytes: UInt64)
        case io(String, Int32)

        public var description: String {
            switch self {
            case .cannotOpen(let path, let code):
                return "couldn't open \(path): \(String(cString: strerror(code)))"
            case .decoderInitFailed:
                return "the system's xz decoder couldn't be started"
            case .corrupt(let bytes):
                return "the compressed image is corrupt (failed after \(bytes) bytes of output)"
            case .truncated(let bytes):
                return "the compressed image ends early (after \(bytes) bytes of output)"
            case .io(let what, let code):
                return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// The unit of "is this all zeros". Matches ext4's allocation well enough
    /// to catch free space, and is cheap to compare.
    static let blockSize = 1 << 20

    /// Decompresses `source` into a new file at `destination` (replacing
    /// anything there) and returns the decompressed length.
    @discardableResult
    public static func decompress(_ format: Format, from source: URL, to destination: URL) throws -> UInt64 {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw DecompressError.cannotOpen(source.path, errno) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw DecompressError.cannotOpen(destination.path, errno) }
        defer { close(output) }

        let algorithm: compression_algorithm
        switch format {
        case .xz: algorithm = COMPRESSION_LZMA
        }

        let inputCapacity = 4 << 20
        let outputCapacity = blockSize
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { inputBuffer.deallocate() }
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer { outputBuffer.deallocate() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DecompressError.decoderInitFailed
        }
        defer { compression_stream_destroy(stream) }
        stream.pointee.src_size = 0

        var writer = SparseWriter(fd: output)
        defer { writer.release() }
        var endOfInput = false

        while true {
            if stream.pointee.src_size == 0 && !endOfInput {
                let n = read(input, inputBuffer, inputCapacity)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DecompressError.io("reading the download", errno)
                }
                if n == 0 { endOfInput = true }
                stream.pointee.src_ptr = UnsafePointer(inputBuffer)
                stream.pointee.src_size = n
            }
            stream.pointee.dst_ptr = outputBuffer
            stream.pointee.dst_size = outputCapacity

            let flags = endOfInput ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = outputCapacity - stream.pointee.dst_size
            try writer.append(outputBuffer, count: produced)

            switch status {
            case COMPRESSION_STATUS_END:
                return try writer.finish()
            case COMPRESSION_STATUS_ERROR:
                throw DecompressError.corrupt(afterBytes: writer.length)
            default:
                // Finalizing with nothing left to read and nothing produced
                // means the stream stopped without its end marker.
                if endOfInput && stream.pointee.src_size == 0 && produced == 0 {
                    throw DecompressError.truncated(afterBytes: writer.length)
                }
            }
        }
    }

    /// Collects output into `blockSize` blocks and writes only the blocks
    /// that aren't entirely zero.
    struct SparseWriter {
        let fd: Int32
        private let block = UnsafeMutablePointer<UInt8>.allocate(capacity: ImageDecompressor.blockSize)
        private let zeros = UnsafeMutablePointer<UInt8>.allocate(capacity: ImageDecompressor.blockSize)
        private var filled = 0
        /// Where the current block starts in the output.
        private var offset: UInt64 = 0

        init(fd: Int32) {
            self.fd = fd
            zeros.initialize(repeating: 0, count: ImageDecompressor.blockSize)
        }

        var length: UInt64 { offset + UInt64(filled) }

        mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) throws {
            var consumed = 0
            while consumed < count {
                let n = min(count - consumed, ImageDecompressor.blockSize - filled)
                (block + filled).update(from: bytes + consumed, count: n)
                filled += n
                consumed += n
                if filled == ImageDecompressor.blockSize { try flush() }
            }
        }

        private mutating func flush() throws {
            guard filled > 0 else { return }
            if memcmp(block, zeros, filled) != 0 {
                var written = 0
                while written < filled {
                    let n = pwrite(fd, block + written, filled - written, off_t(offset) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw DecompressError.io("writing the image", errno)
                    }
                    written += n
                }
            }
            offset += UInt64(filled)
            filled = 0
        }

        /// Writes what's left and sets the file's length - which trailing
        /// zero blocks, never written, would otherwise leave short.
        mutating func finish() throws -> UInt64 {
            try flush()
            guard ftruncate(fd, off_t(offset)) == 0 else { throw DecompressError.io("sizing the image", errno) }
            return offset
        }

        func release() {
            block.deallocate()
            zeros.deallocate()
        }
    }
}
