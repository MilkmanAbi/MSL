import XCTest
@testable import MSLCore

/// Removing an instance takes its `~/.ssh/config` block with it - and only
/// its block. The file is the user's; everything they wrote, and every other
/// instance's entry, must come back exactly as it was.
final class SSHConfigRemovalTests: XCTestCase {
    private let userEntry = "Host work\n    HostName work.example.com\n    User me\n"

    func testRemovesOnlyThatInstancesBlock() {
        var config = SSHSetup.mergeConfig(existing: userEntry, instance: "arch", host: "192.168.64.9", user: "msl")
        config = SSHSetup.mergeConfig(existing: config, instance: "debian", host: "192.168.64.10", user: "msl")

        let trimmed = SSHSetup.removingBlock(from: config, instance: "arch")

        XCTAssertFalse(trimmed.contains("msl-arch"))
        XCTAssertFalse(trimmed.contains("MSL arch"))
        XCTAssertTrue(trimmed.contains("Host msl-debian"))
        XCTAssertTrue(trimmed.hasPrefix(userEntry))
    }

    func testSetUpThenRemoveRestoresTheOriginalFile() {
        let configured = SSHSetup.mergeConfig(existing: userEntry, instance: "arch", host: "192.168.64.9", user: "msl")
        XCTAssertEqual(SSHSetup.removingBlock(from: configured, instance: "arch"), userEntry)
    }

    func testRemovingTwiceIsHarmless() {
        let configured = SSHSetup.mergeConfig(existing: userEntry, instance: "arch", host: "192.168.64.9", user: "msl")
        let once = SSHSetup.removingBlock(from: configured, instance: "arch")
        XCTAssertEqual(SSHSetup.removingBlock(from: once, instance: "arch"), once)
    }

    func testAConfigWithoutTheBlockIsUntouched() {
        XCTAssertEqual(SSHSetup.removingBlock(from: userEntry, instance: "arch"), userEntry)
        XCTAssertEqual(SSHSetup.removingBlock(from: "", instance: "arch"), "")
    }

    func testAnInstanceWhoseNameIsAPrefixOfAnotherKeepsTheOther() {
        var config = SSHSetup.mergeConfig(existing: "", instance: "arch", host: "192.168.64.9", user: "msl")
        config = SSHSetup.mergeConfig(existing: config, instance: "arch-dev", host: "192.168.64.11", user: "msl")
        let trimmed = SSHSetup.removingBlock(from: config, instance: "arch")
        XCTAssertTrue(trimmed.contains("Host msl-arch-dev"))
        XCTAssertFalse(trimmed.contains("# >>> MSL arch >>>"))
    }
}
