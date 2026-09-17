import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Talks to `trafficd` over vsock (guest port 5006).
///
/// Same shape as `FileOpsClient`: one connection per request, one
/// length-prefixed frame each way, no pooling. Deliberately request/
/// response rather than a stream - a pushing daemon would need a second
/// connection model, backpressure, and a fresh way to reach the runaway-log
/// failure this project has already had once.
///
/// **Every image in existence predates this daemon.** A guest without
/// `trafficd` refuses the vsock connect, which surfaces here as
/// `TrafficClientError.unavailable` - a distinct case on purpose, so the UI
/// can say "this image is too old" instead of drawing an empty list that
/// reads as "nothing is happening".
public final class TrafficClient {
    private let manager: VMManager

    public init(manager: VMManager) {
        self.manager = manager
    }

    public enum TrafficClientError: Error, CustomStringConvertible {
        /// No `trafficd` on the other end - an image built before it existed.
        case unavailable
        case connectionClosed
        case remote(errno: Int32)

        public var description: String {
            switch self {
            case .unavailable: return "this instance's image has no traffic daemon"
            case .connectionClosed: return "the guest closed the connection"
            case .remote(let code): return "the guest reported errno \(code)"
            }
        }
    }

    /// Every socket the guest currently has.
    ///
    /// `attributeProcesses` makes the guest walk `/proc/<pid>/fd` to name
    /// the owning process, which is every fd of every process - ask for it
    /// only when something is actually displaying names.
    public func sockets(attributeProcesses: Bool) async throws -> [TrafficProtocol.Connection] {
        try TrafficProtocol.parseSockets(
            try await perform(TrafficProtocol.encodeSockets(attributeProcesses: attributeProcesses)))
    }

    /// The undecoded SOCKETS payload, for relaying across the daemon socket
    /// to `MSLApp` - which parses it with the same parser rather than
    /// trusting a re-encode in the middle.
    public func rawSocketsPayload(attributeProcesses: Bool) async throws -> [UInt8] {
        try await perform(TrafficProtocol.encodeSockets(attributeProcesses: attributeProcesses))
    }

    public func interfaceStats() async throws -> [TrafficProtocol.InterfaceStats] {
        try TrafficProtocol.parseInterfaceStats(
            try await perform(TrafficProtocol.encodeInterfaceStats()))
    }

    /// Whether this guest can answer at all. Cheap enough to call before
    /// showing the view, and the honest way to choose between "no
    /// connections" and "this image cannot tell you".
    public func isAvailable() async -> Bool {
        do { _ = try await interfaceStats(); return true } catch { return false }
    }

    private func perform(_ request: [UInt8]) async throws -> [UInt8] {
        // Deliberately no `ensureRunning()` here, unlike FileOpsClient.
        // Waking a suspended VM to ask what its network is doing would be a
        // monitor that changes what it measures.
        let fd: Int32
        do {
            fd = try await manager.openTrafficConnection()
        } catch {
            throw TrafficClientError.unavailable
        }
        defer { manager.releaseConnection(fd: fd) }

        try Self.writeFrame(fd: fd, payload: request)
        let response = try Self.readFrame(fd: fd)
        guard let status = response.first else { throw TrafficClientError.connectionClosed }
        let body = Array(response.dropFirst())
        if status == 0x00 { return body }
        guard body.count >= 4 else { throw TrafficClientError.connectionClosed }
        let code = Int32(bitPattern: UInt32(body[0]) | (UInt32(body[1]) << 8)
                                   | (UInt32(body[2]) << 16) | (UInt32(body[3]) << 24))
        // EINVAL is what an older `trafficd` (or fileopsd's dispatch) returns
        // for an opcode it does not know - the documented probe result.
        if code == EINVAL { throw TrafficClientError.unavailable }
        throw TrafficClientError.remote(errno: code)
    }

    // MARK: - Framing

    /// Matches `FileOpsClient`'s cap and reasoning: a length prefix from the
    /// other side is untrusted input, and an unbounded allocation from it is
    /// how a confused guest takes the host down with it.
    private static let maxFrameBytes: UInt32 = 16 * 1024 * 1024

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
        guard length <= maxFrameBytes else { throw TrafficClientError.connectionClosed }
        return length == 0 ? [] : try readFull(fd: fd, count: Int(length))
    }

    private static func writeFull(fd: Int32, bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBufferPointer { buffer in
            while sent < bytes.count {
                let written = write(fd, buffer.baseAddress! + sent, bytes.count - sent)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw TrafficClientError.connectionClosed
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
                    throw TrafficClientError.connectionClosed
                }
                if bytes == 0 { throw TrafficClientError.connectionClosed }
                got += bytes
            }
        }
        return buffer
    }
}
