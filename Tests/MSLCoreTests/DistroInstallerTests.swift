import CryptoKit
import XCTest
@testable import MSLCore

/// Exercises the installer end to end against a `file://` manifest.
///
/// The real thing downloads multi-gigabyte images over HTTP, which is not
/// something a test can do - but `install` takes both the manifest URL and
/// the destination directory, and curl speaks `file://`, so everything
/// except the network transport itself is reachable offline: manifest
/// decoding, the unknown-distro error, sha256 verification, the "shared
/// kernel already present" skip, and the atomic install.
final class DistroInstallerTests: XCTestCase {

    private var root: URL!
    private var served: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-installer-\(UUID().uuidString)")
        served = root.appendingPathComponent("served")
        destination = root.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Publishes `contents` as a file and returns the artifact describing it.
    private func publish(_ name: String, _ contents: String) throws -> DistroInstaller.Artifact {
        let url = served.appendingPathComponent(name)
        let data = Data(contents.utf8)
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return DistroInstaller.Artifact(
            version: "1.0", url: "file://" + url.path, sha256: digest, size: UInt64(data.count))
    }

    private func writeManifest(_ manifest: DistroInstaller.Manifest) throws -> String {
        let url = served.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: url)
        return "file://" + url.path
    }

    // MARK: - Falling back between image sources

    /// A source that cannot possibly answer: a manifest that is not there.
    private var brokenSource: DistroInstaller.ImageSource {
        DistroInstaller.ImageSource(
            name: "Broken",
            manifestURL: "file://" + served.appendingPathComponent("no-such-manifest.json").path)
    }

    private func workingSource(_ name: String = "Working") throws -> DistroInstaller.ImageSource {
        let url = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "kernel-bytes"),
            initramfs: try publish("initramfs", "initramfs-bytes"),
            distros: ["debian": try publish("debian.img", "debian-rootfs")]))
        return DistroInstaller.ImageSource(name: name, manifestURL: url)
    }

    func testFallsBackToTheNextSourceWhenTheFirstIsDown() throws {
        var log: [String] = []
        try DistroInstaller.install(
            distro: .debian, sources: [brokenSource, try workingSource()],
            appSupportDir: destination) { log.append($0) }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("rootfs-debian.img").path),
            "the image should have arrived from the second source")
        XCTAssertTrue(log.contains { $0.contains("Broken didn't work") },
                      "the person should be told the first source failed: \(log)")
        XCTAssertTrue(log.contains { $0.contains("downloading from Broken") })
    }

    /// The first source is tried twice before moving on - that is the "retry
    /// one more time" half of the behaviour, and it is invisible without a
    /// count.
    func testEachSourceIsTriedTwiceBeforeMovingOn() throws {
        var log: [String] = []
        try DistroInstaller.install(
            distro: .debian, sources: [brokenSource, try workingSource()],
            appSupportDir: destination) { log.append($0) }
        let retries = log.filter { $0.contains("retrying from Broken") }
        XCTAssertEqual(retries.count, DistroInstaller.attemptsPerSource - 1,
                       "expected one retry of the broken source, got: \(log)")
    }

    func testAWorkingFirstSourceIsNotAbandoned() throws {
        var log: [String] = []
        try DistroInstaller.install(
            distro: .debian, sources: [try workingSource("First"), brokenSource],
            appSupportDir: destination) { log.append($0) }
        XCTAssertFalse(log.contains { $0.contains("Broken") },
                       "the second source should never have been reached: \(log)")
    }

    func testEveryFailureIsReportedWhenNoSourceWorks() throws {
        var thrown: Error?
        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .debian, sources: [brokenSource, brokenSource],
            appSupportDir: destination)) { thrown = $0 }
        let text = "\(thrown.map { "\($0)" } ?? "")"
        // Two sources, two attempts each.
        XCTAssertEqual(text.components(separatedBy: "attempt").count - 1, 4,
                       "every attempt should be listed: \(text)")
    }

    /// Cancelling must stop, not move on. Without this the person presses
    /// Cancel and watches the download restart up to four more times.
    func testCancellingDoesNotFallBackOrRetry() throws {
        let cancellation = DistroInstaller.InstallCancellation()
        cancellation.cancel()
        var log: [String] = []
        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .debian, sources: [try workingSource(), brokenSource],
            appSupportDir: destination,
            cancellation: cancellation) { log.append($0) }) { error in
            guard case DistroInstaller.InstallerError.cancelled = error else {
                return XCTFail("expected .cancelled, got \(error)")
            }
        }
        XCTAssertFalse(log.contains { $0.contains("retrying") }, "a cancel must not retry: \(log)")
    }

    // MARK: - Which sources are used

    func testHuggingFaceIsTriedBeforeSourceForge() {
        XCTAssertEqual(DistroInstaller.defaultSources.count, 2)
        XCTAssertEqual(DistroInstaller.defaultSources[0], DistroInstaller.huggingFaceSource)
        XCTAssertEqual(DistroInstaller.defaultSources[1], DistroInstaller.sourceForgeSource)
        XCTAssertTrue(DistroInstaller.huggingFaceSource.manifestURL.contains("huggingface.co"))
        XCTAssertTrue(DistroInstaller.sourceForgeSource.manifestURL.contains("sourceforge.net"))
    }

    /// An explicit choice means exactly that one. A test pointed at a local
    /// fixture must never quietly reach the real internet instead.
    func testAnExplicitManifestIsTheOnlySource() throws {
        let sources = try DistroInstaller.resolveSources(override: "file:///tmp/whatever.json")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].manifestURL, "file:///tmp/whatever.json")
    }

    /// The fallback against the **real** hosts, not a fixture.
    ///
    /// Skipped unless `MSL_LIVE_SOURCE_TEST=1`, because the rest of this
    /// suite must not need the internet. Run it after changing either
    /// published manifest:
    ///
    ///     MSL_LIVE_SOURCE_TEST=1 swift test --filter testLiveSourcesAnswer
    func testLiveSourcesAnswer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MSL_LIVE_SOURCE_TEST"] == "1",
                          "set MSL_LIVE_SOURCE_TEST=1 to check the published manifests")

        // Both real sources must serve a manifest naming the same distros,
        // or a fallback would quietly install something different.
        let hugging = try DistroInstaller.fetchManifest(from: DistroInstaller.huggingFaceSource.manifestURL)
        let sourceForge = try DistroInstaller.fetchManifest(from: DistroInstaller.sourceForgeSource.manifestURL)
        XCTAssertEqual(Set(hugging.distros.keys), Set(sourceForge.distros.keys),
                       "the two sources publish different distro sets")
        for (name, artifact) in hugging.distros {
            XCTAssertEqual(artifact.sha256, sourceForge.distros[name]?.sha256,
                           "\(name) differs between the two sources - a fallback would install other bytes")
        }
        XCTAssertEqual(hugging.kernel.sha256, sourceForge.kernel.sha256)
        XCTAssertEqual(hugging.initramfs.sha256, sourceForge.initramfs.sha256)

        // And an unreachable first source really does hand over.
        let broken = DistroInstaller.ImageSource(
            name: "unreachable", manifestURL: "https://huggingface.invalid/manifest.json")
        var reached: String?
        for source in [broken, DistroInstaller.sourceForgeSource] {
            if (try? DistroInstaller.fetchManifest(from: source.manifestURL)) != nil {
                reached = source.name
                break
            }
        }
        XCTAssertEqual(reached, DistroInstaller.sourceForgeSource.name)
    }

    func testInstallsKernelInitramfsAndImage() throws {
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "kernel-bytes"),
            initramfs: try publish("initramfs", "initramfs-bytes"),
            distros: ["debian": try publish("debian.img", "debian-rootfs")]))

        var log: [String] = []
        try DistroInstaller.install(
            distro: .debian, manifestURLString: manifestURL,
            appSupportDir: destination) { log.append($0) }

        let kernel = destination.appendingPathComponent("disk-Image")
        let initrd = destination.appendingPathComponent("disk-initramfs-virt")
        let image = destination.appendingPathComponent(GuestDistro.debian.diskImageFilename)
        XCTAssertEqual(try String(contentsOf: kernel, encoding: .utf8), "kernel-bytes")
        XCTAssertEqual(try String(contentsOf: initrd, encoding: .utf8), "initramfs-bytes")
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "debian-rootfs")
        XCTAssertFalse(log.isEmpty, "progress must be reported - the GUI renders these")
    }

    /// Every distro shares one kernel, so a second install must not refetch
    /// it. This is the difference between a 300 MB install and a 4 GB one.
    func testSharedKernelIsNotReinstalled() throws {
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "kernel-bytes"),
            initramfs: try publish("initramfs", "initramfs-bytes"),
            distros: ["debian": try publish("debian.img", "debian-rootfs"),
                      "ubuntu": try publish("ubuntu.img", "ubuntu-rootfs")]))

        try DistroInstaller.install(distro: .debian, manifestURLString: manifestURL, appSupportDir: destination)
        var log: [String] = []
        try DistroInstaller.install(
            distro: .ubuntu, manifestURLString: manifestURL, appSupportDir: destination) { log.append($0) }

        XCTAssertTrue(log.contains { $0.contains("kernel already installed") })
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent(GuestDistro.ubuntu.diskImageFilename), encoding: .utf8),
            "ubuntu-rootfs")
        // ...and installing ubuntu must not have disturbed debian.
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent(GuestDistro.debian.diskImageFilename), encoding: .utf8),
            "debian-rootfs")
    }

    /// A corrupted download must never be installed - the whole point of
    /// verifying before the rename.
    func testChecksumMismatchLeavesNothingBehind() throws {
        var bad = try publish("debian.img", "debian-rootfs")
        bad = DistroInstaller.Artifact(
            version: bad.version, url: bad.url,
            sha256: String(repeating: "0", count: 64), size: bad.size)
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "kernel-bytes"),
            initramfs: try publish("initramfs", "initramfs-bytes"),
            distros: ["debian": bad]))

        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .debian, manifestURLString: manifestURL, appSupportDir: destination))

        let image = destination.appendingPathComponent(GuestDistro.debian.diskImageFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path),
                       "a failed verification must not leave a partial image in place")
        // And no temporary leftovers in the destination directory.
        let stray = (try FileManager.default.contentsOfDirectory(atPath: destination.path))
            .filter { $0.contains("debian") }
        XCTAssertTrue(stray.isEmpty, "leftovers: \(stray)")
    }

    func testUnknownDistroReportsWhatIsAvailable() throws {
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "k"),
            initramfs: try publish("initramfs", "i"),
            distros: ["debian": try publish("debian.img", "d")]))

        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .arch, manifestURLString: manifestURL, appSupportDir: destination)) { error in
            XCTAssertTrue("\(error)".contains("debian"), "the error should name what IS available: \(error)")
        }
    }

    func testUnreachableManifestFails() {
        XCTAssertThrowsError(try DistroInstaller.fetchManifest(
            from: "file://" + root.appendingPathComponent("nope.json").path))
    }

    // MARK: - Compressed images

    /// A disk-image-shaped payload: mostly zeros, with a megabyte of
    /// incompressible data in the middle (at least 2 MiB total) and a last
    /// byte that isn't zero, so the length can't come from written data alone.
    private func sparseImage(megabytes: Int) -> Data {
        precondition(megabytes >= 2)
        var data = Data(count: megabytes << 20)
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let start = (megabytes / 2) << 20
        data.replaceSubrange(start..<(start + (1 << 20) - 1), with: noise.prefix((1 << 20) - 1))
        data[data.count - 1] = 0x42
        return data
    }

    /// Publishes `raw` xz-compressed, the way the image catalog does.
    private func publishCompressed(_ name: String, _ raw: Data, installedSize: UInt64? = nil,
                                   compression: String = "xz") throws -> DistroInstaller.Artifact {
        let compressed = try (raw as NSData).compressed(using: .lzma) as Data
        let url = served.appendingPathComponent(name)
        try compressed.write(to: url)
        let digest = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        return DistroInstaller.Artifact(
            version: "1.0", url: "file://" + url.path, sha256: digest, size: UInt64(compressed.count),
            compression: compression, installedSize: installedSize ?? UInt64(raw.count))
    }

    func testCompressedImageIsUnpackedByteForByteAndStaysSparse() throws {
        let raw = sparseImage(megabytes: 32)
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "k"),
            initramfs: try publish("initramfs", "i"),
            distros: ["debian": try publishCompressed("debian.img.xz", raw)]))

        try DistroInstaller.install(distro: .debian, manifestURLString: manifestURL, appSupportDir: destination)

        let image = destination.appendingPathComponent(GuestDistro.debian.diskImageFilename)
        XCTAssertEqual(try Data(contentsOf: image), raw, "the unpacked image must be identical to what was compressed")

        // Compared with the best this volume can do, not a fixed number: APFS
        // allocates small unwritten gaps next to written data as real zeros,
        // so even a file made with truncate and two writes isn't 1 MiB. The
        // unpacked image must be no worse than that, and far from dense.
        let reference = root.appendingPathComponent("reference.img")
        FileManager.default.createFile(atPath: reference.path, contents: nil)
        let handle = try FileHandle(forWritingTo: reference)
        try handle.truncate(atOffset: UInt64(raw.count))
        let start = raw.count / 2 / (1 << 20) * (1 << 20)
        try handle.seek(toOffset: UInt64(start))
        try handle.write(contentsOf: raw.subdata(in: start..<(start + (1 << 20))))
        try handle.seek(toOffset: UInt64(raw.count - 1))
        try handle.write(contentsOf: Data([0x42]))
        try handle.close()

        let unpacked = DiskStorage.allocatedSize(of: image.path)
        XCTAssertLessThanOrEqual(unpacked, DiskStorage.allocatedSize(of: reference.path) + UInt64(1 << 20),
                                 "all-zero blocks must be skipped, not written")
        XCTAssertLessThan(unpacked, UInt64(raw.count), "a mostly-empty image must not unpack fully allocated")
    }

    func testUnpackedSizeMustMatchTheManifest() throws {
        let raw = sparseImage(megabytes: 4)
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "k"),
            initramfs: try publish("initramfs", "i"),
            distros: ["debian": try publishCompressed("debian.img.xz", raw, installedSize: UInt64(raw.count) + 1)]))

        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .debian, manifestURLString: manifestURL, appSupportDir: destination))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.contains("debian") }
        XCTAssertTrue(leftovers.isEmpty, "a size mismatch installs nothing and cleans up: \(leftovers)")
    }

    func testUnknownCompressionIsRefused() throws {
        let manifestURL = try writeManifest(DistroInstaller.Manifest(
            kernel: try publish("Image", "k"),
            initramfs: try publish("initramfs", "i"),
            distros: ["debian": try publishCompressed("debian.img.zst", sparseImage(megabytes: 2), compression: "zstd")]))

        XCTAssertThrowsError(try DistroInstaller.install(
            distro: .debian, manifestURLString: manifestURL, appSupportDir: destination)) { error in
            XCTAssertTrue("\(error)".contains("zstd"), "should say which format it can't unpack: \(error)")
        }
    }

    func testCorruptCompressedDataFailsCleanly() throws {
        let url = served.appendingPathComponent("broken.xz")
        var bytes = try (sparseImage(megabytes: 2) as NSData).compressed(using: .lzma) as Data
        bytes.replaceSubrange(40..<80, with: Data(repeating: 0xAB, count: 40))
        try bytes.write(to: url)
        let out = root.appendingPathComponent("out.img")
        XCTAssertThrowsError(try ImageDecompressor.decompress(.xz, from: url, to: out))
    }

    func testManifestWithoutCompressionFieldsStillDecodes() throws {
        let json = #"{"kernel":{"version":"1","url":"u","sha256":"s","size":1},"initramfs":{"version":"1","url":"u","sha256":"s","size":1},"distros":{}}"#
        let manifest = try JSONDecoder().decode(DistroInstaller.Manifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.kernel.compression, "manifests from before compressed images must keep working")
    }
}

// MARK: - Download progress

/// The line under the progress bar must not change width as it counts.
///
/// It used to: `ByteCountFormatter` chose its unit and decimals per call, and
/// the rate disappeared whenever a sample saw no growth - so the text jumped
/// shorter every few seconds and the whole block jiggled (reported
/// 2026-10-01).
final class TransferProgressTests: XCTestCase {
    private func line(_ completed: UInt64, _ total: UInt64, _ rate: Double) -> String {
        DistroInstaller.TransferProgress(completed: completed, total: total,
                                         bytesPerSecond: rate).description
    }

    func testWidthStaysConstantThroughoutADownload() {
        let total: UInt64 = 534 * 1_000_000
        var widths = Set<Int>()
        // Every percent of the way, at wildly different speeds.
        for percent in 0...100 {
            let done = UInt64(Double(total) * Double(percent) / 100)
            let rate = Double((percent % 17) + 1) * 500_000
            widths.insert(line(done, total, rate).count)
        }
        XCTAssertEqual(widths.count, 1,
                       "the line changes width as it counts: \(widths.sorted())")
    }

    func testRateIsAlwaysShownEvenAtZero() {
        // A sample that sees no growth must not make the figure vanish - that
        // was half the jitter.
        XCTAssertTrue(line(100_000_000, 534_000_000, 0).contains("MB/s"))
    }

    func testUnitDoesNotSwitchMidDownload() {
        // Chosen from the total, so a download that starts in MB stays in MB.
        let total: UInt64 = 900 * 1_000_000
        XCTAssertTrue(line(1, total, 1).hasSuffix("MB/s"))
        XCTAssertTrue(line(1, total, 1).contains(" of 900.0 MB"))
        XCTAssertTrue(line(total, total, 1).contains(" of 900.0 MB"))
    }

    func testGigabyteDownloadsReadInGB() {
        let total: UInt64 = 3 * 1_000_000_000
        XCTAssertTrue(line(total / 2, total, 1).contains("of 3.0 GB"))
    }

    func testFractionIsClampedAndSafeAtZeroTotal() {
        XCTAssertEqual(DistroInstaller.TransferProgress(completed: 5, total: 0, bytesPerSecond: 0).fraction, 0)
        XCTAssertEqual(DistroInstaller.TransferProgress(completed: 20, total: 10, bytesPerSecond: 0).fraction, 1)
    }
}

/// A distribution is downloaded once and kept.
///
/// Every instance of it is cloned from that base, so re-fetching a few
/// hundred megabytes to replace a byte-identical file is pure waste - which
/// is what `msl install` did for a distro you already had, because only the
/// kernel and initramfs were being skipped.
final class BaseIsKeptTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    private var disk: URL { GuestDistro.debian.baseImageURL(appSupport: support) }

    func testAnUnrecordedBaseIsNotTreatedAsDownloaded() throws {
        try Data("image".utf8).write(to: disk)
        XCTAssertNil(DistroInstaller.installedMarker(for: disk))
    }

    func testARecordedBaseIsRecognisedByItsChecksum() throws {
        try Data("image".utf8).write(to: disk)
        DistroInstaller.recordInstalled("abc123", for: disk)
        XCTAssertEqual(DistroInstaller.installedMarker(for: disk), "abc123")
    }

    /// A new release has a different checksum, so it still downloads.
    func testADifferentChecksumMeansADifferentRelease() throws {
        try Data("image".utf8).write(to: disk)
        DistroInstaller.recordInstalled("old", for: disk)
        XCTAssertNotEqual(DistroInstaller.installedMarker(for: disk), "new")
    }

    /// Deleting the image by hand must not leave MSL believing it is there.
    func testTheRecordMeansNothingWithoutTheImage() throws {
        try Data("image".utf8).write(to: disk)
        DistroInstaller.recordInstalled("abc123", for: disk)
        try FileManager.default.removeItem(at: disk)
        XCTAssertNil(DistroInstaller.installedMarker(for: disk),
                     "a record without an image would skip a download that is genuinely needed")
    }
}
