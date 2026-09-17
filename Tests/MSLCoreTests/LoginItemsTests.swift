import XCTest
@testable import MSLCore

/// What MSL can start at login. Only the plists' contents are tested - writing
/// real ones into ~/Library/LaunchAgents from a test would change the machine.
final class LoginItemsTests: XCTestCase {
    func testLabelsNeverCollideWithTheDaemons() {
        for item in LoginItem.allCases {
            XCTAssertNotEqual(item.label, MSLPaths.launchAgentLabel)
            XCTAssertTrue(item.label.hasPrefix("com.msl.login."))
        }
        XCTAssertEqual(Set(LoginItem.allCases.map(\.label)).count, LoginItem.allCases.count)
    }

    func testTheTerminalItemOpensMSLInTerminal() {
        XCTAssertEqual(LoginItem.terminal.programArguments,
                       ["/usr/bin/open", "-a", "Terminal", MSLPaths.tool("msl").path])
    }

    func testTheAppItemFindsMSLByBundleIdentifier() {
        XCTAssertEqual(LoginItem.app.programArguments, ["/usr/bin/open", "-b", "com.msl.app"])
    }

    func testBothRunOnceAtLoginInTheUsersSession() {
        for item in LoginItem.allCases {
            XCTAssertEqual(item.plist["RunAtLoad"] as? Bool, true)
            XCTAssertEqual(item.plist["LimitLoadToSessionType"] as? String, "Aqua")
            XCTAssertNil(item.plist["KeepAlive"], "quitting Terminal or MSL must not relaunch it")
            XCTAssertEqual(item.plist["Label"] as? String, item.label)
        }
    }

    func testThePlistsLiveInTheUsersLaunchAgents() {
        for item in LoginItem.allCases {
            XCTAssertEqual(item.plistURL.path, NSHomeDirectory() + "/Library/LaunchAgents/\(item.label).plist")
        }
    }
}
