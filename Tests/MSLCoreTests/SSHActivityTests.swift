import XCTest
@testable import MSLCore

final class SSHActivityTests: XCTestCase {
    private func connection(_ proto: TrafficProtocol.Connection.NetProtocol, local: UInt16, state: UInt8,
                            remote: String = "192.168.64.1", remotePort: UInt16 = 51234) -> TrafficProtocol.Connection {
        TrafficProtocol.Connection(family: 4, proto: proto, stateCode: state,
                                   localAddress: "192.168.64.130", localPort: local,
                                   remoteAddress: remote, remotePort: remotePort,
                                   inode: 1, uid: 0, processName: "")
    }

    func testAnEstablishedSSHConnectionIsALiveSession() {
        XCTAssertTrue(SSHActivity.hasLiveSessions([connection(.tcp, local: 22, state: 0x01)]))
    }

    func testAListeningSSHDAloneIsNot() {
        let listening = connection(.tcp, local: 22, state: 0x0A, remote: "0.0.0.0", remotePort: 0)
        XCTAssertFalse(SSHActivity.hasLiveSessions([listening]))
    }

    func testOtherPortsAndProtocolsDoNotCount() {
        XCTAssertFalse(SSHActivity.hasLiveSessions([
            connection(.tcp, local: 8080, state: 0x01),
            connection(.udp, local: 22, state: 0x01),
            connection(.tcp, local: 22, state: 0x08),   // CLOSE_WAIT - on its way out
        ]))
        XCTAssertFalse(SSHActivity.hasLiveSessions([]))
    }

    func testOneLiveSessionAmongOthersIsEnough() {
        XCTAssertTrue(SSHActivity.hasLiveSessions([
            connection(.tcp, local: 443, state: 0x01),
            connection(.tcp, local: 22, state: 0x0A, remote: "0.0.0.0", remotePort: 0),
            connection(.tcp, local: 22, state: 0x01),
        ]))
    }
}
