import XCTest
@testable import MSLCore

/// The greeting line and the cat, and the setting the app and the CLI share.
final class PersonalityTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-personality-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    func testBothOnByDefault() {
        XCTAssertTrue(PersonalitySettings.default.greeters)
        XCTAssertTrue(PersonalitySettings.default.kitty)
    }

    /// A missing or damaged file must never fail a shell, it just means the
    /// defaults.
    func testUnreadableFileMeansDefaults() throws {
        XCTAssertEqual(PersonalitySettingsStore.load(from: file), .default)
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(PersonalitySettingsStore.load(from: file), .default)
    }

    func testSettingSurvivesARoundTrip() {
        var settings = PersonalitySettings.default
        settings.greeters = false
        XCTAssertTrue(PersonalitySettingsStore.save(settings, to: file))
        XCTAssertEqual(PersonalitySettingsStore.load(from: file).greeters, false)
        XCTAssertEqual(PersonalitySettingsStore.load(from: file).kitty, true)
    }

    func testKittySaysOneLine() {
        let said = Kitty.say("hello")
        XCTAssertTrue(said.contains("< hello >"))
        XCTAssertTrue(said.contains("＼二つ"), "the cat herself should be there")
    }

    func testKittyWrapsLongSentences() {
        let words = Array(repeating: "meow", count: 30).joined(separator: " ")
        let said = Kitty.say(words)
        let bubble = said.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("|") || $0.hasPrefix("/") || $0.hasPrefix("\\") }
        XCTAssertGreaterThan(bubble.count, 2, "a long line should wrap into a multi-line bubble")
        XCTAssertTrue(bubble.allSatisfy { $0.count <= 44 }, "no line should run away")
    }

    func testEmptyWordsStillDrawABubble() {
        XCTAssertFalse(Kitty.say("").isEmpty)
    }
}
