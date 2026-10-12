import XCTest
@testable import MSLApp
@testable import MSLCore

/// The `visibleItems` memoization is a cache, and a cache that doesn't
/// invalidate is a correctness bug, not just a perf one. These pin the
/// invalidation: every input that changes the output must change the output.
@MainActor
final class FilesVisibleItemsMemoTests: XCTestCase {
    private func model(with names: [String]) -> FilesModel {
        let model = FilesModel()
        model.items = names.map {
            MSLFileItem(path: "/x/\($0)", name: $0, isDirectory: false, size: UInt64($0.count),
                        modified: Date())
        }
        return model
    }

    func testHiddenToggleInvalidates() {
        let model = model(with: ["a", ".b", "c"])
        // Order is the sort test's job; here only the membership matters, and
        // the machine's persisted default sort direction must not sway it.
        model.showHidden = false
        XCTAssertEqual(Set(model.visibleItems.map(\.name)), ["a", "c"])
        // Same array read twice is the cache hit path - still correct.
        XCTAssertEqual(Set(model.visibleItems.map(\.name)), ["a", "c"])
        model.showHidden = true
        XCTAssertEqual(Set(model.visibleItems.map(\.name)), [".b", "a", "c"])
    }

    func testSearchInvalidates() {
        let model = model(with: ["apple", "banana", "apricot"])
        XCTAssertEqual(model.visibleItems.count, 3)
        model.search = "ap"
        XCTAssertEqual(Set(model.visibleItems.map(\.name)), ["apple", "apricot"])
        model.search = ""
        XCTAssertEqual(model.visibleItems.count, 3)
    }

    func testSortDirectionInvalidates() {
        let model = model(with: ["a", "b", "c"])
        model.sortKey = .name
        model.sortAscending = true
        XCTAssertEqual(model.visibleItems.map(\.name), ["a", "b", "c"])
        model.sortAscending = false
        XCTAssertEqual(model.visibleItems.map(\.name), ["c", "b", "a"])
    }

    func testNewListingInvalidates() {
        let model = model(with: ["a", "b"])
        XCTAssertEqual(model.visibleItems.count, 2)
        model.items = [MSLFileItem(path: "/x/z", name: "z", isDirectory: false, size: 1, modified: Date())]
        XCTAssertEqual(model.visibleItems.map(\.name), ["z"])
    }
}

/// Selection now lives in the model for every view mode, so the arrow keys and
/// clicks share one implementation - pinned here.
@MainActor
final class FilesSelectionTests: XCTestCase {
    private func model() -> FilesModel {
        let model = FilesModel()
        model.sortKey = .name
        model.sortAscending = true
        model.items = ["a", "b", "c", "d"].map {
            MSLFileItem(path: "/x/\($0)", name: $0, isDirectory: false, size: 1, modified: Date())
        }
        return model
    }

    func testArrowsMoveFromTheLastClick() {
        let m = model()
        m.handleTap(on: m.visibleItems[1], modifiers: [])     // b
        m.moveSelection(by: 1, extend: false)
        XCTAssertEqual(m.selection, ["/x/c"])
        m.moveSelection(by: -2, extend: false)
        XCTAssertEqual(m.selection, ["/x/a"])
        m.moveSelection(by: -1, extend: false)                // clamps at the top
        XCTAssertEqual(m.selection, ["/x/a"])
    }

    func testShiftArrowExtendsFromTheAnchor() {
        let m = model()
        m.handleTap(on: m.visibleItems[1], modifiers: [])     // anchor b
        m.moveSelection(by: 1, extend: true)
        m.moveSelection(by: 1, extend: true)
        XCTAssertEqual(m.selection, ["/x/b", "/x/c", "/x/d"])
    }

    func testCommandClickTogglesAndShiftClickRanges() {
        let m = model()
        m.handleTap(on: m.visibleItems[0], modifiers: [])
        m.handleTap(on: m.visibleItems[2], modifiers: .command)
        XCTAssertEqual(m.selection, ["/x/a", "/x/c"])
        m.handleTap(on: m.visibleItems[2], modifiers: .command)
        XCTAssertEqual(m.selection, ["/x/a"])
        // ⌘-picked items survive a shift range from the anchor (c).
        m.handleTap(on: m.visibleItems[3], modifiers: .shift)
        XCTAssertEqual(m.selection, ["/x/a", "/x/c", "/x/d"])
    }

    func testShiftClickBackTowardTheAnchorShrinks() {
        let m = model()
        m.handleTap(on: m.visibleItems[0], modifiers: [])
        m.handleTap(on: m.visibleItems[3], modifiers: .shift)
        XCTAssertEqual(m.selection.count, 4)
        m.handleTap(on: m.visibleItems[1], modifiers: .shift)
        XCTAssertEqual(m.selection, ["/x/a", "/x/b"])
    }

    func testFirstArrowWithNothingSelectedPicksAnEnd() {
        let m = model()
        m.moveSelection(by: 1, extend: false)
        XCTAssertEqual(m.selection, ["/x/a"])
    }
}

/// `FolderStats` is what the Quick Look peek shows for a folder. Counted
/// against a real temp directory, since that's what it lists.
final class FolderStatsTests: XCTestCase {
    func testCountsImmediateChildren() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-folderstats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(count: 100).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 200).write(to: dir.appendingPathComponent("b.bin"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)

        let provider = LocalFileProvider(displayName: "t", rootPath: dir.path)
        let stats = await FolderStats.load(dir.path, provider: provider)
        XCTAssertEqual(stats.folders, 1)
        XCTAssertEqual(stats.files, 2)
        XCTAssertEqual(stats.totalSize, 300)
        XCTAssertEqual(stats.containsLine, "1 folder, 2 files")
    }
}

/// The marquee's Finder rules: plain replaces, ⇧ adds, ⌘ toggles.
final class MarqueeRuleTests: XCTestCase {
    private let base: Set<String> = ["a", "b"]
    private let hits: Set<String> = ["b", "c"]

    func testModifiersPickTheRule() {
        XCTAssertEqual(MarqueeRule(modifiers: []), .replace)
        XCTAssertEqual(MarqueeRule(modifiers: .shift), .add)
        XCTAssertEqual(MarqueeRule(modifiers: .command), .toggle)
        XCTAssertEqual(MarqueeRule(modifiers: [.command, .shift]), .toggle)
    }

    func testReplaceIsJustTheHits() {
        XCTAssertEqual(MarqueeRule.replace.combine(base: base, hits: hits), ["b", "c"])
    }

    func testAddUnions() {
        XCTAssertEqual(MarqueeRule.add.combine(base: base, hits: hits), ["a", "b", "c"])
    }

    func testToggleFlipsCoveredItems() {
        XCTAssertEqual(MarqueeRule.toggle.combine(base: base, hits: hits), ["a", "c"])
    }

    func testShrinkingTheRectangleGivesItemsBack() {
        // Recomputed from the base every update, so dragging back over an item
        // un-selects it again rather than leaving it stuck on.
        XCTAssertEqual(MarqueeRule.replace.combine(base: [], hits: ["a"]), ["a"])
        XCTAssertEqual(MarqueeRule.replace.combine(base: [], hits: []), [])
    }
}
