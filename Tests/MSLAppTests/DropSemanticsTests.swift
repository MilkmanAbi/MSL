import XCTest
@testable import MSLApp
@testable import MSLCore

/// What a drag actually does when it lands.
///
/// Finder's rule, and what people mean by "proper" drag and drop: within one
/// volume a drag moves, across volumes it copies, option always copies.
/// Dragging a file into a sibling folder and finding two of it is the thing
/// that makes a file browser feel wrong.
final class DropSemanticsTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func file(_ name: String) -> String {
        let path = root.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return path
    }

    private func folder(_ name: String) -> String {
        let path = root.appendingPathComponent(name).path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Two paths on one disk: a move is possible, so a drag should move.
    func testPathsOnOneVolumeAreRecognised() {
        XCTAssertTrue(FilesModel.sameFilesystem(file("a.txt"), folder("dest")))
    }

    /// A path that does not exist cannot be reasoned about, and guessing
    /// "same volume" would turn a copy into a move across the Mac/Linux line.
    func testAnUnreachablePathIsNotAssumedToBeLocal() {
        XCTAssertFalse(FilesModel.sameFilesystem(file("a.txt"),
                                                 "/Volumes/127.0.0.1/home/nobody"))
    }

    func testMovingTakesTheFileWithIt() throws {
        let source = file("note.txt")
        let destination = folder("inbox")
        try FilesModel.move(source, into: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source),
                       "a move must not leave the original behind")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("note.txt")))
    }

    /// Refusing is the safe half of Finder's replace-or-keep-both, and an
    /// accidental drag overwriting a file is exactly the loss not to make
    /// easy.
    func testMovingOntoAnExistingNameIsRefused() {
        let source = file("same.txt")
        let destination = folder("dest")
        FileManager.default.createFile(
            atPath: (destination as NSString).appendingPathComponent("same.txt"),
            contents: Data("other".utf8))

        XCTAssertThrowsError(try FilesModel.move(source, into: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source),
                      "a refused move must leave the original alone")
    }

    /// `rename(2)` reports this as EINVAL, which would surface as a baffling
    /// error after the row had already vanished from the list.
    func testAFolderCannotBeDroppedIntoItself() {
        let outer = folder("project")
        let inner = (outer as NSString).appendingPathComponent("sub")
        try? FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FilesModel.move(outer, into: inner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outer))
    }

    /// Dropping something back where it already is should do nothing at all,
    /// rather than erroring on a name that is "already taken" by itself.
    func testDroppingIntoItsOwnFolderIsANoOp() throws {
        let source = file("stay.txt")
        try FilesModel.move(source, into: root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }
}
