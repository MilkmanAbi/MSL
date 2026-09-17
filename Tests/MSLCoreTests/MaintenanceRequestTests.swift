import XCTest
@testable import MSLCore

/// The `MAINTENANCE` control line, end to end through the daemon protocol.
///
/// `ControlRequest` isn't `Equatable`, so each check pattern-matches the
/// case it expects rather than comparing values.
final class MaintenanceRequestTests: XCTestCase {
    func testTheLineParses() {
        guard case .maintenance(let instance, let command)? =
                DaemonProtocol.ControlRequest.parse("MAINTENANCE work fsck-repair") else {
            return XCTFail("a MAINTENANCE line didn't parse")
        }
        XCTAssertEqual(instance, "work")
        XCTAssertEqual(command, .fsckRepair)
    }

    /// What the app sends is exactly what the daemon reads back, for every
    /// command on the list.
    func testEveryCommandRoundTripsThroughTheWire() {
        for command in MaintenanceCommand.allCases {
            let data = DaemonProtocol.ControlRequest.maintenance(instance: "dev", command: command).encode()
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard case .maintenance(let instance, let parsed)? = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("\(command.rawValue) didn't survive the round trip: \(line)")
            }
            XCTAssertEqual(instance, "dev")
            XCTAssertEqual(parsed, command)
        }
    }

    /// Unknown or malformed lines die at the edge. This is what keeps the
    /// command from ever turning into "run this".
    func testAnythingOffTheListIsRejectedAtParse() {
        for line in ["MAINTENANCE work rm-rf", "MAINTENANCE work util-shell",
                     "MAINTENANCE work", "MAINTENANCE", "MAINTENANCE work fsck-check extra"] {
            XCTAssertNil(DaemonProtocol.ControlRequest.parse(line), line)
        }
    }

    /// A maintenance run is never an ordinary start - the one VM it boots is
    /// its own, with the repair script as init.
    func testMaintenanceNeverCountsAsAStart() {
        for command in MaintenanceCommand.allCases {
            XCTAssertNil(DaemonProtocol.ControlRequest.maintenance(instance: "x", command: command).startsInstance,
                         command.rawValue)
        }
    }

    /// The card polls status every ten seconds; the actions are what's worth
    /// seeing in the Traffic Monitor.
    func testStatusPollingStaysOutOfTheActivityLog() {
        XCTAssertNil(DaemonProtocol.ControlRequest.maintenance(instance: "x", command: .status).monitorSummary)
        XCTAssertEqual(DaemonProtocol.ControlRequest.maintenance(instance: "x", command: .fsckRepair).monitorSummary,
                       "Maintenance: fsck-repair")
    }
}
