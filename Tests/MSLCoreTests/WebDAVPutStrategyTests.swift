import XCTest
@testable import MSLCore

/// Which way a PUT body reaches the guest.
///
/// The bug being fixed: a >4 MiB PUT writes chunk by chunk from offset 0, so
/// if chunk 3 of 10 fails, Finder reports an error while a truncated,
/// half-rewritten file is already sitting on disk under its final name.
///
/// The fix is deliberately narrow, and the *narrowness* is the thing worth
/// testing - temp-and-rename everywhere would drop an existing file's
/// permissions on every save, because `rename` replaces the inode and
/// `fileopsd` has no CHMOD opcode. These tests pin both halves: that a new
/// large file goes via a temp, and that nothing else does.
final class WebDAVPutStrategyTests: XCTestCase {
    private let chunk = 4 * 1024 * 1024
    private let temp = "/srv/.msl-put-FIXED.tmp"

    private func strategy(_ bodyCount: Int, _ destination: WebDAVServer.PutDestination)
        -> WebDAVServer.PutStrategy {
        WebDAVServer.putStrategy(bodyCount: bodyCount, chunkSize: chunk,
                                 destination: destination, tempPath: temp)
    }

    // MARK: - The case that is actually fixed

    func testCreatingALargeFileGoesViaATemporary() {
        XCTAssertEqual(strategy(chunk + 1, .absent), .viaTemporary(tempPath: temp),
                       "a failure part-way through must leave no file behind at all, "
                       + "rather than a partial one that looks like a finished copy")
    }

    // MARK: - The cases that deliberately do not change

    func testOverwritingALargeFileStaysInPlace() {
        // Not an oversight. Renaming over it would lose its mode, and losing
        // a script's +x on every save is worse than a rare, reported failure.
        XCTAssertEqual(strategy(chunk + 1, .present), .inPlace)
        XCTAssertEqual(strategy(64 * 1024 * 1024, .present), .inPlace)
    }

    func testSmallBodiesStayInPlaceWhetherOrNotTheFileExists() {
        // `fileopsd` reads the whole frame before writing, so a single-chunk
        // write is already all-or-nothing. A temp would only cost a rename
        // and, on an overwrite, the file's permissions.
        for size in [1, 1024, chunk - 1, chunk] {
            XCTAssertEqual(strategy(size, .absent), .inPlace, "\(size) bytes, new file")
            XCTAssertEqual(strategy(size, .present), .inPlace, "\(size) bytes, overwrite")
        }
    }

    func testTheBoundaryIsExactlyOneChunk() {
        XCTAssertEqual(strategy(chunk, .absent), .inPlace, "exactly one chunk is one write")
        XCTAssertEqual(strategy(chunk + 1, .absent), .viaTemporary(tempPath: temp),
                       "one byte more needs two writes, and two writes can fail between them")
    }

    // MARK: - Where the temp file lives

    func testTemporaryIsASiblingOfTheDestination() {
        // `rename(2)` cannot cross filesystems, and the guest's /tmp may be
        // a different one.
        XCTAssertEqual(WebDAVServer.temporaryPutPath(for: "/srv/data/report.pdf", uuid: "U"),
                       "/srv/data/.msl-put-U.tmp")
    }

    func testTemporaryAtTheFilesystemRoot() {
        XCTAssertEqual(WebDAVServer.temporaryPutPath(for: "/notes.txt", uuid: "U"),
                       "/.msl-put-U.tmp")
    }

    func testTemporaryIsHidden() {
        let path = WebDAVServer.temporaryPutPath(for: "/srv/x.bin", uuid: "U")
        let name = String(path.split(separator: "/").last!)
        XCTAssertTrue(name.hasPrefix("."), "one that outlives a crash should stay out of the way")
    }

    /// The temp name must not grow with the destination's - a 250-character
    /// basename plus a suffix would blow past NAME_MAX and fail the write
    /// for a reason that has nothing to do with the file.
    func testTemporaryNameDoesNotInheritTheDestinationName() {
        let long = String(repeating: "n", count: 250)
        let path = WebDAVServer.temporaryPutPath(for: "/srv/\(long).bin", uuid: "0123456789")
        let name = String(path.split(separator: "/").last!)
        XCTAssertFalse(name.contains("n"), "no part of the destination name is copied in")
        XCTAssertLessThan(name.utf8.count, 255, "must fit in NAME_MAX")
    }

    func testTemporaryIsUniquePerCall() {
        // Two concurrent PUTs into one directory must not share a temp.
        let a = WebDAVServer.temporaryPutPath(for: "/srv/x", uuid: UUID().uuidString)
        let b = WebDAVServer.temporaryPutPath(for: "/srv/x", uuid: UUID().uuidString)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Cleaning up after a failure

    func testGuestSideFailureIsWorthCleaningUpAfter() {
        // ENOSPC, EACCES: the connection is alive and the temp is really there.
        XCTAssertTrue(WebDAVServer.shouldCleanUpTemporary(
            after: FileOpsProtocol.FileOpsError.remote(errno: ENOSPC)))
        XCTAssertTrue(WebDAVServer.shouldCleanUpTemporary(
            after: FileOpsProtocol.FileOpsError.remote(errno: EACCES)))
    }

    func testATimeoutIsNotWorthCleaningUpAfter() {
        // The transport is gone, so the unlink cannot succeed either - it
        // would just burn another full operationTimeout before Finder is
        // told anything at all.
        XCTAssertFalse(WebDAVServer.shouldCleanUpTemporary(after: WebDAVServerError.timedOut))
        XCTAssertFalse(WebDAVServer.shouldCleanUpTemporary(
            after: FileOpsProtocol.FileOpsError.connectionClosed))
    }
}
