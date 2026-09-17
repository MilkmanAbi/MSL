import Foundation

/// The wire format `trafficd` speaks (guest vsock port 5006).
///
/// Length-prefixed binary throughout, unlike `FileOpsProtocol`'s
/// tab-delimited listing. That is a direct lesson from this codebase: a
/// filename containing a tab corrupts every entry after it in a LIST
/// response, and a process name out of `/proc/<pid>/comm` is arbitrary
/// bytes with the same hazard. New protocol, no back-compatibility to
/// preserve, so it does not repeat the mistake.
/// Strings the daemon and the app both need to agree on. In MSLCore rather
/// than in `mslhd` because `MSLApp` cannot import the daemon, and a marker
/// spelled differently on the two sides silently degrades into a generic
/// error message.
public enum DaemonServerMarkers {
    public static let trafficUnavailable = "traffic-daemon-unavailable"
}

public enum TrafficProtocol {

    public enum TrafficError: Error, CustomStringConvertible {
        case malformedResponse
        case truncated(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .malformedResponse: return "the guest sent a traffic response this host cannot read"
            case .truncated(let expected, let got): return "traffic response truncated (wanted \(expected) bytes, got \(got))"
            }
        }
    }

    // MARK: - Model

    /// One socket, as the guest's kernel sees it.
    ///
    /// Worth being precise about what this is: a *socket*, not a packet
    /// capture. It says the guest has a connection to an address and which
    /// process owns it. It says nothing about what crossed that connection.
    public struct Connection: Equatable, Identifiable, Sendable {
        public enum NetProtocol: UInt8, Sendable { case tcp = 6, udp = 17 }

        public var id: String { "\(proto.rawValue)-\(localAddress):\(localPort)-\(remoteAddress):\(remotePort)-\(inode)" }
        public let family: UInt8          // 4 or 6
        public let proto: NetProtocol
        public let stateCode: UInt8
        public let localAddress: String
        public let localPort: UInt16
        public let remoteAddress: String
        public let remotePort: UInt16
        public let inode: UInt32
        public let uid: UInt32
        /// Empty when the host did not ask for process attribution, or when
        /// the owning process exited between the two `/proc` reads.
        public let processName: String

        /// `/proc/net/tcp`'s `st` column. UDP reuses the same numbers but
        /// only really has 1 (ESTABLISHED, meaning connected) and 7.
        public var stateName: String {
            switch stateCode {
            case 0x01: return "ESTABLISHED"
            case 0x02: return "SYN_SENT"
            case 0x03: return "SYN_RECV"
            case 0x04: return "FIN_WAIT1"
            case 0x05: return "FIN_WAIT2"
            case 0x06: return "TIME_WAIT"
            case 0x07: return proto == .udp ? "UNCONNECTED" : "CLOSE"
            case 0x08: return "CLOSE_WAIT"
            case 0x09: return "LAST_ACK"
            case 0x0A: return "LISTEN"
            case 0x0B: return "CLOSING"
            default:   return "STATE_\(stateCode)"
            }
        }

        /// A listening socket has no meaningful peer, which is worth
        /// distinguishing in a UI: "listening on 0.0.0.0:22" is a very
        /// different fact from "connected to 0.0.0.0:0".
        public var isListening: Bool { stateCode == 0x0A }

        /// Loopback traffic never leaves the guest. Being able to filter it
        /// out is most of what makes the list readable.
        public var isLoopback: Bool {
            localAddress.hasPrefix("127.") || localAddress == "::1"
                || remoteAddress.hasPrefix("127.") || remoteAddress == "::1"
        }
    }

    public struct InterfaceStats: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let rxBytes: UInt64
        public let rxPackets: UInt64
        public let txBytes: UInt64
        public let txPackets: UInt64
    }

    // MARK: - Requests

    public static func encodeSockets(attributeProcesses: Bool) -> [UInt8] {
        // Attribution walks every fd of every process in the guest, so it is
        // a flag rather than the default - the host asks only when a view
        // that shows process names is actually open.
        [0x01, attributeProcesses ? 0x01 : 0x00]
    }

    public static func encodeInterfaceStats() -> [UInt8] { [0x02] }

    // MARK: - Responses

    public static func parseSockets(_ payload: [UInt8]) throws -> [Connection] {
        var cursor = Cursor(payload)
        let count = try cursor.u32()
        var connections: [Connection] = []
        connections.reserveCapacity(Int(count))
        for _ in 0..<count {
            let family = try cursor.u8()
            let protoRaw = try cursor.u8()
            let state = try cursor.u8()
            let local = try cursor.bytes(16)
            let localPort = try cursor.u16()
            let remote = try cursor.bytes(16)
            let remotePort = try cursor.u16()
            let inode = try cursor.u32()
            let uid = try cursor.u32()
            let nameLength = try cursor.u16()
            let nameBytes = try cursor.bytes(Int(nameLength))

            guard let proto = Connection.NetProtocol(rawValue: protoRaw) else {
                throw TrafficError.malformedResponse
            }
            connections.append(Connection(
                family: family,
                proto: proto,
                stateCode: state,
                localAddress: formatAddress(local, family: family),
                localPort: localPort,
                remoteAddress: formatAddress(remote, family: family),
                remotePort: remotePort,
                inode: inode,
                uid: uid,
                // A process name that is not valid UTF-8 is replaced rather
                // than dropping the whole connection - the connection is the
                // useful part and the name is a label.
                processName: String(decoding: nameBytes, as: UTF8.self)))
        }
        return connections
    }

    public static func parseInterfaceStats(_ payload: [UInt8]) throws -> [InterfaceStats] {
        var cursor = Cursor(payload)
        let count = try cursor.u32()
        var stats: [InterfaceStats] = []
        for _ in 0..<count {
            let nameLength = try cursor.u16()
            let name = String(decoding: try cursor.bytes(Int(nameLength)), as: UTF8.self)
            stats.append(InterfaceStats(name: name,
                                        rxBytes: try cursor.u64(),
                                        rxPackets: try cursor.u64(),
                                        txBytes: try cursor.u64(),
                                        txPackets: try cursor.u64()))
        }
        return stats
    }

    /// Renders the 16 raw bytes. IPv4 uses the first four; IPv6 is written
    /// in the usual grouped hex, including the `::ffff:` form for a
    /// v4-mapped address, because showing `::ffff:127.0.0.1` as sixteen
    /// bytes of hex helps nobody.
    static func formatAddress(_ bytes: [UInt8], family: UInt8) -> String {
        if family == 4 {
            return bytes.prefix(4).map(String.init).joined(separator: ".")
        }
        // v4-mapped: ::ffff:a.b.c.d
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let v4 = bytes[12..<16].map(String.init).joined(separator: ".")
            return "::ffff:\(v4)"
        }
        var groups: [String] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(String(format: "%x", (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])))
        }
        // Collapse the longest run of zero groups, per the usual notation.
        var bestStart = -1, bestLength = 0, runStart = -1, runLength = 0
        for (index, group) in groups.enumerated() {
            if group == "0" {
                if runStart < 0 { runStart = index; runLength = 0 }
                runLength += 1
                if runLength > bestLength { bestStart = runStart; bestLength = runLength }
            } else {
                runStart = -1; runLength = 0
            }
        }
        guard bestLength > 1 else { return groups.joined(separator: ":") }
        let head = groups[0..<bestStart].joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].joined(separator: ":")
        return "\(head)::\(tail)"
    }

    /// Bounds-checked reader. Every field is checked because the guest is
    /// on the other end of a socket and a short frame must be an error, not
    /// a crash - the same reason `FileOpsProtocol`'s encoders throw rather
    /// than trapping on an oversized conversion.
    private struct Cursor {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else {
                throw TrafficError.truncated(expected: offset + count, got: bytes.count)
            }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 {
            let raw = try bytes(2); return UInt16(raw[0]) | (UInt16(raw[1]) << 8)
        }
        mutating func u32() throws -> UInt32 {
            let raw = try bytes(4)
            return UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
        }
        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32()), hi = UInt64(try u32())
            return lo | (hi << 32)
        }
    }
}
