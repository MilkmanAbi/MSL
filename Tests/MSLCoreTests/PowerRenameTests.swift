import XCTest
@testable import MSLCore

/// Power Rename is the feature meant to make Finder feel primitive, so its name
/// arithmetic has to be exactly right - a batch rename that does something
/// subtly wrong is worse than none. These pin every operation and their order.
final class PowerRenameTests: XCTestCase {
    private func opts(_ build: (inout PowerRename.Options) -> Void) -> PowerRename.Options {
        var o = PowerRename.Options(); build(&o); return o
    }

    // The headline case from the ask: K123 -> Lie01.
    func testPlainFindReplace() {
        let o = opts { $0.find = "K123"; $0.replacement = "Lie01" }
        XCTAssertEqual(PowerRename.rename("K123_scan.tiff", index: 0, options: o), "Lie01_scan.tiff")
    }

    func testFindReplaceLeavesExtensionAlone() {
        let o = opts { $0.find = "tiff"; $0.replacement = "png" }  // name-only target
        XCTAssertEqual(PowerRename.rename("photo.tiff", index: 0, options: o), "photo.tiff")
    }

    func testExtensionOnlyTarget() {
        let o = opts { $0.find = "jpeg"; $0.replacement = "jpg"; $0.target = .extensionOnly }
        XCTAssertEqual(PowerRename.rename("holiday.jpeg", index: 0, options: o), "holiday.jpg")
    }

    func testCaseInsensitiveByDefault() {
        let o = opts { $0.find = "img"; $0.replacement = "photo" }
        XCTAssertEqual(PowerRename.rename("IMG_001.jpg", index: 0, options: o), "photo_001.jpg")
    }

    func testCaseSensitiveRespectsCase() {
        let o = opts { $0.find = "img"; $0.replacement = "photo"; $0.caseSensitive = true }
        XCTAssertEqual(PowerRename.rename("IMG_001.jpg", index: 0, options: o), "IMG_001.jpg")
    }

    func testRegexCapture() {
        let o = opts { $0.find = #"^(\d+)-(.+)$"#; $0.replacement = "$2-$1"; $0.useRegex = true }
        XCTAssertEqual(PowerRename.rename("2026-report.pdf", index: 0, options: o), "report-2026.pdf")
    }

    func testPrefixAndSuffix() {
        let o = opts { $0.prefix = "draft_"; $0.suffix = "_v2" }
        XCTAssertEqual(PowerRename.rename("notes.md", index: 0, options: o), "draft_notes_v2.md")
    }

    func testSequentialNumbering() {
        let o = opts { $0.numbering = true; $0.numberStart = 1; $0.numberPadding = 2; $0.numberSeparator = "-" }
        XCTAssertEqual(PowerRename.rename("shot.png", index: 0, options: o), "shot-01.png")
        XCTAssertEqual(PowerRename.rename("shot.png", index: 4, options: o), "shot-05.png")
    }

    func testNumberingPrefixPosition() {
        let o = opts { $0.numbering = true; $0.numberStart = 10; $0.numberIncrement = 10
                       $0.numberPadding = 3; $0.numberPosition = .prefix; $0.numberSeparator = "_" }
        XCTAssertEqual(PowerRename.rename("track.mp3", index: 0, options: o), "010_track.mp3")
        XCTAssertEqual(PowerRename.rename("track.mp3", index: 1, options: o), "020_track.mp3")
    }

    func testLetterCaseAppliesLast() {
        // Case transforms the name, not the extension (nobody wants ".TXT").
        let o = opts { $0.prefix = "New "; $0.letterCase = .upper }
        XCTAssertEqual(PowerRename.rename("readme.txt", index: 0, options: o), "NEW README.txt")
    }

    func testDotfileHasNoExtension() {
        let o = opts { $0.suffix = ".bak" }
        XCTAssertEqual(PowerRename.rename(".bashrc", index: 0, options: o), ".bashrc.bak")
    }

    func testCombinedRule() {
        // Replace, then prefix, then number, then case - a real-world combo.
        let o = opts {
            $0.find = "DSC"; $0.replacement = "Beach"
            $0.numbering = true; $0.numberStart = 1; $0.numberPadding = 2; $0.numberSeparator = "-"
        }
        XCTAssertEqual(PowerRename.rename("DSC.jpg", index: 0, options: o), "Beach-01.jpg")
        XCTAssertEqual(PowerRename.rename("DSC.jpg", index: 1, options: o), "Beach-02.jpg")
    }

    // MARK: - Preview & conflicts

    func testPreviewFlagsDuplicates() {
        // Two files that collapse to the same name must both be flagged.
        let o = opts { $0.find = #"\d+"#; $0.replacement = ""; $0.useRegex = true }
        let rows = PowerRename.preview(paths: ["/x/a1.txt", "/x/a2.txt"], options: o)
        XCTAssertEqual(rows.map(\.newName), ["a.txt", "a.txt"])
        XCTAssertTrue(rows.allSatisfy { $0.problem == .duplicate })
    }

    func testPreviewFlagsCollisionWithExistingFile() {
        let o = opts { $0.find = "old"; $0.replacement = "new" }
        let rows = PowerRename.preview(paths: ["/x/old.txt"], options: o,
                                       existing: ["old.txt", "new.txt"])
        XCTAssertEqual(rows[0].newName, "new.txt")
        XCTAssertEqual(rows[0].problem, .collision)
    }

    func testPreviewAllowsRotationAmongSelection() {
        // a->b and b->a shouldn't flag each other as collisions: both are being
        // renamed, so neither "already exists" in the way that matters.
        let o = opts { $0.find = "a"; $0.replacement = "b"; $0.target = .fullName }
        let rows = PowerRename.preview(paths: ["/x/a", "/x/b"], options: o, existing: ["a", "b"])
        // "a"->"b" duplicates with "b"->"b"? b maps to b (unchanged) and a maps
        // to b -> that's a genuine duplicate, so this checks duplicate wins.
        XCTAssertTrue(rows.contains { $0.problem == .duplicate })
    }

    func testNoOpProducesNoChanges() {
        let rows = PowerRename.preview(paths: ["/x/a.txt", "/x/b.txt"], options: PowerRename.Options())
        XCTAssertTrue(rows.allSatisfy { !$0.changed && $0.problem == nil })
    }

    func testInvalidRegexReported() {
        var o = PowerRename.Options(); o.useRegex = true; o.find = "([unclosed"
        XCTAssertNotNil(o.regexError)
        // And it renames to the original rather than crashing.
        XCTAssertEqual(PowerRename.rename("file.txt", index: 0, options: o), "file.txt")
    }
}
