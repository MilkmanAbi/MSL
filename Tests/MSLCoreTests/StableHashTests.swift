import XCTest
@testable import MSLCore

final class StableHashTests: XCTestCase {
    /// The whole point of the type. `Hasher` would pass this within one
    /// process and fail across launches, so the constant is written out
    /// literally - if the algorithm ever changes, every contributor's colour
    /// changes with it, and this test is what makes that a deliberate act.
    func testValueIsAStableConstant() {
        // FNV-1a's published 64-bit test vectors. These caught a real bug:
        // the first draft used FNV's *32-bit* prime with the 64-bit offset
        // basis, which is a perfectly stable hash but not the one the doc
        // comment claimed, and nothing else here would have noticed.
        XCTAssertEqual(StableHash.value(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.value("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.value("foobar"), 0x85944171f73967e8)
    }

    func testSameStringAlwaysGivesTheSameIndex() {
        for _ in 0..<100 {
            XCTAssertEqual(StableHash.index(for: "MilkmanAbi", modulo: 7),
                           StableHash.index(for: "MilkmanAbi", modulo: 7))
        }
    }

    func testIndexStaysInRange() {
        for name in ["a", "MilkmanAbi", "neekocat_2025", "", "ünïcödé", String(repeating: "x", count: 500)] {
            for count in 1...9 {
                let index = StableHash.index(for: name, modulo: count)
                XCTAssertTrue((0..<count).contains(index), "\(name) % \(count) -> \(index)")
            }
        }
    }

    /// A caller with an empty palette gets a boring answer, not a crash.
    func testEmptyPaletteDoesNotTrap() {
        XCTAssertEqual(StableHash.index(for: "anyone", modulo: 0), 0)
        XCTAssertEqual(StableHash.index(for: "anyone", modulo: -3), 0)
    }

    /// Not a uniformity proof - just a guard against a hash that collapses
    /// everything into one bucket, which would silently undo the colours.
    func testDifferentNamesSpreadAcrossBuckets() {
        let names = ["abi", "neeko", "sam", "kai", "rin", "jo", "max", "ada", "lee", "wren"]
        let buckets = Set(names.map { StableHash.index(for: $0, modulo: 7) })
        XCTAssertGreaterThanOrEqual(buckets.count, 4)
    }
}
