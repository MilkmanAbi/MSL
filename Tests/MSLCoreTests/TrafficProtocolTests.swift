import XCTest
@testable import MSLCore

/// The host half of `trafficd`'s wire format.
///
/// The guest half has its own fixture tests in C
/// (`Guest/init/tests/trafficd_test.c`) because the `/proc` parsing lives
/// there and cannot be reached from here. These cover the binary records
/// that cross the vsock, and the address rendering - which is the part a
/// user actually reads, and therefore the part where being wrong is
/// invisible rather than loud.
final class TrafficProtocolTests: XCTestCase {

    // MARK: - Builders mirroring what trafficd emits

    private func socketPayload(_ rows: [(family: UInt8, proto: UInt8, state: UInt8,
                                         local: [UInt8], lport: UInt16,
                                         remote: [UInt8], rport: UInt16,
                                         inode: UInt32, uid: UInt32, name: String)]) -> [UInt8] {
        var out: [UInt8] = []
        appendU32(&out, UInt32(rows.count))
        for row in rows {
            out.append(row.family)
            out.append(row.proto)
            out.append(row.state)
            out += pad16(row.local)
            appendU16(&out, row.lport)
            out += pad16(row.remote)
            appendU16(&out, row.rport)
            appendU32(&out, row.inode)
            appendU32(&out, row.uid)
            let nameBytes = Array(row.name.utf8)
            appendU16(&out, UInt16(nameBytes.count))
            out += nameBytes
        }
        return out
    }

    private func pad16(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: max(0, 16 - bytes.count))
    }
    private func appendU16(_ out: inout [UInt8], _ value: UInt16) {
        out += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
    private func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out += (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    private func appendU64(_ out: inout [UInt8], _ value: UInt64) {
        out += (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private func row(local: [UInt8] = [127, 0, 0, 1], lport: UInt16 = 22,
                     remote: [UInt8] = [0, 0, 0, 0], rport: UInt16 = 0,
                     state: UInt8 = 0x0A, proto: UInt8 = 6, family: UInt8 = 4,
                     inode: UInt32 = 1, uid: UInt32 = 0, name: String = "")
        -> (family: UInt8, proto: UInt8, state: UInt8, local: [UInt8], lport: UInt16,
            remote: [UInt8], rport: UInt16, inode: UInt32, uid: UInt32, name: String) {
        (family, proto, state, local, lport, remote, rport, inode, uid, name)
    }

    // MARK: - Requests

    func testProcessAttributionIsOptInOnTheWire() {
        // Attribution walks every fd of every process in the guest. It must
        // be something the host asks for, not something it always pays for.
        XCTAssertEqual(TrafficProtocol.encodeSockets(attributeProcesses: false), [0x01, 0x00])
        XCTAssertEqual(TrafficProtocol.encodeSockets(attributeProcesses: true), [0x01, 0x01])
        XCTAssertEqual(TrafficProtocol.encodeInterfaceStats(), [0x02])
    }

    // MARK: - Sockets

    func testParsesAListeningSocket() throws {
        let payload = socketPayload([row(local: [0, 0, 0, 0], lport: 22, state: 0x0A, inode: 12345)])
        let connections = try TrafficProtocol.parseSockets(payload)
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections[0].localAddress, "0.0.0.0")
        XCTAssertEqual(connections[0].localPort, 22)
        XCTAssertEqual(connections[0].stateName, "LISTEN")
        XCTAssertTrue(connections[0].isListening)
        XCTAssertEqual(connections[0].proto, .tcp)
    }

    func testParsesAnEstablishedConnectionWithAProcessName() throws {
        let payload = socketPayload([row(local: [192, 168, 64, 3], lport: 51000,
                                         remote: [1, 1, 1, 1], rport: 443,
                                         state: 0x01, inode: 999, uid: 1000, name: "curl")])
        let connection = try XCTUnwrap(try TrafficProtocol.parseSockets(payload).first)
        XCTAssertEqual(connection.remoteAddress, "1.1.1.1")
        XCTAssertEqual(connection.remotePort, 443)
        XCTAssertEqual(connection.stateName, "ESTABLISHED")
        XCTAssertEqual(connection.processName, "curl")
        XCTAssertEqual(connection.uid, 1000)
        XCTAssertFalse(connection.isListening)
    }

    func testUdpStateSevenReadsAsUnconnectedNotClose() throws {
        // The same number means different things per protocol, and "CLOSE"
        // on a perfectly healthy DNS socket would be alarming nonsense.
        let udp = socketPayload([row(state: 0x07, proto: 17)])
        XCTAssertEqual(try TrafficProtocol.parseSockets(udp).first?.stateName, "UNCONNECTED")
        let tcp = socketPayload([row(state: 0x07, proto: 6)])
        XCTAssertEqual(try TrafficProtocol.parseSockets(tcp).first?.stateName, "CLOSE")
    }

    func testLoopbackIsIdentifiableSoItCanBeFilteredOut() throws {
        let payload = socketPayload([
            row(local: [127, 0, 0, 1], lport: 631),
            row(local: [192, 168, 64, 3], lport: 22, remote: [192, 168, 64, 1], rport: 5000),
        ])
        let connections = try TrafficProtocol.parseSockets(payload)
        XCTAssertTrue(connections[0].isLoopback)
        XCTAssertFalse(connections[1].isLoopback)
    }

    func testAnEmptyTableIsEmptyNotAnError() throws {
        XCTAssertEqual(try TrafficProtocol.parseSockets(socketPayload([])).count, 0)
    }

    func testUnknownProtocolIsRefusedRatherThanGuessed() {
        let payload = socketPayload([row(proto: 99)])
        XCTAssertThrowsError(try TrafficProtocol.parseSockets(payload))
    }

    func testATruncatedFrameThrowsRatherThanCrashing() {
        // The guest is on the other end of a socket; a short frame has to be
        // an error, never an out-of-bounds read.
        var payload = socketPayload([row(name: "sshd")])
        payload.removeLast(6)
        XCTAssertThrowsError(try TrafficProtocol.parseSockets(payload)) { error in
            guard case TrafficProtocol.TrafficError.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testAClaimedCountLargerThanTheFrameThrows() {
        // A count of 100 with one record's worth of bytes must not spin or
        // read past the end.
        var payload: [UInt8] = []
        appendU32(&payload, 100)
        XCTAssertThrowsError(try TrafficProtocol.parseSockets(payload))
    }

    func testAnUndecodableProcessNameCostsOnlyTheName() throws {
        // The connection is the useful part; the label is not worth losing
        // it over. (Same lesson as the guest listing that used to hide a
        // whole directory over one bad filename.)
        var payload: [UInt8] = []
        appendU32(&payload, 1)
        payload += [4, 6, 0x01]
        payload += pad16([10, 0, 0, 5]); appendU16(&payload, 100)
        payload += pad16([10, 0, 0, 6]); appendU16(&payload, 200)
        appendU32(&payload, 7); appendU32(&payload, 0)
        appendU16(&payload, 2); payload += [0xFF, 0xFE]   // not valid UTF-8

        let connection = try XCTUnwrap(try TrafficProtocol.parseSockets(payload).first)
        XCTAssertEqual(connection.localAddress, "10.0.0.5")
        XCTAssertEqual(connection.remotePort, 200)
        XCTAssertFalse(connection.processName.isEmpty, "replacement characters, not an empty name")
    }

    // MARK: - Address rendering

    func testIPv4Rendering() {
        XCTAssertEqual(TrafficProtocol.formatAddress([127, 0, 0, 1] + [UInt8](repeating: 0, count: 12), family: 4),
                       "127.0.0.1")
        XCTAssertEqual(TrafficProtocol.formatAddress([255, 255, 255, 255] + [UInt8](repeating: 0, count: 12), family: 4),
                       "255.255.255.255")
    }

    func testIPv6LoopbackCollapses() {
        var bytes = [UInt8](repeating: 0, count: 16); bytes[15] = 1
        XCTAssertEqual(TrafficProtocol.formatAddress(bytes, family: 6), "::1")
    }

    func testIPv6MappedIPv4IsShownAsIPv4() {
        // Otherwise a perfectly ordinary connection reads as sixteen bytes
        // of hex nobody can match against anything.
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xFF; bytes[11] = 0xFF
        bytes[12] = 192; bytes[13] = 168; bytes[14] = 64; bytes[15] = 3
        XCTAssertEqual(TrafficProtocol.formatAddress(bytes, family: 6), "::ffff:192.168.64.3")
    }

    func testIPv6GeneralRendering() {
        // 2001:db8::1
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x20; bytes[1] = 0x01; bytes[2] = 0x0d; bytes[3] = 0xb8; bytes[15] = 1
        XCTAssertEqual(TrafficProtocol.formatAddress(bytes, family: 6), "2001:db8::1")
    }

    func testIPv6WithNoZeroRunIsNotCollapsed() {
        let bytes: [UInt8] = [0x20,0x01, 0x0d,0xb8, 0x00,0x01, 0x00,0x02,
                              0x00,0x03, 0x00,0x04, 0x00,0x05, 0x00,0x06]
        XCTAssertEqual(TrafficProtocol.formatAddress(bytes, family: 6), "2001:db8:1:2:3:4:5:6")
    }

    // MARK: - Interfaces

    func testParsesInterfaceCounters() throws {
        var payload: [UInt8] = []
        appendU32(&payload, 2)
        for (name, rx, tx) in [("lo", UInt64(1024), UInt64(1024)), ("enp0s1", 987_654_321, 12_345)] {
            let nameBytes = Array(name.utf8)
            appendU16(&payload, UInt16(nameBytes.count)); payload += nameBytes
            appendU64(&payload, rx); appendU64(&payload, 10)
            appendU64(&payload, tx); appendU64(&payload, 20)
        }
        let stats = try TrafficProtocol.parseInterfaceStats(payload)
        XCTAssertEqual(stats.map(\.name), ["lo", "enp0s1"])
        XCTAssertEqual(stats[1].rxBytes, 987_654_321)
        XCTAssertEqual(stats[1].txBytes, 12_345)
        XCTAssertEqual(stats[1].txPackets, 20)
    }

    func testTruncatedInterfaceStatsThrow() {
        var payload: [UInt8] = []
        appendU32(&payload, 1)
        appendU16(&payload, 4); payload += Array("eth0".utf8)   // counters missing
        XCTAssertThrowsError(try TrafficProtocol.parseInterfaceStats(payload))
    }
}
