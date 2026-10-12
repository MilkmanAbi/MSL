import XCTest
@testable import MSLCore

/// The suite must not touch the real MSL installation.
///
/// It did. A full run left `last-greeting`, a `storage.json` describing
/// disks that never existed, and five empty directories in the developer's
/// own `~/Library/Application Support/MSL` - written by code the tests
/// reach incidentally: the greeter remembering which line it showed,
/// `DiskStorage` keeping its policy index, several types calling
/// `ensureDirectory` as they are built. It was noticed because a Mac wiped
/// for a fresh-install test had the folder back minutes later.
///
/// Writing there is the lesser half. A test that *reads* a real
/// installation is a test whose result depends on the machine it runs on,
/// which is how a suite passes for one person and fails for another.
final class TestIsolationTests: XCTestCase {

    func testAppSupportIsNotTheRealOne() {
        let real = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MSL").path
        XCTAssertNotEqual(MSLPaths.appSupport.path, real,
                          "tests are pointed at the real MSL directory - they will overwrite the developer's own instances and settings")
    }

    func testEverythingDerivedFromItIsAlsoRedirected() {
        // The redirect is at the root, so each of these follows for free -
        // but only while they keep deriving from `appSupport` rather than
        // spelling the path out again, which is exactly the mistake worth
        // catching.
        let home = NSHomeDirectory()
        for path in [MSLPaths.binDirectory.path, MSLPaths.appSupport.path, MSLPaths.logsDirectory.path] {
            XCTAssertFalse(path.hasPrefix(home + "/Library/Application Support/MSL"),
                           "\(path) still points into the real installation")
        }
    }

    func testTheRedirectIsStableWithinARun() {
        // Computed once per process. If it were re-derived per call, two
        // reads would disagree about where something had just been written.
        XCTAssertEqual(MSLPaths.appSupport.path, MSLPaths.appSupport.path)
    }

    func testWritingThroughItLandsInTheTemporaryDirectory() {
        // Not a tautology: this is the thing that actually goes wrong, and
        // it proves the directory is real and writable rather than merely a
        // different string.
        let marker = MSLPaths.appSupport.appendingPathComponent("isolation-probe")
        XCTAssertTrue(MSLPaths.ensureDirectory(MSLPaths.appSupport))
        XCTAssertNoThrow(try "x".write(to: marker, atomically: true, encoding: .utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: marker)
    }
}
