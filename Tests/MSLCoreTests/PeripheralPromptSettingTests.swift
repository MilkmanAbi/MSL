import XCTest
@testable import MSLCore

/// "Omit MSL Peripherals prompt for media devices": off unless someone turns
/// it on, and never switched on by a settings file that predates it.
final class PeripheralPromptSettingTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertFalse(MSLExperimentalSettings().omitPeripheralsPrompt)
    }

    /// A file written before the flag existed must load with it OFF: a
    /// setting that skips a privacy question cannot appear by upgrading.
    func testAnOlderFileDecodesWithItOff() throws {
        let old = #"{"guestClipboard": true, "globalMenuBar": true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(MSLExperimentalSettings.self, from: old)
        XCTAssertFalse(settings.omitPeripheralsPrompt)
        XCTAssertTrue(settings.guestClipboard, "and the rest of the file still loads")
    }

    func testItRoundTrips() throws {
        var settings = MSLExperimentalSettings()
        settings.omitPeripheralsPrompt = true
        let back = try JSONDecoder().decode(MSLExperimentalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(back.omitPeripheralsPrompt)
    }
}
