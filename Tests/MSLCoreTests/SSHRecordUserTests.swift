import XCTest
@testable import MSLCore

/// A saved SSH record is only reused for the user SSH should land as now.
final class SSHRecordUserTests: XCTestCase {
    private let record = SSHSetup.Record(host: "192.168.64.130", user: "msl", alias: "msl-debian")

    func testARecordForTheSameUserIsReused() {
        XCTAssertTrue(SSHSetup.recordMatches(record, expectedUser: "msl"))
    }

    func testARecordForAnotherUserIsStale() {
        // Set up automatically as `msl` before the user created their account.
        XCTAssertFalse(SSHSetup.recordMatches(record, expectedUser: "abinaash"))
    }

    func testNoExpectationAcceptsAnyRecord() {
        XCTAssertTrue(SSHSetup.recordMatches(record, expectedUser: nil))
    }
}
