import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Talks to `memd` over vsock (guest port 5007).
///
/// Same shape as `TrafficClient`: one connection per request, one
/// length-prefixed frame each way, no pooling and no pushing. The guest
/// sleeps in `accept()` between requests, so an idle instance costs nothing
/// on either side of the boundary.
///
/// **Every image in existence predates this daemon.** A guest without
/// `memd` refuses the connect, which surfaces as `.unavailable` - a
/// distinct case so the UI can say "this image is too old for dynamic
/// memory" rather than silently behaving like a fixed allocation.
public final class MemoryClient {
    private let manager: VMManager

    public init(manager: VMManager) {
        self.manager = manager
    }

    public enum MemoryClientError: Error, CustomStringConvertible {
        case unavailable
        case connectionClosed
        case malformed
        case remote(errno: Int32)

        public var description: String {
            switch self {
            case .unavailable: return "this instance's image has no memory daemon"
            case .connectionClosed: return "the guest closed the connection"
            case .malformed: return "the guest sent a reply this version cannot read"
            case .remote(let code): return "the guest reported errno \(code)"
            }
        }
    }

    private enum Op: UInt8 {
        case memstat = 0x01
        case compact = 0x02
    }

    /// One reading of the guest's memory.
    ///
    /// `capturedAt` is stamped on the host, on purpose: the guest's clock is
    /// its own, and the controller uses this only to decide whether the
    /// reading is too old to act on - which is a question about how long ago
    /// *we* asked.
    public func sample() async throws -> GuestMemorySample {
        let body = try await perform(Op.memstat)
        var cursor = 0
        func u64() throws -> UInt64 {
            guard cursor + 8 <= body.count else { throw MemoryClientError.malformed }
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(body[cursor + index]) << (8 * index) }
            cursor += 8
            return value
        }

        let total = try u64(), available = try u64(), free = try u64()
        let fileCache = try u64(), anonymous = try u64(), swapTotal = try u64()

        guard cursor < body.count else { throw MemoryClientError.malformed }
        let stallPresent = body[cursor] != 0
        cursor += 1
        guard cursor + 4 <= body.count else { throw MemoryClientError.malformed }
        var centipercent: UInt32 = 0
        for index in 0..<4 { centipercent |= UInt32(body[cursor + index]) << (8 * index) }
        cursor += 4

        // Optional, newer memd only: whether /proc/vmstat has
        // nr_balloon_pages, and that figure in kB. A reply that stops above is
        // an older memd, and the balloon stays unknown rather than zero - see
        // `GuestMemorySample.discountingBalloon()`.
        var balloonKB: UInt64?
        if cursor + 1 + 8 <= body.count {
            let balloonPresent = body[cursor] != 0
            cursor += 1
            let value = try u64()
            if balloonPresent { balloonKB = value }
        }

        guard total > 0 else { throw MemoryClientError.malformed }
        return GuestMemorySample(
            totalKB: total, availableKB: available, freeKB: free,
            fileCacheKB: fileCache, anonymousKB: anonymous,
            swapTotalKB: swapTotal,
            balloonKB: balloonKB,
            stallPercentAvg10: stallPresent ? Double(centipercent) / 100.0 : nil,
            capturedAt: Date())
    }

    /// Ask the guest to compact physical memory before a large inflate.
    ///
    /// Best-effort by design: this is an optimisation the framework
    /// recommends, not a precondition. A guest that refuses (no
    /// `CONFIG_COMPACTION`, a read-only `/proc`) just makes the balloon
    /// slightly less effective, which is not worth failing the adjustment
    /// over.
    public func compact() async {
        _ = try? await perform(Op.compact)
    }

    public func isAvailable() async -> Bool {
        do { _ = try await sample(); return true } catch { return false }
    }

    private func perform(_ op: Op) async throws -> [UInt8] {
        // No `ensureRunning()`: waking a suspended guest to ask how much
        // memory it is using would change the answer, and a suspended guest
        // is not the one under memory pressure.
        let fd: Int32
        do {
            fd = try await manager.openMemoryConnection()
        } catch {
            throw MemoryClientError.unavailable
        }
        defer { manager.releaseConnection(fd: fd) }

        try Self.writeFrame(fd: fd, payload: [op.rawValue])
        let response = try Self.readFrame(fd: fd)
        guard let status = response.first else { throw MemoryClientError.connectionClosed }
        let body = Array(response.dropFirst())
        if status == 0x00 { return body }
        guard body.count >= 4 else { throw MemoryClientError.connectionClosed }
        let code = Int32(bitPattern: UInt32(body[0]) | (UInt32(body[1]) << 8)
                                   | (UInt32(body[2]) << 16) | (UInt32(body[3]) << 24))
        if code == EINVAL { throw MemoryClientError.unavailable }
        throw MemoryClientError.remote(errno: code)
    }

    // MARK: - Framing

    /// A memstat reply is 54 bytes. The cap is generous rather than tight
    /// because the length prefix is untrusted input from the guest, and the
    /// point is to refuse an absurd allocation, not to police the format.
    private static let maxFrameBytes: UInt32 = 64 * 1024

    private static func writeFrame(fd: Int32, payload: [UInt8]) throws {
        var header = [UInt8](repeating: 0, count: 4)
        let length = UInt32(payload.count)
        for index in 0..<4 { header[index] = UInt8((length >> (8 * index)) & 0xFF) }
        try writeFull(fd: fd, bytes: header + payload)
    }

    private static func readFrame(fd: Int32) throws -> [UInt8] {
        let header = try readFull(fd: fd, count: 4)
        let length = UInt32(header[0]) | (UInt32(header[1]) << 8)
                   | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
        guard length <= maxFrameBytes else { throw MemoryClientError.connectionClosed }
        return length == 0 ? [] : try readFull(fd: fd, count: Int(length))
    }

    private static func writeFull(fd: Int32, bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBufferPointer { buffer in
            while sent < bytes.count {
                let written = write(fd, buffer.baseAddress! + sent, bytes.count - sent)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MemoryClientError.connectionClosed
                }
                sent += written
            }
        }
    }

    private static func readFull(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        try buffer.withUnsafeMutableBufferPointer { pointer in
            while got < count {
                let bytes = read(fd, pointer.baseAddress! + got, count - got)
                if bytes < 0 {
                    if errno == EINTR { continue }
                    throw MemoryClientError.connectionClosed
                }
                if bytes == 0 { throw MemoryClientError.connectionClosed }
                got += bytes
            }
        }
        return buffer
    }
}
