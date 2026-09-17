import XCTest
@testable import MSLCore

/// The registry is read and written by the CLI and the daemon at once. A save
/// that truncates the file before writing it lets a reader in between decode
/// an empty registry - `msl list` once showed no instances at all while the
/// daemon was writing (2026-09-14). Saves are atomic now: a reader sees the
/// old file or the new one, never half of either.
final class InstanceRegistryAtomicWriteTests: XCTestCase {
    func testReadsNeverSeeAnEmptyRegistryWhileAnotherWriterSaves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instances.json")

        let registry = InstanceRegistry(path: path)
        _ = try registry.ensureRegistered("default", distro: .alpine)
        _ = try registry.ensureRegistered("debian", distro: .debian)

        let stop = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // A second registry object, as a second process would have.
            let writer = InstanceRegistry(path: path)
            while stop.wait(timeout: .now()) == .timedOut {
                _ = try? writer.ensureRegistered("scratch", distro: .fedora)
                try? writer.remove("scratch")
            }
            writerDone.signal()
        }

        var emptyReads = 0
        var missingBaseline = 0
        let reader = InstanceRegistry(path: path)
        for _ in 0..<4000 {
            let names = reader.list()
            if names.isEmpty { emptyReads += 1 }
            if !names.contains("default") || !names.contains("debian") { missingBaseline += 1 }
        }
        stop.signal()
        writerDone.wait()

        XCTAssertEqual(emptyReads, 0, "a read caught the registry mid-write and saw no instances")
        XCTAssertEqual(missingBaseline, 0, "a read lost instances nobody removed")
        XCTAssertEqual(Set(reader.list()), ["default", "debian"])
    }
}
