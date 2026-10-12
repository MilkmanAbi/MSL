import AppKit
import XCTest
@testable import MSLCore

/// The badge an instance wears. Every test works in its own temporary
/// directory - a test that wrote to the real Application Support once cost
/// this project a user's `default-users.json` (2026-09-29).
final class InstanceAppearanceTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: - Nothing until something is chosen

    func testNoFileOnAMacWhereNobodyTouchedALogo() {
        XCTAssertEqual(InstanceAppearanceStore.of("work", appSupport: support),
                       InstanceAppearance())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.url(appSupport: support).path))
    }

    func testStoresAndReadsBack() {
        let wanted = InstanceAppearance(symbol: "flag.fill", tint: "#0090FF")
        XCTAssertTrue(InstanceAppearanceStore.set(wanted, for: "work", appSupport: support))
        XCTAssertEqual(InstanceAppearanceStore.of("work", appSupport: support), wanted)
    }

    func testInstancesDoNotShareABadge() {
        InstanceAppearanceStore.set(.init(symbol: "flag.fill"), for: "work", appSupport: support)
        InstanceAppearanceStore.set(.init(symbol: "crown.fill"), for: "play", appSupport: support)
        XCTAssertEqual(InstanceAppearanceStore.of("work", appSupport: support).symbol, "flag.fill")
        XCTAssertEqual(InstanceAppearanceStore.of("play", appSupport: support).symbol, "crown.fill")
    }

    /// Resetting to the default removes the entry rather than storing an
    /// empty one, and the last entry going takes the file with it.
    func testResettingRemovesTheEntryAndThenTheFile() {
        InstanceAppearanceStore.set(.init(symbol: "flag.fill"), for: "work", appSupport: support)
        InstanceAppearanceStore.set(InstanceAppearance(), for: "work", appSupport: support)
        XCTAssertTrue(InstanceAppearanceStore.of("work", appSupport: support).isDefault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.url(appSupport: support).path))
    }

    func testResettingOneLeavesTheOthers() {
        InstanceAppearanceStore.set(.init(symbol: "flag.fill"), for: "work", appSupport: support)
        InstanceAppearanceStore.set(.init(symbol: "crown.fill"), for: "play", appSupport: support)
        InstanceAppearanceStore.set(InstanceAppearance(), for: "work", appSupport: support)
        XCTAssertTrue(InstanceAppearanceStore.of("work", appSupport: support).isDefault)
        XCTAssertEqual(InstanceAppearanceStore.of("play", appSupport: support).symbol, "crown.fill")
    }

    /// A new instance given a deleted one's name must not inherit its badge -
    /// the rule `LinuxAppCatalog.forget` exists for.
    func testForgetDropsEverythingIncludingThePicture() throws {
        let file = try importSquare(named: "work")
        InstanceAppearanceStore.set(.init(symbol: "flag.fill", image: file),
                                    for: "work", appSupport: support)
        InstanceAppearanceStore.forget(instance: "work", appSupport: support)
        XCTAssertTrue(InstanceAppearanceStore.of("work", appSupport: support).isDefault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.imageURL(file, appSupport: support).path))
    }

    func testForgetLeavesTheOthersAlone() {
        InstanceAppearanceStore.set(.init(symbol: "crown.fill"), for: "play", appSupport: support)
        InstanceAppearanceStore.forget(instance: "work", appSupport: support)
        XCTAssertEqual(InstanceAppearanceStore.of("play", appSupport: support).symbol, "crown.fill")
    }

    // MARK: - Pictures

    /// Writes a 400x200 PNG and imports it, returning the stored file name.
    private func importSquare(named instance: String) throws -> String {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw XCTSkip("couldn't make a test image") }
        let source = support.appendingPathComponent("source-\(instance).png")
        try png.write(to: source)
        return try InstanceAppearanceStore.importImage(from: source, for: instance, appSupport: support)
    }

    /// Re-encoded rather than copied: the badge is 44 points at most, so a
    /// 12-megapixel photo would cost memory on every row draw for detail
    /// nobody can see.
    func testImportedPictureIsSquaredAndScaled() throws {
        let file = try importSquare(named: "work")
        let stored = InstanceAppearanceStore.imageURL(file, appSupport: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        let image = try XCTUnwrap(NSImage(contentsOf: stored))
        XCTAssertEqual(image.size.width, 256, accuracy: 1)
        XCTAssertEqual(image.size.height, 256, accuracy: 1)
    }

    /// The file name is MSL's, inside its own folder - a path into the user's
    /// own folders would leave a blank badge the first time they moved it.
    func testPictureIsStoredByNameNotPath() throws {
        let file = try importSquare(named: "work")
        XCTAssertFalse(file.contains("/"))
        XCTAssertTrue(file.hasPrefix("work-"))
        XCTAssertTrue(file.hasSuffix(".png"))
    }

    /// Replacing a picture deletes the one it replaced, or every change
    /// leaves a file behind forever.
    func testReplacingAPictureDeletesTheOldFile() throws {
        let first = try importSquare(named: "work")
        InstanceAppearanceStore.set(.init(image: first), for: "work", appSupport: support)
        let second = try importSquare(named: "work")
        XCTAssertNotEqual(first, second)
        InstanceAppearanceStore.set(.init(image: second), for: "work", appSupport: support)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.imageURL(first, appSupport: support).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.imageURL(second, appSupport: support).path))
    }

    func testClearingThePictureDeletesIt() throws {
        let file = try importSquare(named: "work")
        InstanceAppearanceStore.set(.init(symbol: "flag.fill", image: file),
                                    for: "work", appSupport: support)
        InstanceAppearanceStore.set(.init(symbol: "flag.fill"), for: "work", appSupport: support)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceAppearanceStore.imageURL(file, appSupport: support).path))
        XCTAssertEqual(InstanceAppearanceStore.of("work", appSupport: support).symbol, "flag.fill")
    }

    func testSomethingThatIsNotAnImageIsRefused() throws {
        let source = support.appendingPathComponent("notes.txt")
        try "not a picture".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try InstanceAppearanceStore.importImage(from: source, for: "work", appSupport: support))
    }

    // MARK: - The palette

    /// The picker's symbols have to be real SF Symbols, or a faction is an
    /// empty square.
    func testEveryFactionSymbolResolves() {
        for faction in InstanceAppearance.factions {
            for symbol in faction.symbols {
                XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                                "\(faction.name): \(symbol) isn't an SF Symbol")
            }
        }
    }

    func testNoSymbolIsOfferedTwice() {
        let all = InstanceAppearance.factions.flatMap(\.symbols)
        XCTAssertEqual(Set(all).count, all.count, "a symbol appears in two factions")
    }

    func testPaletteIsWellFormed() {
        XCTAssertEqual(Set(InstanceAppearance.palette).count, InstanceAppearance.palette.count)
        for hex in InstanceAppearance.palette {
            XCTAssertEqual(hex.count, 7, hex)
            XCTAssertTrue(hex.hasPrefix("#"), hex)
            XCTAssertNotNil(UInt32(hex.dropFirst(), radix: 16), hex)
        }
    }

    /// A hand-edited file shouldn't be able to make a badge draw nothing.
    func testUnknownSymbolIsNotClaimedAsKnown() {
        XCTAssertFalse(InstanceAppearance.isKnownSymbol("not.a.symbol"))
        XCTAssertTrue(InstanceAppearance.isKnownSymbol("flag.fill"))
    }

    func testGarbageInTheFileReadsAsTheDefault() throws {
        try "{ not json".write(to: InstanceAppearanceStore.url(appSupport: support),
                              atomically: true, encoding: .utf8)
        XCTAssertTrue(InstanceAppearanceStore.of("work", appSupport: support).isDefault)
    }
}
