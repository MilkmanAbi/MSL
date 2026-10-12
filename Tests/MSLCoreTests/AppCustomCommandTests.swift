import XCTest
@testable import MSLCore

/// Per-app launch overrides. Uses a unique instance name and clears it
/// afterwards, because this store is the real one on disk — a test that
/// leaves entries behind would change how the user's own apps launch.
final class AppCustomCommandTests: XCTestCase {
    private let instance = "unit-test-instance-\(UUID().uuidString.prefix(8))"

    override func tearDown() {
        AppCustomCommandStore.set(nil, instance: instance, command: "mari0")
        AppCustomCommandStore.set(nil, instance: instance, command: " mari0 ")
        super.tearDown()
    }

    func testAnAppWithNoOverrideRunsItsOwnCommand() {
        XCTAssertNil(AppCustomCommandStore.command(instance: instance, command: "mari0"))
        XCTAssertEqual(
            AppCustomCommandStore.effectiveCommand(instance: instance, command: "mari0"), "mari0")
    }

    func testAnOverrideReplacesWhatRuns() {
        AppCustomCommandStore.set("love /snap/mari0/current/mari0", instance: instance, command: "mari0")
        XCTAssertEqual(
            AppCustomCommandStore.effectiveCommand(instance: instance, command: "mari0"),
            "love /snap/mari0/current/mari0")
    }

    func testClearingRestoresTheOriginal() {
        AppCustomCommandStore.set("something-else", instance: instance, command: "mari0")
        AppCustomCommandStore.set(nil, instance: instance, command: "mari0")
        XCTAssertEqual(
            AppCustomCommandStore.effectiveCommand(instance: instance, command: "mari0"), "mari0")
    }

    func testAWhitespaceOnlyOverrideIsTreatedAsNoOverride() {
        // Otherwise clearing the text field and saving would launch nothing
        // at all, with no way back from the UI.
        AppCustomCommandStore.set("   ", instance: instance, command: "mari0")
        XCTAssertNil(AppCustomCommandStore.command(instance: instance, command: "mari0"))
        XCTAssertEqual(
            AppCustomCommandStore.effectiveCommand(instance: instance, command: "mari0"), "mari0")
    }

    func testTheKeyIgnoresSurroundingWhitespaceAndSeparatesInstances() {
        // Matches AppGraphicsStore, so one app's two settings agree on what
        // identifies it.
        XCTAssertEqual(AppCustomCommandStore.key(instance: "Milk", command: " mari0 "),
                       AppCustomCommandStore.key(instance: "Milk", command: "mari0"))
        XCTAssertNotEqual(AppCustomCommandStore.key(instance: "Milk", command: "mari0"),
                          AppCustomCommandStore.key(instance: "Oat", command: "mari0"))
    }

    func testAnOverrideIsFoundRegardlessOfSurroundingWhitespace() {
        AppCustomCommandStore.set("love-11 mari0", instance: instance, command: " mari0 ")
        XCTAssertEqual(
            AppCustomCommandStore.effectiveCommand(instance: instance, command: "mari0"),
            "love-11 mari0")
    }
}
