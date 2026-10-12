import XCTest
@testable import MSLCore

/// The cat sits at the top of a shell with the greeting under her. These pin
/// the four combinations, and the bubble alignment that `msl kitty "words"`
/// still depends on - a speech bubble whose right border does not line up is
/// the one defect that makes the whole thing look broken, and the greetings
/// are full of full-width kaomoji that `String.count` measures wrongly.
final class PersonalityBannerTests: XCTestCase {

    private let line = "oh. you're back. w-whatever. it was going to boot anyway."

    // MARK: - The four cases

    func testBothOnPutsTheCatAboveTheLine() {
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: true), greeting: line)
        guard let banner else { return XCTFail("expected a banner") }
        XCTAssertTrue(banner.hasPrefix(Kitty.art), "the cat comes first")
        XCTAssertTrue(banner.hasSuffix(line), "and the greeting is tucked under her")
        // No bubble: that belongs to `msl kitty "words"`, not to the banner.
        XCTAssertFalse(banner.contains("___"), "the banner is not a cowsay")
        XCTAssertEqual(banner.split(separator: "\n").count,
                       Kitty.art.split(separator: "\n").count + 1,
                       "exactly one line added under her")
    }

    func testTheCatOffLeavesTheLineAlone() {
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: false), greeting: line)
        XCTAssertEqual(banner, line, "no bubble, no cat - exactly what it used to be")
    }

    func testTheLineSitsDirectlyUnderHerLastPaw() {
        // No blank line between: she is saying it, not introducing it.
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: true), greeting: line)
        let rows = banner?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        XCTAssertEqual(rows.dropLast().last.map(String.init), "　＼二つ")
        XCTAssertEqual(rows.last.map(String.init), line)
    }

    func testTheGreetingOffLeavesJustTheCat() {
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: false, kitty: true), greeting: line)
        XCTAssertEqual(banner, Kitty.art)
        XCTAssertFalse(banner?.contains("you're back") ?? true, "a silenced greeting must not leak")
    }

    func testBothOffIsNothingAtAll() {
        XCTAssertNil(PersonalityBanner.render(
            settings: PersonalitySettings(greeters: false, kitty: false), greeting: line))
        // And with no greeting to show either way.
        XCTAssertNil(PersonalityBanner.render(
            settings: PersonalitySettings(greeters: false, kitty: false), greeting: nil))
    }

    func testTheGreetingOnButAbsentStillShowsTheCat() {
        // `Greeter.nextGreeting()` is optional; a nil must not produce an
        // empty speech bubble over her head.
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: true), greeting: nil)
        XCTAssertEqual(banner, Kitty.art)
    }

    func testANarrowTerminalGetsTheLineInsteadOfAWrappedCat() {
        // A cat folded in half by the terminal is worse than no cat.
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: true), greeting: line, columns: 12)
        XCTAssertEqual(banner, line)
    }

    func testAnUnknownWidthIsNotTreatedAsNarrow() {
        // `ioctl(TIOCGWINSZ)` fails on a pipe and leaves the width at zero.
        // Reading that as a nought-column terminal dropped the cat from
        // everything that was not a tty - including `msl greeter | less`.
        let banner = PersonalityBanner.render(
            settings: PersonalitySettings(greeters: true, kitty: true), greeting: line, columns: 0)
        XCTAssertTrue(banner?.hasPrefix(Kitty.art) ?? false, "zero columns means unknown, not narrow")
    }

    func testANarrowTerminalWithNoGreetingShowsNothingRatherThanAWrappedCat() {
        XCTAssertNil(PersonalityBanner.render(
            settings: PersonalitySettings(greeters: false, kitty: true), greeting: line, columns: 12))
    }

    // MARK: - Alignment, which is the part that shows

    /// Checks a bubble is square.
    ///
    /// cowsay's geometry, which the bars do not share with the text rows:
    ///
    /// ```
    ///  _____        <- bar: a leading space then width+2 underscores
    /// < moo >       <- text: "< ", width, " >"
    ///  -----        <- bar
    /// ```
    ///
    /// So every *text* row must be the same width as every other, and each
    /// bar is exactly one column shorter. Asserting all of them were equal
    /// would be asserting a bubble that is not a bubble.
    private func assertAligned(_ rendered: String, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        // The bubble ends at the tail that points down at the cat.
        let bubble = rendered.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "\\" } }
        let isBar = { (row: Substring) in
            row.allSatisfy { $0 == " " || $0 == "_" || $0 == "-" }
        }
        let bars = bubble.filter(isBar)
        let rows = bubble.filter { !isBar($0) }

        XCTAssertEqual(bars.count, 2, "\(message): expected a top and a bottom bar", file: file, line: line)
        XCTAssertFalse(rows.isEmpty, "\(message): expected at least one line of text", file: file, line: line)

        let rowWidths = Set(rows.map { DisplayWidth.columns(of: $0) })
        XCTAssertEqual(rowWidths.count, 1,
                       "\(message): text rows have widths \(rowWidths.sorted()) - the right border is ragged",
                       file: file, line: line)
        guard let width = rowWidths.first else { return }
        for bar in bars {
            XCTAssertEqual(DisplayWidth.columns(of: bar), width - 1,
                           "\(message): a bar is \(DisplayWidth.columns(of: bar)) wide, text rows are \(width)",
                           file: file, line: line)
        }
    }

    func testEveryRealGreetingMakesASquareBubble() {
        // The whole catalogue, not a sample: the misaligned ones are exactly
        // the ones with kaomoji, and which those are changes as greetings
        // are added.
        for greeting in Greeter.all {
            assertAligned(Kitty.say(greeting.text), greeting.text)
        }
    }

    func testFullWidthTextIsMeasuredInColumns() {
        // `＿` is two columns wide and one grapheme. Measuring by `count`
        // under-pads the border by one column per character.
        XCTAssertEqual(DisplayWidth.columns(of: "＿＿"), 4)
        XCTAssertEqual("＿＿".count, 2)
        assertAligned(Kitty.say("＿＿＿ hello ＿＿＿"), "full-width padding")
    }

    func testCombiningMarksTakeNoColumns() {
        // `e` + combining acute is two scalars, one column.
        XCTAssertEqual(DisplayWidth.columns(of: "e\u{0301}"), 1)
        // A variation selector is not drawn at all.
        XCTAssertEqual(DisplayWidth.columns(of: "\u{FE0F}"), 0)
    }

    func testAmbiguousWidthCharactersCountAsOne() {
        // Terminal.app and SwiftTerm both draw these in one cell; treating
        // them as two would over-pad every bubble that has a heart in it.
        for text in ["•", "♡", "˘", "✧"] {
            XCTAssertEqual(DisplayWidth.columns(of: text), 1, "\(text) should be one column")
        }
    }

    // MARK: - The faces survive wrapping

    func testKaomojiAreNotBrokenAcrossLines() {
        // `( ˘︹˘ )` has spaces inside it. Split across two bubble lines it
        // stops being a face and becomes punctuation.
        let faces = ["( ˘︹˘ )", "(⁄ ⁄•⁄ω⁄•⁄ ⁄)", "(￣^￣)ゞ"]
        for face in faces {
            let text = String(repeating: "word ", count: 7) + face
            let lines = Kitty.wrap(text)
            XCTAssertTrue(lines.contains { $0.contains(face) },
                          "\(face) was broken up into \(lines)")
        }
    }

    func testAVeryLongWordDoesNotLoop() {
        let lines = Kitty.wrap(String(repeating: "x", count: 200))
        XCTAssertEqual(lines.count, 1, "an unbreakable word stays one line rather than hanging")
    }

    func testEmptyTextStillMakesABubble() {
        assertAligned(Kitty.say(""), "empty")
    }

    // MARK: - The art

    func testTheArtIsTheCatFromTheFile() {
        // Ten lines, and the paw at the bottom - a sanity check that nobody
        // has reflowed her in an editor.
        XCTAssertEqual(Kitty.art.split(separator: "\n").count, 10)
        XCTAssertTrue(Kitty.art.hasSuffix("＼二つ"))
        XCTAssertTrue(Kitty.art.contains("🌸"))
    }

    func testHerEarsSitOverHerHead() {
        // The ears are drawn on their own line, so nothing but this keeps
        // them lined up with the head below - and they were one column left
        // of where they should be.
        let rows = Kitty.art.split(separator: "\n").map(String.init)
        func indent(_ row: String) -> Int {
            DisplayWidth.columns(of: row.prefix { $0 == " " || $0 == "\u{3000}" })
        }
        XCTAssertEqual(indent(rows[0]), 14, "the ears")
        XCTAssertEqual(indent(rows[1]), 11, "the flower and the face")
    }

    func testTheArtsWidthIsWhatTheNarrowTerminalCheckUses() {
        // If these disagree, the fallback either triggers too early or lets
        // her wrap after all.
        XCTAssertEqual(Kitty.artColumns,
                       Kitty.art.split(separator: "\n")
                           .map { DisplayWidth.columns(of: $0) }.max())
        XCTAssertGreaterThan(Kitty.artColumns, 10)
    }
}
