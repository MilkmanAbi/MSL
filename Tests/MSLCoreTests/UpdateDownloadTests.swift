import XCTest
@testable import MSLCore

/// Fetching and verifying MSL's own installer package.
///
/// The whole flow is driven offline through `MSL_RELEASE_BASE`, pointed at a
/// `file://` directory - the same lever `MSL_MANIFEST_URL` gives the distro
/// installer. There is no newer MSL release to test against, and there must
/// never need to be one.
final class UpdateDownloadTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("MSL_RELEASE_BASE")
        try? FileManager.default.removeItem(at: scratch)
    }

    private func release(_ version: String, tag: String? = nil) -> UpdateCheck.Release {
        UpdateCheck.Release(tag: tag ?? "v\(version)", version: UpdateCheck.Version(version)!)
    }

    /// The real package this repository builds, when it is there. Everything
    /// that needs a genuine `.pkg` skips without it rather than asserting
    /// against a fake one - a hand-made xar would prove nothing about the
    /// thing MSL actually ships.
    private func realPackage() throws -> URL {
        // The working directory a test runs in has moved before, so the
        // package is looked for rather than assumed: up from here, and from
        // this file's own location, which survives any cwd at all.
        let name = "MSL-\(MSLVersion.marketing).pkg"
        var roots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        // .../MSL/Tests/MSLCoreTests/UpdateDownloadTests.swift -> .../MSL
        roots.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        for root in roots {
            var directory = root
            for _ in 0..<4 {
                let candidate = directory.appendingPathComponent("dist/\(name)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                directory = directory.deletingLastPathComponent()
            }
        }
        throw XCTSkip("no built \(name) in any dist/ above \(roots[0].path) - run Scripts/build-installer.sh")
    }

    // MARK: - Where the asset is

    func testAssetNameMatchesWhatTheBuildScriptWrites() {
        // Scripts/build-installer.sh: PKG="$ROOT/dist/MSL-$VERSION.pkg",
        // and v1.0.0 shipped exactly "MSL-1.0.0.pkg".
        XCTAssertEqual(UpdateDownload.assetCandidates(version: "2.1.0").first, "MSL-2.1.0.pkg")
    }

    func testCandidateURLsPointAtTheReleasesDownloadPath() {
        let urls = UpdateDownload.candidateURLs(for: release("2.1.0"))
        XCTAssertEqual(urls.first?.absoluteString,
                       "https://github.com/MilkmanAbi/MSL/releases/download/v2.1.0/MSL-2.1.0.pkg")
    }

    /// A tag spelled differently from its version downloads from the *tag* -
    /// "the tag we compared is the tag we install" (OIS). The package inside
    /// is still named for the version, which is what MSL verifies against.
    func testTagIsWhatTheDownloadPathUses() {
        let odd = UpdateCheck.Release(tag: "v2.1", version: UpdateCheck.Version("2.1.0")!)
        let url = UpdateDownload.candidateURLs(for: odd).first
        XCTAssertEqual(url?.absoluteString.contains("/download/v2.1/"), true)
        XCTAssertEqual(url?.lastPathComponent, "MSL-2.1.0.pkg")
    }

    func testReleaseBaseOverrideRedirectsEverything() {
        setenv("MSL_RELEASE_BASE", "file:///tmp/fake", 1)
        XCTAssertEqual(UpdateDownload.candidateURLs(for: release("2.1.0")).first?.absoluteString,
                       "file:///tmp/fake/MSL-2.1.0.pkg")
    }

    func testReleaseBaseOverrideToleratesATrailingSlash() {
        setenv("MSL_RELEASE_BASE", "file:///tmp/fake/", 1)
        XCTAssertEqual(UpdateDownload.candidateURLs(for: release("2.1.0")).first?.absoluteString,
                       "file:///tmp/fake/MSL-2.1.0.pkg")
    }

    // MARK: - Reading a package

    func testIdentityFromDistribution() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="1">
            <pkg-ref id="com.msl.app"/>
            <pkg-ref id="com.msl.app" version="2.0.0" onConclusion="none">#MSL-app.pkg</pkg-ref>
        </installer-gui-script>
        """
        let identity = UpdateDownload.identity(inDistribution: xml)
        XCTAssertEqual(identity?.identifier, "com.msl.app")
        XCTAssertEqual(identity?.version, "2.0.0")
    }

    func testIdentityOfSomethingThatIsNotADistribution() {
        XCTAssertNil(UpdateDownload.identity(inDistribution: "<html>404 Not Found</html>"))
    }

    /// The realistic attack is not a forged installer, it is a captive
    /// portal or an error page saved as `.pkg`.
    func testAnHTMLPageIsNotAPackage() throws {
        let fake = scratch.appendingPathComponent("MSL-9.9.9.pkg")
        try "<html><body>404</body></html>".write(to: fake, atomically: true, encoding: .utf8)
        XCTAssertNil(UpdateDownload.identity(of: fake))
        XCTAssertThrowsError(try UpdateDownload.verify(fake, assetName: "MSL-9.9.9.pkg",
                                                       expecting: release("9.9.9"), sums: nil)) { error in
            XCTAssertEqual(error as? UpdateDownload.Failure, .notAPackage)
        }
    }

    func testRealPackageReadsItsOwnIdentity() throws {
        let identity = UpdateDownload.identity(of: try realPackage())
        XCTAssertEqual(identity?.identifier, "com.msl.app")
        XCTAssertEqual(identity?.version, MSLVersion.marketing)
    }

    /// The mistake a publisher is most likely to make: the right filename
    /// with the wrong package inside it.
    func testVersionMismatchIsRefused() throws {
        let pkg = try realPackage()
        XCTAssertThrowsError(try UpdateDownload.verify(pkg, assetName: pkg.lastPathComponent,
                                                       expecting: release("99.0.0"), sums: nil)) { error in
            XCTAssertEqual(error as? UpdateDownload.Failure,
                           .versionMismatch(expected: "99.0.0", found: MSLVersion.marketing))
        }
    }

    func testRealPackageVerifiesAgainstItsOwnVersion() throws {
        let pkg = try realPackage()
        let verification = try UpdateDownload.verify(pkg, assetName: pkg.lastPathComponent,
                                                     expecting: release(MSLVersion.marketing), sums: nil)
        XCTAssertEqual(verification, .identityOnly)
    }

    // MARK: - SHA256SUMS (OIS's rules)

    func testChecksumIsReadFromSums() {
        let sums = """
        abc123  info.txt
        deadbeef  MSL-2.1.0.pkg
        """
        XCTAssertEqual(UpdateDownload.checksum(for: "MSL-2.1.0.pkg", inSums: sums), "deadbeef")
        XCTAssertNil(UpdateDownload.checksum(for: "MSL-9.9.9.pkg", inSums: sums))
    }

    func testChecksumToleratesBinaryModeStar() {
        XCTAssertEqual(UpdateDownload.checksum(for: "MSL-2.1.0.pkg", inSums: "feed  *MSL-2.1.0.pkg"),
                       "feed")
    }

    /// OIS: a *wrong* checksum is fatal for the asset.
    func testWrongChecksumIsFatal() throws {
        let pkg = try realPackage()
        let sums = "0000000000000000000000000000000000000000000000000000000000000000  \(pkg.lastPathComponent)"
        XCTAssertThrowsError(try UpdateDownload.verify(pkg, assetName: pkg.lastPathComponent,
                                                       expecting: release(MSLVersion.marketing),
                                                       sums: sums)) { error in
            XCTAssertEqual(error as? UpdateDownload.Failure, .checksumMismatch)
        }
    }

    /// OIS: a *missing* entry is a warning, not a refusal. MSL's releases
    /// have never shipped SHA256SUMS, and refusing them all would make this
    /// feature useless on every release that exists.
    func testMissingChecksumEntryStillVerifies() throws {
        let pkg = try realPackage()
        let verification = try UpdateDownload.verify(pkg, assetName: pkg.lastPathComponent,
                                                     expecting: release(MSLVersion.marketing),
                                                     sums: "abc  something-else.txt")
        XCTAssertEqual(verification, .identityOnly)
    }

    func testMatchingChecksumIsReported() throws {
        let pkg = try realPackage()
        let digest = try XCTUnwrap(UpdateDownload.sha256(of: pkg))
        let verification = try UpdateDownload.verify(pkg, assetName: pkg.lastPathComponent,
                                                     expecting: release(MSLVersion.marketing),
                                                     sums: "\(digest)  \(pkg.lastPathComponent)")
        XCTAssertEqual(verification, .checksum)
    }

    // MARK: - Where it lands

    func testNothingInDownloadsIsEverOverwritten() throws {
        let existing = scratch.appendingPathComponent("MSL-2.1.0.pkg")
        try "something else entirely".write(to: existing, atomically: true, encoding: .utf8)
        let placed = UpdateDownload.destination(for: "MSL-2.1.0.pkg", in: scratch,
                                                matching: release("2.1.0"))
        XCTAssertFalse(placed.alreadyThere)
        XCTAssertEqual(placed.url.lastPathComponent, "MSL-2.1.0 2.pkg")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "something else entirely")
    }

    /// Running the update twice should not leave "MSL-2.1.0 2.pkg" behind.
    func testTheSamePackageAlreadyThereIsReused() throws {
        let pkg = try realPackage()
        let copy = scratch.appendingPathComponent(pkg.lastPathComponent)
        try FileManager.default.copyItem(at: pkg, to: copy)
        let placed = UpdateDownload.destination(for: pkg.lastPathComponent, in: scratch,
                                                matching: release(MSLVersion.marketing))
        XCTAssertTrue(placed.alreadyThere)
        XCTAssertEqual(placed.url, copy)
    }

    func testAFreeNameIsUsedWhenNothingIsThere() {
        let placed = UpdateDownload.destination(for: "MSL-2.1.0.pkg", in: scratch, matching: nil)
        XCTAssertEqual(placed.url.lastPathComponent, "MSL-2.1.0.pkg")
        XCTAssertFalse(placed.alreadyThere)
    }

    // MARK: - The whole fetch, offline

    /// Download, verify and place, driven entirely from a `file://`
    /// "release". This is the end-to-end test: the only part it cannot
    /// exercise is GitHub itself.
    func testFetchFromAFileURLRelease() throws {
        let pkg = try realPackage()
        let host = scratch.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pkg, to: host.appendingPathComponent(pkg.lastPathComponent))
        setenv("MSL_RELEASE_BASE", host.absoluteString, 1)

        let landing = scratch.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)

        let fetched = try UpdateDownload.fetch(release(MSLVersion.marketing), into: landing)
        XCTAssertFalse(fetched.reused)
        XCTAssertEqual(fetched.url.lastPathComponent, pkg.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fetched.url.path))
        XCTAssertEqual(UpdateDownload.identity(of: fetched.url)?.version, MSLVersion.marketing)
        // No half-finished file is left looking like an installer.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: landing.path)
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".msldownload") }, [])
    }

    /// A second run finds it already there and transfers nothing.
    func testFetchReusesAVerifiedPackageAlreadyInDownloads() throws {
        let pkg = try realPackage()
        let host = scratch.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pkg, to: host.appendingPathComponent(pkg.lastPathComponent))
        setenv("MSL_RELEASE_BASE", host.absoluteString, 1)

        let landing = scratch.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        _ = try UpdateDownload.fetch(release(MSLVersion.marketing), into: landing)
        let again = try UpdateDownload.fetch(release(MSLVersion.marketing), into: landing)
        XCTAssertTrue(again.reused)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: landing.path).count, 1)
    }

    /// A release whose asset is missing fails without touching anything -
    /// the caller then falls back to opening the release page, which is what
    /// MSL did before this existed.
    func testAMissingAssetFailsCleanly() throws {
        let host = scratch.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        setenv("MSL_RELEASE_BASE", host.absoluteString, 1)
        let landing = scratch.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)

        XCTAssertThrowsError(try UpdateDownload.fetch(release("9.9.9"), into: landing))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: landing.path), [])
    }
}
