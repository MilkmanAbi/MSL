import XCTest
@testable import MSLCore

final class RemovalConfirmationTests: XCTestCase {
    func testTheWordConfirms() {
        XCTAssertTrue(RemovalConfirmation.matches("Meow"))
    }

    func testCaseAndSurroundingWhitespaceDoNotMatter() {
        XCTAssertTrue(RemovalConfirmation.matches("meow"))
        XCTAssertTrue(RemovalConfirmation.matches("MEOW"))
        XCTAssertTrue(RemovalConfirmation.matches("  Meow \n"))
    }

    func testAnythingElseDoesNot() {
        XCTAssertFalse(RemovalConfirmation.matches(""))
        XCTAssertFalse(RemovalConfirmation.matches("Meo"))
        XCTAssertFalse(RemovalConfirmation.matches("Meow!"))
        XCTAssertFalse(RemovalConfirmation.matches("Me ow"))
        XCTAssertFalse(RemovalConfirmation.matches("yes"))
    }
}
