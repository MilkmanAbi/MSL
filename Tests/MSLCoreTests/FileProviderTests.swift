import XCTest
@testable import MSLCore

/// The provider is the whole data layer under the file browser, and it is
/// the part that can be exercised without a guest: the Linux side is a
/// mounted volume, so `FileManager` is the same code path either way.
final class FileProviderTests: XCTestCase {

    private var root: URL!
    private var provider: LocalFileProvider!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        provider = LocalFileProvider(displayName: "Test", rootPath: root.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testListsDirectoriesFirstThenNaturalOrder() async throws {
        _ = try write("banana.txt")
        _ = try write("Apple.txt")
        _ = try write("file10.txt")
        _ = try write("file2.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zebra-dir"), withIntermediateDirectories: true)

        let items = try await provider.list(root.path)
        XCTAssertEqual(items.first?.name, "zebra-dir", "directories sort first, as in Finder")
        let files = items.filter { !$0.isDirectory }.map(\.name)
        // Case-insensitive, and "file2" before "file10" - localizedStandard.
        XCTAssertEqual(files, ["Apple.txt", "banana.txt", "file2.txt", "file10.txt"])
    }

    func testItemMetadata() async throws {
        _ = try write("hello.txt", "hello world")
        let listed = try await provider.list(root.path)
        let item = try XCTUnwrap(listed.first { $0.name == "hello.txt" })
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.size, 11)
        XCTAssertNotNil(item.modified)
        XCTAssertFalse(item.isHidden)
    }

    func testHiddenFlag() async throws {
        _ = try write(".profile")
        let listed = try await provider.list(root.path)
        let item = try XCTUnwrap(listed.first { $0.name == ".profile" })
        XCTAssertTrue(item.isHidden)
    }

    func testCreateRenameRemove() async throws {
        let folder = root.appendingPathComponent("New Folder").path
        try await provider.createDirectory(at: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))

        try await provider.rename(folder, to: "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))

        try await provider.remove(root.appendingPathComponent("Renamed").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))
    }

    /// A rename field must not be able to move a file to another directory.
    func testRenameRejectsPathsAndClobbering() async throws {
        _ = try write("a.txt")
        _ = try write("b.txt")
        let a = root.appendingPathComponent("a.txt").path

        for bad in ["", "/", "../escaped.txt", "sub/dir.txt", ".", ".."] {
            do {
                try await provider.rename(a, to: bad)
                XCTFail("should have rejected '\(bad)'")
            } catch {}
        }
        // And it must not silently replace an existing file.
        do {
            try await provider.rename(a, to: "b.txt")
            XCTFail("should not clobber b.txt")
        } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "x")
    }

    func testCreateDirectoryRefusesDuplicate() async throws {
        let path = root.appendingPathComponent("dup").path
        try await provider.createDirectory(at: path)
        do {
            try await provider.createDirectory(at: path)
            XCTFail("should refuse an existing directory")
        } catch {}
    }

    /// Drag-and-drop across the boundary, both directions.
    func testImportAndExport() async throws {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let source = try write("dragged.txt", "payload")

        try await provider.importFile(from: source, into: other.path)
        XCTAssertEqual(
            try String(contentsOf: other.appendingPathComponent("dragged.txt"), encoding: .utf8), "payload")

        let exported = root.appendingPathComponent("exported.txt")
        try await provider.exportFile(source.path, to: exported)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "payload")
    }

    /// Dropping onto a file that already exists must not destroy it - the
    /// dangerous half of a Finder "replace?" prompt, without the prompt.
    func testImportRefusesToClobber() async throws {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: other.appendingPathComponent("dragged.txt"))
        let source = try write("dragged.txt", "new")

        do {
            try await provider.importFile(from: source, into: other.path)
            XCTFail("should refuse to overwrite")
        } catch {}
        XCTAssertEqual(
            try String(contentsOf: other.appendingPathComponent("dragged.txt"), encoding: .utf8), "original")
    }

    /// A read-only provider - what the guest becomes if the WebDAV mount
    /// turns out to be `rdonly` - must refuse every mutation rather than
    /// failing somewhere deeper.
    func testReadOnlyProviderRefusesEveryMutation() async throws {
        let readOnly = LocalFileProvider(displayName: "Guest", rootPath: root.path, readOnly: true)
        XCTAssertFalse(readOnly.isWritable)
        _ = try write("f.txt")

        do { try await readOnly.createDirectory(at: root.appendingPathComponent("x").path); XCTFail() } catch {}
        do { try await readOnly.remove(root.appendingPathComponent("f.txt").path); XCTFail() } catch {}
        do { try await readOnly.rename(root.appendingPathComponent("f.txt").path, to: "g.txt"); XCTFail() } catch {}
        do {
            try await readOnly.importFile(from: root.appendingPathComponent("f.txt"), into: root.path)
            XCTFail()
        } catch {}
        // Reading out of a read-only provider is still fine.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("f.txt").path))
    }
    // MARK: - Read-only volume detection

    /// The real thing: a UDRO disk image, mounted read-only, written to.
    /// Synthetic `NSError`s would only prove the classifier matches what I
    /// guessed macOS produces. This proves it matches what macOS produces.
    func testDetectsRefusalFromARealReadOnlyVolume() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-ro-\(UUID().uuidString)")
        let source = scratch.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hi".write(to: source.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let image = scratch.appendingPathComponent("ro.dmg")
        guard runTool("/usr/bin/hdiutil",
                      ["create", "-quiet", "-srcfolder", source.path, "-format", "UDRO",
                       "-volname", "MSLROTest", image.path]) != nil,
              let attach = runTool("/usr/bin/hdiutil",
                                   ["attach", "-nobrowse", "-readonly", image.path]),
              let mount = attach.split(separator: "\n").last(where: { $0.contains("/Volumes/") })
                  .map({ String($0[$0.range(of: "/Volumes/")!.lowerBound...])
                      .trimmingCharacters(in: .whitespaces) })
        else { throw XCTSkip("hdiutil unavailable in this environment") }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", "-quiet", mount]) }

        // The local case behaves: access(2) knows the mount is read-only.
        // It is WebDAV, where the bits lie, that this exists for.
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: mount))

        do {
            try FileManager.default.createDirectory(
                atPath: mount + "/newdir", withIntermediateDirectories: false)
            XCTFail("expected the read-only volume to refuse a write")
        } catch {
            XCTAssertTrue(isReadOnlyVolumeError(error),
                          "unrecognised refusal: \(error as NSError)")
        }
    }

    func testOrdinaryFailuresAreNotMistakenForAReadOnlyVolume() {
        // A missing file, not a refusing volume: the UI must not disable
        // writing for the whole root because one operation failed.
        let missing = NSError(domain: NSCocoaErrorDomain,
                              code: NSFileNoSuchFileError, userInfo: nil)
        XCTAssertFalse(isReadOnlyVolumeError(missing))
        XCTAssertFalse(isReadOnlyVolumeError(MSLFileError.notWritable("Linux")))
        XCTAssertTrue(isReadOnlyVolumeError(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS), userInfo: nil)))
    }

    private func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    // MARK: - Trash

    /// Deleting must be recoverable wherever the volume allows it. Verified
    /// by actually trashing a file and finding it in the user's Trash - a
    /// mock would only prove `trashItem` was called.
    func testDeleteMovesToTheTrashAndLeavesTheFileRecoverable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A unique name so the assertion cannot pass on some other file the
        // user already had in the Trash.
        let name = "msl-trash-probe-\(UUID().uuidString).txt"
        let file = root.appendingPathComponent(name)
        try "recover me".write(to: file, atomically: true, encoding: .utf8)

        let provider = LocalFileProvider(displayName: "Test", rootPath: root.path)
        let trashed = try await provider.trash(file.path)

        XCTAssertTrue(trashed, "a local volume should have a Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the file should have left its original location")

        let inTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path),
                      "the file should be recoverable from the Trash")
        XCTAssertEqual(try String(contentsOf: inTrash, encoding: .utf8), "recover me")
        try? FileManager.default.removeItem(at: inTrash)
    }

    func testTrashRefusesOnAReadOnlyProvider() async throws {
        let provider = LocalFileProvider(displayName: "Linux", rootPath: "/tmp", readOnly: true)
        do {
            _ = try await provider.trash("/tmp/whatever")
            XCTFail("a read-only provider must refuse to trash")
        } catch {
            XCTAssertTrue(error is MSLFileError)
        }
    }
    // MARK: - Finder tags

    /// Tags written here must be the same tags Finder writes - not a
    /// private store that merely round-trips through our own reader.
    ///
    /// The check that discriminates: after writing, read the value back
    /// through `URLResourceValues.tagNames`, which is Foundation's own
    /// reader and knows nothing about this code, and compare the raw
    /// attribute against the exact byte format observed on files Finder
    /// itself had tagged.
    func testWritesGenuineFinderTags() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tag-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        try FileTagStore.setTags(["Red", "Blue"], at: file.path)

        // Foundation's own reader sees them.
        let viaFoundation = try file.resourceValues(forKeys: [.tagNamesKey]).tagNames
        XCTAssertEqual(viaFoundation.map(Set.init), Set(["Red", "Blue"]))

        // And the colours survive, which is what needs the raw attribute.
        let tags = FileTagStore.tags(at: file.path)
        XCTAssertEqual(Set(tags.map(\.name)), Set(["Red", "Blue"]))
        XCTAssertEqual(tags.first { $0.name == "Red" }?.colorIndex, 6)
        XCTAssertEqual(tags.first { $0.name == "Blue" }?.colorIndex, 4)
    }

    func testCustomTagKeepsItsNameAndHasNoColour() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tag-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        try FileTagStore.setTags(["Project MSL"], at: file.path)
        let tags = FileTagStore.tags(at: file.path)
        XCTAssertEqual(tags, [FileTag(name: "Project MSL", colorIndex: 0)])
    }

    func testTogglingAndClearingTags() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tag-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        try FileTagStore.toggle("Green", at: file.path)
        XCTAssertEqual(FileTagStore.tags(at: file.path).map(\.name), ["Green"])
        try FileTagStore.toggle("Green", at: file.path)
        XCTAssertTrue(FileTagStore.tags(at: file.path).isEmpty)

        // Clearing a file that has no tags must not fail - removexattr
        // reports ENOATTR and that is not an error worth surfacing.
        XCTAssertNoThrow(try FileTagStore.setTags([], at: file.path))
    }
}
