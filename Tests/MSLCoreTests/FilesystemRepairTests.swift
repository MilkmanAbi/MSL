import XCTest
@testable import MSLCore

final class FilesystemRepairTests: XCTestCase {
    // MARK: - Verdicts

    /// e2fsck's exit status is a bitmask, and the bits meaning "the check
    /// did not happen" must beat everything else. This table is the single
    /// most important thing in the feature: getting a row wrong tells
    /// someone a broken disk is fine.
    func testExitCodeTable() {
        let rows: [(Int32, FsckMode, FsckVerdict.Outcome, healthy: Bool)] = [
            (0,   .check,  .clean, true),
            (0,   .repair, .clean, true),
            (1,   .repair, .repaired, true),
            (2,   .repair, .repairedNeedsRestart, true),
            (3,   .repair, .repairedNeedsRestart, true),     // 1|2
            (4,   .check,  .problemsRemain, false),
            (4,   .repair, .problemsRemain, false),
            (5,   .repair, .problemsRemain, false),          // 1|4: fixed some, not all
            (6,   .repair, .problemsRemain, false),          // 2|4
        ]
        for (code, mode, expected, healthy) in rows {
            let verdict = FsckVerdict.from(exitCode: code, mode: mode)
            XCTAssertEqual(verdict.outcome, expected, "exit \(code) in \(mode) mode")
            XCTAssertEqual(verdict.isHealthy, healthy, "exit \(code) health")
            XCTAssertEqual(verdict.allowsBoot, healthy, "exit \(code) boot decision")
        }
    }

    func testTheCheckNotRunningIsNeverReportedAsClean() {
        for code: Int32 in [8, 12, 16, 32, 128, 136, 255, -1] {
            let verdict = FsckVerdict.from(exitCode: code, mode: .check)
            guard case .didNotRun = verdict.outcome else {
                return XCTFail("exit \(code) rendered as \(verdict.outcome) - the check did not run")
            }
            XCTAssertFalse(verdict.isHealthy, "exit \(code) called healthy")
            XCTAssertFalse(verdict.allowsBoot, "exit \(code) allowed a boot on an unchecked disk")
            XCTAssertTrue(verdict.detail.contains("says nothing about the disk"))
        }
    }

    /// 12 is 8|4. The operational error means the "errors left" bit can't be
    /// trusted either, so it must read as "didn't run", not "problems".
    func testOperationalErrorOutranksProblemsFound() {
        guard case .didNotRun = FsckVerdict.from(exitCode: 12, mode: .check).outcome else {
            return XCTFail("8|4 should be treated as a check that didn't complete")
        }
    }

    func testWordingFollowsTheMode() {
        XCTAssertEqual(FsckVerdict.from(exitCode: 4, mode: .check).title, "Problems found")
        XCTAssertEqual(FsckVerdict.from(exitCode: 4, mode: .repair).title, "Some problems couldn't be fixed")
    }

    // MARK: - Arguments

    /// A check must never be able to modify the disk, and a repair must never
    /// silently degrade into a check.
    func testCheckNeverWritesAndRepairNeverChecksOnly() {
        let check = FilesystemCheck.arguments(for: .check)
        let repair = FilesystemCheck.arguments(for: .repair)
        XCTAssertTrue(check.contains("-n"))
        XCTAssertFalse(check.contains("-y"))
        XCTAssertFalse(check.contains("-p"))
        XCTAssertTrue(repair.contains("-y"))
        XCTAssertFalse(repair.contains("-n"))
        // -f on both: a disk cut off mid-write can be marked clean and be wrong.
        XCTAssertTrue(check.contains("-f"))
        XCTAssertTrue(repair.contains("-f"))
    }

    // MARK: - Locating e2fsck

    func testFindsTheHomebrewKegFirst() {
        let found = E2fsck.locate(pathEnvironment: "/usr/bin:/somewhere/else") {
            $0 == "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck" || $0 == "/somewhere/else/e2fsck"
        }
        XCTAssertEqual(found, "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck")
    }

    func testFallsBackToPath() {
        let found = E2fsck.locate(pathEnvironment: "/usr/bin::/custom/sbin") { $0 == "/custom/sbin/e2fsck" }
        XCTAssertEqual(found, "/custom/sbin/e2fsck")
    }

    func testIntelHomebrewIsFound() {
        XCTAssertEqual(E2fsck.locate(pathEnvironment: nil) { $0 == "/usr/local/opt/e2fsprogs/sbin/e2fsck" },
                       "/usr/local/opt/e2fsprogs/sbin/e2fsck")
    }

    /// The case that matters for most users: nothing is installed.
    func testAbsentMeansNil() {
        XCTAssertNil(E2fsck.locate(pathEnvironment: "/usr/bin:/bin") { _ in false })
        XCTAssertNil(E2fsck.locate(pathEnvironment: nil) { _ in false })
    }

    // MARK: - Backups

    func testBackupSitsBesideTheImage() {
        XCTAssertEqual(ImageBackup.path(for: "/a/b/rootfs.img"), "/a/b/rootfs.img.pre-repair")
    }

    /// A second repair must not overwrite the first one's backup: the older
    /// copy is the truly original disk.
    func testExistingBackupIsKept() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("disk.img").path
        try Data("original".utf8).write(to: URL(fileURLWithPath: image))

        try ImageBackup.make(for: image)
        try Data("after first repair".utf8).write(to: URL(fileURLWithPath: image))
        try ImageBackup.make(for: image)

        XCTAssertEqual(try String(contentsOfFile: ImageBackup.path(for: image), encoding: .utf8), "original")
    }

    /// A clone on APFS is free; this proves it really is a clone rather than
    /// a copy, since the whole safety argument rests on it costing nothing.
    func testBackupIsAnInstantClone() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("big.img").path
        FileManager.default.createFile(atPath: image, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: image))
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 32 * 1024 * 1024))
        try handle.close()

        let freeBefore = try freeBytes(at: work)
        try ImageBackup.make(for: image)
        let freeAfter = try freeBytes(at: work)

        XCTAssertTrue(ImageBackup.exists(for: image))
        // A real copy would consume 32 MB. Allow slack for unrelated churn.
        XCTAssertLessThan(freeBefore - min(freeBefore, freeAfter), 8 * 1024 * 1024,
                          "the backup cost real space - it was copied, not cloned")
    }

    func testRestoreConsumesTheBackup() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("disk.img").path
        try Data("before".utf8).write(to: URL(fileURLWithPath: image))
        try ImageBackup.make(for: image)
        try Data("after".utf8).write(to: URL(fileURLWithPath: image))

        try ImageBackup.restore(for: image)
        XCTAssertEqual(try String(contentsOfFile: image, encoding: .utf8), "before")
        XCTAssertFalse(ImageBackup.exists(for: image))
    }

    // MARK: - The real thing

    /// End to end against a real ext4 image, when e2fsprogs is installed:
    /// build it, corrupt it deterministically, and walk it through check,
    /// repair, re-check and restore - asserting that check mode never
    /// changes a byte and that the backup is exactly the pre-repair disk.
    func testRealImageCheckRepairBackupRestore() throws {
        guard let e2fsck = E2fsck.locate() else { throw XCTSkip("e2fsprogs isn't installed") }
        let tools = (e2fsck as NSString).deletingLastPathComponent
        let mke2fs = tools + "/mke2fs", debugfs = tools + "/debugfs"
        guard FileManager.default.isExecutableFile(atPath: mke2fs),
              FileManager.default.isExecutableFile(atPath: debugfs) else {
            throw XCTSkip("mke2fs/debugfs missing beside e2fsck")
        }

        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("disk.img").path
        FileManager.default.createFile(atPath: image, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: image))
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()

        try run(mke2fs, ["-q", "-t", "ext4", "-F", image])
        let payload = work.appendingPathComponent("payload.txt")
        try Data("hello".utf8).write(to: payload)
        try run(debugfs, ["-w", "-R", "write \(payload.path) hello.txt", image])

        XCTAssertEqual(FilesystemCheck.run(e2fsck: e2fsck, imagePath: image, mode: .check).verdict.outcome,
                       .clean, "a freshly made filesystem should check clean")

        // The corruption: a file claiming seven links when it has one.
        try run(debugfs, ["-w", "-R", "set_inode_field hello.txt links_count 7", image])
        let corrupted = try Data(contentsOf: URL(fileURLWithPath: image))

        let check = FilesystemCheck.run(e2fsck: e2fsck, imagePath: image, mode: .check)
        XCTAssertEqual(check.verdict.outcome, .problemsRemain)
        XCTAssertNil(check.backupPath, "a check has nothing to back up")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image)), corrupted,
                       "check mode changed the disk")

        let repair = FilesystemCheck.run(e2fsck: e2fsck, imagePath: image, mode: .repair)
        XCTAssertEqual(repair.verdict.outcome, .repaired)
        XCTAssertEqual(repair.backupPath, ImageBackup.path(for: image))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ImageBackup.path(for: image))), corrupted,
                       "the backup isn't the disk from before the repair")
        XCTAssertFalse(repair.output.isEmpty, "e2fsck's report should come back for the disclosure")

        XCTAssertEqual(FilesystemCheck.run(e2fsck: e2fsck, imagePath: image, mode: .check).verdict.outcome,
                       .clean, "the repair didn't take")

        try ImageBackup.restore(for: image)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image)), corrupted,
                       "restoring didn't put the original disk back")
    }

    // MARK: - Helpers

    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msl-fsck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func freeBytes(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return UInt64(values.volumeAvailableCapacity ?? 0)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
