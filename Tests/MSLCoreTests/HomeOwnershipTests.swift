import XCTest
@testable import MSLCore

/// The repair for homes MSL made root-owned while it ran apps as root.
final class HomeOwnershipTests: XCTestCase {
    func testScanReportsCountAndSamples() {
        let output = """
        MSL-HOME /home/abinaash
        MSL-WRONG 3
        MSL-SAMPLE /home/abinaash/.config/gtk-3.0/settings.ini
        MSL-SAMPLE /home/abinaash/.cache/thumbnails
        """
        let report = HomeOwnership.parse(output)
        XCTAssertEqual(report?.home, "/home/abinaash")
        XCTAssertEqual(report?.wrongCount, 3)
        XCTAssertEqual(report?.samples.count, 2)
        XCTAssertTrue(report?.needsRepair == true)
    }

    func testNothingWrongIsNotARepair() {
        let report = HomeOwnership.parse("MSL-HOME /home/abi\nMSL-WRONG 0")
        XCTAssertEqual(report?.wrongCount, 0)
        XCTAssertFalse(report?.needsRepair == true)
    }

    func testNoHomeDirectoryIsNil() {
        XCTAssertNil(HomeOwnership.parse("MSL-HOME-MISSING"))
        XCTAssertNil(HomeOwnership.parse("some unrelated warning"))
    }

    /// Real output from the guest: shellinit gives every command a pty, so
    /// the lines come back CRLF-terminated. Parsing that as-is is what made
    /// the first live run report "couldn't find the home directory".
    func testParsesCarriageReturnedOutputFromAPty() {
        let output = "MSL-HOME /home/abinaash\r\nMSL-WRONG 2\r\nMSL-SAMPLE /home/abinaash/.cache\r\n"
        let report = HomeOwnership.parse(output)
        XCTAssertEqual(report?.wrongCount, 2)
        XCTAssertEqual(report?.home, "/home/abinaash")
        XCTAssertEqual(HomeOwnership.parseRepaired("MSL-REPAIRED 7\r\n"), 7)
    }

    func testRepairCountIsRead() {
        XCTAssertEqual(HomeOwnership.parseRepaired("MSL-REPAIRED 41\nMSL-WRONG 0"), 41)
        XCTAssertNil(HomeOwnership.parseRepaired("MSL-WRONG 0"))
    }

    /// A username is never pasted raw into the shell, and the walk never
    /// leaves the guest's own filesystem: the Mac's home is mounted inside
    /// the guest, and chowning that would be a disaster.
    func testScriptsQuoteTheUserAndStayOnOneFilesystem() {
        let script = HomeOwnership.repairScript(user: "ab'i")
        XCTAssertTrue(script.contains(#"'ab'\''i'"#), script)
        XCTAssertFalse(script.contains("! -user ab'i "))
        for script in [HomeOwnership.scanScript(user: "abi"), HomeOwnership.repairScript(user: "abi")] {
            XCTAssertTrue(script.contains("-xdev"), "must not cross into /mnt/mac")
            XCTAssertTrue(script.contains("/etc/passwd"), "home comes from passwd, not a guess")
            XCTAssertTrue(script.contains("awk -F:"), "Alpine has no getent, so awk reads passwd")
        }
        XCTAssertFalse(HomeOwnership.scanScript(user: "abi").contains("chown"), "a scan must change nothing")
    }
}
