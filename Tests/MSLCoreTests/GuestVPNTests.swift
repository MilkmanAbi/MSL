import XCTest
@testable import MSLCore

final class GuestVPNTests: XCTestCase {
    func testStatusParsesEveryFlag() {
        let status = GuestVPN.parseStatus("""
        MSL-VPN-INSTALLED\r
        MSL-VPN-WIREGUARD\r
        MSL-VPN-TOKEN\r
        MSL-VPN-CONNECTED\r
        MSL-VPN-OK\r
        """)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.wireGuard)
        XCTAssertTrue(status.hasToken)
        XCTAssertTrue(status.connected)
        XCTAssertNil(status.nextStep(), "nothing left to do once it is connected")
    }

    func testEmptyStatusIsEmpty() {
        let status = GuestVPN.parseStatus("MSL-VPN-OK\n")
        XCTAssertFalse(status.installed)
        XCTAssertEqual(status.nextStep(), "Install the hide.me client to use it here.")
    }

    /// A kernel with no WireGuard cannot connect, and saying so before the
    /// download is the point of checking it in the same pass.
    func testMissingWireGuardIsTheBlockingStep() {
        let status = GuestVPN.parseStatus("MSL-VPN-INSTALLED\n")
        XCTAssertEqual(status.nextStep()?.contains("no WireGuard support"), true)
    }

    func testLoginComesBeforeConnect() {
        let status = GuestVPN.parseStatus("MSL-VPN-INSTALLED\nMSL-VPN-WIREGUARD\n")
        XCTAssertEqual(status.nextStep()?.contains("hide.me token"), true)
        let loggedIn = GuestVPN.parseStatus("MSL-VPN-INSTALLED\nMSL-VPN-WIREGUARD\nMSL-VPN-TOKEN\n")
        XCTAssertEqual(loggedIn.nextStep()?.contains("hide.me connect"), true)
    }

    /// The checksum is the only thing standing between a download and root
    /// in someone's instance, so a mismatch has to be its own result and
    /// carry what was actually seen.
    func testChecksumMismatchIsReported() {
        let result = GuestVPN.parseInstall("MSL-VPN-CHECKSUM-MISMATCH deadbeef\nMSL-VPN-OK\n")
        XCTAssertEqual(result, .checksumMismatch("deadbeef"))
        XCTAssertTrue(result.message.contains("Nothing was installed"))
    }

    func testInstallResultsAreDistinct() {
        XCTAssertEqual(GuestVPN.parseInstall("MSL-VPN-INSTALLED\nMSL-VPN-OK\n"), .installed)
        XCTAssertEqual(GuestVPN.parseInstall("MSL-VPN-NO-DOWNLOADER\n"), .noDownloader)
        XCTAssertEqual(GuestVPN.parseInstall("MSL-VPN-DOWNLOAD-FAILED\n"), .downloadFailed)
        XCTAssertEqual(GuestVPN.parseInstall("MSL-VPN-NO-CHECKSUM-TOOL\n"), .noChecksumTool)
        XCTAssertEqual(GuestVPN.parseInstall("MSL-VPN-EXTRACT-FAILED\n"), .extractFailed)
    }

    /// The download must be pinned to the version whose checksum is pinned,
    /// or the check is theatre.
    func testURLAndChecksumAgreeOnVersion() {
        XCTAssertTrue(GuestVPN.downloadURL.contains("v\(GuestVPN.version)"))
        XCTAssertTrue(GuestVPN.downloadURL.contains("arm64-\(GuestVPN.version).tar.gz"))
        XCTAssertEqual(GuestVPN.sha256.count, 64)
    }

    func testScriptsParseAsShell() throws {
        for (name, script) in [("status", GuestVPN.statusScript),
                               ("install", GuestVPN.installScript),
                               ("remove", GuestVPN.removeScript)] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("msl-vpn-\(name)-\(UUID().uuidString).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", url.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "\(name) script is not valid shell: \(text)")
        }
    }
}
