import XCTest
@testable import MSLApp

/// The "hibernate is not how you save your work" explanation.
@MainActor
final class HibernateNoticeTests: XCTestCase {
    private let key = "msl.hibernate.warned"
    private var saved: Bool!

    override func setUp() {
        saved = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
    override func tearDown() { UserDefaults.standard.set(saved, forKey: key) }

    /// Shown the first time, because the surprise costs whatever was open.
    func testItIsShownOnAFreshMac() {
        XCTAssertFalse(AppModel.hibernateWarningSilenced)
    }

    /// And never again once dismissed. An alert that cannot be turned off is
    /// a reason to stop using the button rather than to read it.
    func testDontRemindMeSticks() {
        AppModel.hibernateWarningSilenced = true
        XCTAssertTrue(AppModel.hibernateWarningSilenced)
    }
}
