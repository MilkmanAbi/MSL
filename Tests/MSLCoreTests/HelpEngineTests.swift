import XCTest
@testable import MSLCore

/// The markup parser and the search index, against small fixtures. What the
/// real guide says is checked separately, in `HelpGuideTests`.
final class HelpEngineTests: XCTestCase {
    // MARK: - Blocks

    func testParagraphLinesJoinAndBlankLinesSplit() {
        let doc = HelpMarkup.parse("""
        one
        two

        three
        """)
        XCTAssertEqual(doc.blocks, [.paragraph("one two"), .paragraph("three")])
    }

    func testHeadingsGetUniqueAnchors() {
        let doc = HelpMarkup.parse("""
        ## Memory & CPU
        ### Memory & CPU
        ## Pinned {#my-anchor}
        """)
        XCTAssertEqual(doc.blocks, [
            .heading(level: 2, text: "Memory & CPU", anchor: "memory-cpu"),
            .heading(level: 3, text: "Memory & CPU", anchor: "memory-cpu-2"),
            .heading(level: 2, text: "Pinned", anchor: "my-anchor"),
        ])
    }

    func testCalloutKindTitleAndParagraphs() {
        let doc = HelpMarkup.parse("""
        > [!WARNING] Careful now
        > first line
        > continues
        >
        > second paragraph
        """)
        XCTAssertEqual(doc.blocks, [.callout(kind: .warning, title: "Careful now",
                                             text: "first line continues\n\nsecond paragraph")])
    }

    func testBulletsInsideACalloutStayBullets() {
        let doc = HelpMarkup.parse("""
        > [!WARNING]
        > Do one of these:
        >
        > - first way
        > - second way,
        >   continued
        """)
        XCTAssertEqual(doc.blocks, [.callout(kind: .warning, title: nil,
                                             text: "Do one of these:\n\n• first way\n\n• second way, continued")])
    }

    func testSectionTextLeavesTheHeadingToItsOwnField() {
        let doc = HelpMarkup.parse("## Shut Down\nIt stops at once.")
        XCTAssertEqual(doc.sections.first?.text, "It stops at once.")
    }

    func testEveryMatchingFormIsHighlighted() {
        let index = HelpSearchIndex(chapters: [
            HelpChapter(id: "c", title: "C", symbol: "x", tint: .gray, blurb: "", articles: [
                HelpArticle(id: "a", title: "Stopping", symbol: "x", summary: "Stopping.",
                            body: "## Shut down\nRun sudo poweroff first."),
            ]),
        ])
        let terms = index.search("poweroff").first?.highlightTerms ?? []
        XCTAssertTrue(terms.contains("poweroff"), "\(terms)")
    }

    func testCalloutWithoutAKindIsANote() {
        XCTAssertEqual(HelpMarkup.parse("> just a note").blocks,
                       [.callout(kind: .note, title: nil, text: "just a note")])
    }

    func testListsJoinIndentedContinuations() {
        let doc = HelpMarkup.parse("""
        - first
          still first
        - second
        1. step one
        2. step two
          more of two
        """)
        XCTAssertEqual(doc.blocks, [
            .bullets(["first still first", "second"]),
            .steps(["step one", "step two more of two"]),
        ])
    }

    func testCodeIsVerbatim() {
        let doc = HelpMarkup.parse("""
        ```shell
        - not a bullet
        ## not a heading
          indented
        ```
        after
        """)
        XCTAssertEqual(doc.blocks, [
            .code(label: "shell", text: "- not a bullet\n## not a heading\n  indented"),
            .paragraph("after"),
        ])
    }

    func testTableWithHeaderAndEscapedBar() {
        let doc = HelpMarkup.parse("""
        | Key | Meaning |
        |---|:--:|
        | a \\| b | c |
        """)
        XCTAssertEqual(doc.blocks, [.table(header: ["Key", "Meaning"], rows: [["a | b", "c"]])])
    }

    func testShortcutsAndFeatures() {
        let doc = HelpMarkup.parse("""
        @keys ⌘N | New Instance
        @keys ⌥⌘F | MSL Files
        @card sparkles melon | Title | Some text | with a bar
        """)
        XCTAssertEqual(doc.blocks, [
            .shortcuts([HelpShortcut(keys: "⌘N", action: "New Instance"),
                        HelpShortcut(keys: "⌥⌘F", action: "MSL Files")]),
            .features([HelpFeature(symbol: "sparkles", tint: .melon, title: "Title", text: "Some text | with a bar")]),
        ])
    }

    func testDividerAndStepsNeedASpaceAfterTheDot() {
        let doc = HelpMarkup.parse("""
        ---
        3.5 GB is a number, not a step.
        """)
        XCTAssertEqual(doc.blocks, [.divider, .paragraph("3.5 GB is a number, not a step.")])
    }

    // MARK: - Sections

    func testSectionsSplitAtHeadingsAndCarryPlainText() {
        let doc = HelpMarkup.parse("""
        Intro with **bold** and a [link](help:other#x).

        ## First
        Body `code`.
        > [!TIP] Tip title
        > tip text

        ### Deeper
        ```
        msl doctor
        ```
        """)
        XCTAssertEqual(doc.sections.map(\.anchor), ["", "first", "deeper"])
        XCTAssertEqual(doc.sections[0].text, "Intro with bold and a link.")
        XCTAssertTrue(doc.sections[1].text.contains("Tip title"))
        XCTAssertTrue(doc.sections[1].text.contains("tip text"))
        XCTAssertTrue(doc.sections[2].text.contains("msl doctor"))
        XCTAssertEqual(doc.outline.map(\.title), ["First", "Deeper"])
    }

    func testAnArticleOpeningWithAHeadingHasNoEmptyTopSection() {
        let doc = HelpMarkup.parse("## Straight in\ntext")
        XCTAssertEqual(doc.sections.map(\.anchor), ["straight-in"])
    }

    // MARK: - Links

    func testHelpLinksParseAndRoundTrip() {
        XCTAssertEqual(HelpLink(string: "help:memory#dynamic"), HelpLink(article: "memory", anchor: "dynamic"))
        XCTAssertEqual(HelpLink(string: "help:memory"), HelpLink(article: "memory"))
        XCTAssertNil(HelpLink(string: "https://example.com"))
        XCTAssertNil(HelpLink(string: "help:"))
        let link = HelpLink(article: "a", anchor: "b")
        XCTAssertEqual(HelpLink(url: link.url), link)
        XCTAssertEqual(HelpLink.links(in: "see [x](help:a#b) and [y](https://z) and [w](help:c)"),
                       [HelpLink(article: "a", anchor: "b"), HelpLink(article: "c")])
    }

    // MARK: - Emoji

    func testKaomojiAreNotEmoji() {
        for face in ["(｡•̀ᴗ-)✧", "( ˘•ω•˘ )", "٩(ˊᗜˋ*)و", "♡", "(╯°□°)╯︵ ┻━┻", "⌘⇧⌥⌃", "#1 * 2"] {
            XCTAssertEqual(EmojiCheck.emoji(in: face), [], face)
        }
    }

    func testEmojiAreCaught() {
        for emoji in ["\u{1F349}", "\u{2728}", "\u{2764}\u{FE0F}", "\u{1F44D}\u{1F3FD}"] {
            XCTAssertFalse(EmojiCheck.emoji(in: "text \(emoji) text").isEmpty, emoji)
        }
    }

    // MARK: - Search

    private lazy var index = HelpSearchIndex(chapters: [
        HelpChapter(id: "c", title: "Chapter", symbol: "x", tint: .melon, blurb: "", articles: [
            HelpArticle(id: "memory", title: "Memory", symbol: "memorychip",
                        summary: "How much memory an instance gets.", keywords: ["ballooning"], body: """
                        Instances get memory from your Mac.

                        ## Dynamic mode
                        The instance starts at its maximum and gives memory back.

                        ## Manual mode
                        A fixed amount.
                        """),
            HelpArticle(id: "snapshots", title: "Snapshots", symbol: "clock",
                        summary: "Save and restore the whole machine.", body: """
                        A snapshot saves memory and disk together.

                        ## Restoring
                        Restoring discards everything since the snapshot.
                        """),
            HelpArticle(id: "disk", title: "Repairing a disk", symbol: "internaldrive",
                        summary: "Check and repair the filesystem.", body: """
                        Repair Disk runs a filesystem check and fixes what it finds.
                        """),
        ]),
    ])

    func testEmptyAndStopWordOnlyQueries() {
        XCTAssertEqual(index.search(""), [])
        XCTAssertEqual(index.search("   "), [])
    }

    func testTitleOutranksBodyMention() {
        let results = index.search("snapshot")
        XCTAssertEqual(results.first?.articleID, "snapshots")
    }

    func testLandsOnTheSectionThatAnswers() {
        let result = index.search("dynamic").first
        XCTAssertEqual(result?.articleID, "memory")
        XCTAssertEqual(result?.anchor, "dynamic-mode")
    }

    func testSynonymsFindTheGuidesOwnWord() {
        let result = index.search("ram").first
        XCTAssertEqual(result?.articleID, "memory")
        XCTAssertTrue(result?.highlightTerms.contains("memory") ?? false)
        XCTAssertEqual(index.search("fsck").first?.articleID, "disk")
    }

    func testPrefixesMatchAsYouType() {
        XCTAssertEqual(index.search("snaps").first?.articleID, "snapshots")
        XCTAssertEqual(index.search("restor").first?.anchor, "restoring")
    }

    func testStemmingMatchesOtherForms() {
        XCTAssertEqual(index.search("restores").first?.anchor, "restoring")
        XCTAssertEqual(index.search("repairing").first?.articleID, "disk")
    }

    func testEveryWordMustMatchWhenSomethingMatchesThemAll() {
        let results = index.search("memory restoring")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.articleID == "snapshots" }, "\(results.map(\.id))")
    }

    func testTyposFallBackToFuzzy() {
        XCTAssertEqual(index.search("snapshto").first?.articleID, "snapshots")
        XCTAssertEqual(index.search("memroy").first?.articleID, "memory")
    }

    func testGibberishFindsNothing() {
        XCTAssertEqual(index.search("zzqqxx"), [])
    }

    func testSnippetShowsTheMatchingSentence() {
        let snippet = index.search("discards").first?.snippet ?? ""
        XCTAssertTrue(snippet.contains("discards everything"), snippet)
    }

    func testSnippetsMatchWordStartsAndDropStrayQuotes() {
        XCTAssertNil(HelpSearchIndex.wordStartRange(of: "ram", in: "the framework"))
        XCTAssertNotNil(HelpSearchIndex.wordStartRange(of: "ram", in: "the framework uses RAM"))
        XCTAssertNotNil(HelpSearchIndex.wordStartRange(of: "mem", in: "memory"))
        let snippet = HelpSearchIndex.snippet(
            from: "It says \"It will still start.\" Red: numbers that can't work need more RAM.",
            highlighting: ["ram"])
        XCTAssertEqual(snippet, "Red: numbers that can't work need more RAM.")
    }

    func testStemmer() {
        XCTAssertEqual(HelpSearchIndex.stem("snapshots"), "snapshot")
        XCTAssertEqual(HelpSearchIndex.stem("running"), "run")
        XCTAssertEqual(HelpSearchIndex.stem("stopped"), "stop")
        XCTAssertEqual(HelpSearchIndex.stem("boxes"), "box")
        XCTAssertEqual(HelpSearchIndex.stem("libraries"), "library")
        XCTAssertEqual(HelpSearchIndex.stem("status"), "status")
        XCTAssertEqual(HelpSearchIndex.stem("access"), "access")
        XCTAssertEqual(HelpSearchIndex.stem("disk"), "disk")
        XCTAssertEqual(HelpSearchIndex.stem("restore"), HelpSearchIndex.stem("restoring"))
        XCTAssertEqual(HelpSearchIndex.stem("restores"), HelpSearchIndex.stem("restored"))
        XCTAssertEqual(HelpSearchIndex.stem("remove"), HelpSearchIndex.stem("removing"))
    }

    func testEditDistance() {
        XCTAssertEqual(HelpSearchIndex.editDistance("memroy", "memory", limit: 1), 1, "a swap is one slip")
        XCTAssertEqual(HelpSearchIndex.editDistance("snapshto", "snapshot", limit: 1), 1)
        XCTAssertEqual(HelpSearchIndex.editDistance("kitten", "sitting", limit: 3), 3)
        XCTAssertEqual(HelpSearchIndex.editDistance("snapshot", "snapshot", limit: 1), 0)
        XCTAssertNil(HelpSearchIndex.editDistance("apple", "zebra", limit: 1))
    }
}
