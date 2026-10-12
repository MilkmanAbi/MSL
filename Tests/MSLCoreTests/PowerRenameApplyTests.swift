import XCTest
@testable import MSLCore

/// The Power Rename *apply* strategy: rename everything to a unique temporary
/// name first, then to its final name. This is what lets a batch shuffle names
/// among itself - the case a naive one-pass rename gets wrong, because
/// `LocalFileProvider.rename` (rightly) refuses to clobber an existing file.
/// `FilesModel.applyPowerRename` does exactly this; here it's exercised against
/// a real directory.
final class PowerRenameApplyTests: XCTestCase {
    private func makeDir(_ names: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    /// Mirrors `FilesModel.applyPowerRename`'s two passes.
    private func apply(_ mapping: [(old: String, new: String)],
                       in dir: URL, provider: LocalFileProvider) async throws {
        var staged: [(temp: String, final: String)] = []
        for change in mapping where change.old != change.new {
            let temp = ".msl-rename-\(UUID().uuidString)"
            try await provider.rename(dir.appendingPathComponent(change.old).path, to: temp)
            staged.append((dir.appendingPathComponent(temp).path, change.new))
        }
        for item in staged {
            try await provider.rename(item.temp, to: item.final)
        }
    }

    func testBatchRenameProducesExpectedFiles() async throws {
        let dir = try makeDir(["K123_a.txt", "K123_b.txt", "K123_c.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = LocalFileProvider(displayName: "t", rootPath: dir.path)

        try await apply([("K123_a.txt", "Lie_a.txt"),
                         ("K123_b.txt", "Lie_b.txt"),
                         ("K123_c.txt", "Lie_c.txt")], in: dir, provider: provider)

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["Lie_a.txt", "Lie_b.txt", "Lie_c.txt"])
    }

    /// The collision case two-phase exists for: a.txt -> b.txt while b.txt still
    /// exists (because it's being renamed too). A one-pass rename would throw
    /// `alreadyExists`; two-phase must sail through.
    func testRotationDoesNotCollide() async throws {
        let dir = try makeDir(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = LocalFileProvider(displayName: "t", rootPath: dir.path)

        // Tag the contents so we can prove they swapped, not just that the
        // names exist.
        try Data("A".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("B".utf8).write(to: dir.appendingPathComponent("b.txt"))

        try await apply([("a.txt", "b.txt"), ("b.txt", "a.txt")], in: dir, provider: provider)

        let a = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
        let b = try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8)
        XCTAssertEqual(a, "B")   // what was b is now a
        XCTAssertEqual(b, "A")   // and vice versa
    }
}
