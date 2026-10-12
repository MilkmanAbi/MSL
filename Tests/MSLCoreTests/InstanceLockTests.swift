import XCTest
@testable import MSLCore

/// "Ask before starting this instance", enforced by the background service.
final class InstanceLockTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-locks-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    func testNothingIsLockedByDefault() {
        XCTAssertFalse(InstanceLockStore.load(from: file).isLocked("work"))
    }

    func testLockingIsPerInstanceAndSurvives() {
        XCTAssertTrue(InstanceLockStore.setLocked(true, for: "work", in: file))
        XCTAssertTrue(InstanceLockStore.load(from: file).isLocked("work"))
        XCTAssertFalse(InstanceLockStore.load(from: file).isLocked("scratch"))
        XCTAssertTrue(InstanceLockStore.setLocked(false, for: "work", in: file))
        XCTAssertFalse(InstanceLockStore.load(from: file).isLocked("work"))
    }

    /// Authentication guards *starting*. Asking again for an instance that is
    /// already up would fire every time a Linux app reconnects, which is
    /// often, and would make the feature unusable.
    func testRunningInstancesAreNotAskedAgain() {
        var settings = InstanceLockSettings()
        settings.setLocked(true, for: "work")
        XCTAssertTrue(InstanceLockPolicy.requiresAuthentication(instance: "work", isRunningOrPaused: false, settings: settings))
        XCTAssertFalse(InstanceLockPolicy.requiresAuthentication(instance: "work", isRunningOrPaused: true, settings: settings))
        XCTAssertFalse(InstanceLockPolicy.requiresAuthentication(instance: "other", isRunningOrPaused: false, settings: settings))
    }

    func testPromptNamesTheInstance() {
        XCTAssertEqual(InstanceLockPolicy.reason(for: "work"), "start work")
    }

    func testDamagedFileIsNotALock() throws {
        try Data("{{{".utf8).write(to: file)
        XCTAssertFalse(InstanceLockStore.load(from: file).isLocked("work"))
    }
}
