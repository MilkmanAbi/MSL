import XCTest
@testable import MSLCore

final class MSLExperimentalSettingsTests: XCTestCase {
    /// A file written before a default changed holds an explicit `false`,
    /// so changing the default in the struct reaches nobody who has ever
    /// opened the Experimental Features window. This is the migration that
    /// fixes that, and the test that it only promotes what it should.
    func testMigrationTurnsOnTheIntegrationDefaults() throws {
        // Exactly what this Mac's `experimental.json` held: the four new
        // flags off, and two values the person chose for themselves.
        let old = """
        {
          "globalMenuBar" : false,
          "gpuAcceleration" : true,
          "guestClipboard" : false,
          "linuxShortcuts" : false,
          "macTextNavigation" : false,
          "nativeScaling" : false,
          "omitPeripheralsPrompt" : false,
          "openLinksOnMac" : true,
          "optionKeyMode" : "leftAltRightAltGr",
          "preferMSLFiles" : true,
          "screenshotKeys" : false
        }
        """
        let settings = try JSONDecoder().decode(MSLExperimentalSettings.self,
                                                from: Data(old.utf8))
        // Promoted.
        XCTAssertTrue(settings.linuxShortcuts)
        XCTAssertTrue(settings.macTextNavigation)
        XCTAssertTrue(settings.screenshotKeys)
        XCTAssertTrue(settings.guestClipboard)
        // Generation 3 promotes the menu bar, so that one is now on too.
        XCTAssertTrue(settings.globalMenuBar)
        // **Untouched.** Nothing any generation promoted keeps whatever was
        // stored - a blanket "reset to defaults" would have silently undone
        // this, which is the whole reason the migration is per-flag.
        XCTAssertTrue(settings.gpuAcceleration)
        XCTAssertFalse(settings.nativeScaling)
        XCTAssertFalse(settings.omitPeripheralsPrompt)
        XCTAssertEqual(settings.defaultsGeneration, MSLExperimentalSettings.currentGeneration)
    }

    /// Once migrated, a later read must not re-promote anything: turning a
    /// flag back off has to stick.
    func testMigrationRunsOnce() throws {
        var settings = MSLExperimentalSettings()
        settings.linuxShortcuts = false
        settings.guestClipboard = false
        let data = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(MSLExperimentalSettings.self, from: data)
        XCTAssertFalse(reloaded.linuxShortcuts)
        XCTAssertFalse(reloaded.guestClipboard)
    }

    /// A file from a build that never knew about generations is generation 1.
    func testFileWithoutAGenerationIsMigrated() throws {
        let settings = try JSONDecoder().decode(MSLExperimentalSettings.self,
                                                from: Data("{}".utf8))
        XCTAssertTrue(settings.linuxShortcuts)
        XCTAssertEqual(settings.defaultsGeneration, MSLExperimentalSettings.currentGeneration)
    }

    /// A read failure must be distinguishable from "no file", because
    /// anything that writes back what it read turns the first into data
    /// loss. Losing that distinction overwrote two real settings.
    func testUnreadableFileIsNotReportedAsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-exp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // No file at all: defaults are a real answer.
        XCTAssertEqual(MSLExperimentalSettingsStore.loadIfReadable(from: url),
                       MSLExperimentalSettings())
        // A file that exists but cannot be decoded: no answer, so a caller
        // that would write back knows to leave it alone.
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(MSLExperimentalSettingsStore.loadIfReadable(from: url))
        // `load` still answers, for the readers that only read.
        XCTAssertEqual(MSLExperimentalSettingsStore.load(from: url), MSLExperimentalSettings())
    }

    /// The shipped defaults, so a change to one is a deliberate edit here.
    func testShippedDefaults() {
        let defaults = MSLExperimentalSettings()
        XCTAssertTrue(defaults.linuxShortcuts)
        XCTAssertTrue(defaults.macTextNavigation)
        XCTAssertTrue(defaults.screenshotKeys)
        XCTAssertTrue(defaults.guestClipboard)
        XCTAssertTrue(defaults.openLinksOnMac)
        XCTAssertTrue(defaults.preferMSLFiles)
        XCTAssertTrue(defaults.globalMenuBar)
        // Still off: these cost something or need hardware.
        XCTAssertFalse(defaults.omitPeripheralsPrompt)
        XCTAssertFalse(defaults.nativeScaling)
        XCTAssertFalse(defaults.gpuAcceleration)
    }
}
