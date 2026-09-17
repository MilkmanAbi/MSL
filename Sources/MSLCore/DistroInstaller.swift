// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Fetches and installs a distro's prebuilt image (plus the shared kernel/
/// initramfs every distro boots with - see `GuestDistro`'s doc comment) from
/// a remote manifest, so `msl install <distro>` works without building
/// anything locally - `Linux-Side/image-build/` remains the tool that
/// *produces* the images this consumes.
///
/// Design deliberately mirrors OneInstallSystem's (github.com/MilkmanAbi/
/// OneInstallSystem) update pipeline, adapted from "fetch a CLI binary from
/// GitHub releases" to "fetch a multi-gigabyte disk image from wherever the
/// image catalog ends up living" - the same three disciplines carry over
/// directly and are exactly the ones worth keeping from a project that's
/// already fought through the edge cases:
///   1. **Verify before trust.** sha256 is checked against the manifest
///      *before* the file is ever unpacked or moved to its real destination
///      path - nothing overwrites a working install with an unverified
///      download.
///   2. **Atomic swap.** Download (and unpack) to temp files in the *same
///      directory* as the destination, then `rename(2)`. A crash or Ctrl-C
///      mid-download leaves temp files behind (cleaned up next run) and the
///      real destination untouched - never a half-written, corrupt image.
///   3. **A manifest is the source of truth**, not directory-listing
///      guesses - name, version, url, sha256, size, all explicit.
public enum DistroInstaller {
    public struct Artifact: Codable, Equatable {
        public let version: String
        public let url: String
        /// Of the file at `url` - the compressed download, when there is one.
        public let sha256: String
        /// Of the file at `url`.
        public let size: UInt64
        /// How the file at `url` is compressed (`"xz"`), or nil for a raw
        /// file. Absent from manifests written before compressed images.
        public let compression: String?
        /// The installed (decompressed) length, checked after unpacking.
        public let installedSize: UInt64?

        public init(version: String, url: String, sha256: String, size: UInt64,
                    compression: String? = nil, installedSize: UInt64? = nil) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.compression = compression
            self.installedSize = installedSize
        }
    }

    /// The manifest published alongside the images themselves - one file,
    /// fetched fresh on every `msl install` (these are multi-gigabyte
    /// one-time downloads, not something to cache/throttle the way OIS
    /// throttles its own frequent update-check polling).
    public struct Manifest: Codable {
        public let kernel: Artifact
        public let initramfs: Artifact
        public let distros: [String: Artifact]

        public init(kernel: Artifact, initramfs: Artifact, distros: [String: Artifact]) {
            self.kernel = kernel
            self.initramfs = initramfs
            self.distros = distros
        }
    }

    public enum InstallerError: Error, CustomStringConvertible {
        case manifestFetchFailed(String, Int32)
        case manifestDecodeFailed(String)
        case unknownDistro(String, known: [String])
        case downloadFailed(String, Int32)
        case checksumMismatch(String, expected: String, actual: String)
        case unsupportedCompression(String, url: String)
        case installedSizeMismatch(String, expected: UInt64, actual: UInt64)
        case customImage(String)

        public var description: String {
            switch self {
            case .manifestFetchFailed(let url, let status):
                return "couldn't fetch manifest from \(url) (curl exited \(status))"
            case .manifestDecodeFailed(let reason):
                return "manifest is not valid JSON in the expected shape: \(reason)"
            case .unknownDistro(let name, let known):
                return "'\(name)' isn't in the manifest - available: \(known.joined(separator: ", "))"
            case .downloadFailed(let url, let status):
                return "download failed for \(url) (curl exited \(status))"
            case .checksumMismatch(let url, let expected, let actual):
                return "sha256 mismatch for \(url) - expected \(expected), got \(actual). Download corrupted or manifest is stale; not installed."
            case .unsupportedCompression(let compression, let url):
                return "\(url) is compressed as '\(compression)', which this version of MSL can't unpack - update MSL. Not installed."
            case .installedSizeMismatch(let url, let expected, let actual):
                return "\(url) unpacked to \(actual) bytes, but the manifest says \(expected). Not installed."
            case .customImage(let slug):
                return "custom:\(slug) is a custom image - there's nothing to download. Put its Image, initramfs and rootfs.img in Custom Images/\(slug) (`msl images open`)."
            }
        }
    }

    /// The published image catalog, on SourceForge's file release system.
    ///
    /// A manifest at the project's root, whose entries point into a dated
    /// release folder (`msl-images-<date>/`). A new release is a new folder
    /// plus a new root manifest, so this URL never changes and old versions of
    /// MSL keep finding current images. `downloads.sourceforge.net` redirects
    /// to a mirror, which the installer's `curl -fL` follows. Overridable via
    /// `MSL_MANIFEST_URL` (or the `--manifest` flag `msl install` accepts)
    /// for testing against a local fixture without touching the real
    /// multi-gigabyte images - see `Sources/msl/main.swift`.
    public static let defaultManifestURLString =
        "https://downloads.sourceforge.net/project/msl-files/manifest.json"

    public static func resolveManifestURLString(override: String?) -> String {
        override ?? ProcessInfo.processInfo.environment["MSL_MANIFEST_URL"] ?? defaultManifestURLString
    }

    public static func fetchManifest(from urlString: String) throws -> Manifest {
        let data = try runCurl(url: urlString)
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw InstallerError.manifestDecodeFailed("\(error)")
        }
    }

    /// How much room a freshly installed image gets straight away. Images
    /// are published as small filesystems (4 GiB) to keep unpacking quick;
    /// growing the sparse file costs the Mac nothing, and the guest's
    /// filesystem follows on first boot (`DiskStorage`'s pending resize).
    static let installedStartingCapacity: UInt64 = StoragePolicy.defaultSize

    /// Downloads and installs `distro`'s image plus the shared kernel/
    /// initramfs (skipped if already present - every distro shares them,
    /// so only the very first `msl install` of any distro needs to fetch
    /// them at all). `progress` receives human-readable status lines,
    /// suitable for writing straight to stderr.
    public static func install(distro: GuestDistro, manifestURLString: String, appSupportDir: URL, progress: ((String) -> Void)? = nil) throws {
        // A custom image is installed by putting its files in its folder;
        // there is nothing to download.
        if let slug = distro.customSlug { throw InstallerError.customImage(slug) }
        // A download of several gigabytes shouldn't die because the display
        // slept. Held for the whole install, from the app and from `msl
        // install` alike, and only for a real install - the tests install
        // into scratch directories and have no reason to keep a Mac awake.
        let awake = appSupportDir.standardizedFileURL.path == MSLPaths.appSupport.standardizedFileURL.path
            ? KeepAwake() : nil
        defer { awake?.release() }
        if awake?.isHolding == true {
            progress?("keeping your Mac awake until the install finishes")
        }
        progress?("fetching manifest from \(manifestURLString) ...")
        let manifest = try fetchManifest(from: manifestURLString)
        guard let distroArtifact = manifest.distros[distro.rawValue] else {
            throw InstallerError.unknownDistro(distro.rawValue, known: Array(manifest.distros.keys).sorted())
        }

        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let kernelDest = appSupportDir.appendingPathComponent("disk-Image")
        let initrdDest = appSupportDir.appendingPathComponent("disk-initramfs-virt")
        let diskDest = appSupportDir.appendingPathComponent(distro.diskImageFilename)

        if FileManager.default.fileExists(atPath: kernelDest.path) {
            progress?("kernel already installed, skipping (shared across every distro)")
        } else {
            try downloadAndVerify(manifest.kernel, to: kernelDest, progress: progress)
        }
        if FileManager.default.fileExists(atPath: initrdDest.path) {
            progress?("initramfs already installed, skipping (shared across every distro)")
        } else {
            try downloadAndVerify(manifest.initramfs, to: initrdDest, progress: progress)
        }
        try downloadAndVerify(distroArtifact, to: diskDest, progress: progress)

        // Storage policies live in the real Application Support directory
        // only (`DiskStorage`), so a test installing into a scratch
        // directory must not touch them.
        if appSupportDir.standardizedFileURL.path == MSLPaths.appSupport.standardizedFileURL.path {
            prepareStorage(forInstalledImage: diskDest, distro: distro, progress: progress)
            // The remembered default user's account lived on the disk that
            // was just replaced. Keeping it pointed every new session at a
            // user the fresh image doesn't have: shellinit refuses an
            // unknown user with a silent exit 127, so the terminal died
            // straight after its banner and the app never offered account
            // setup, since it believed one already existed.
            if LinuxUserSetup.registry().defaultUser(for: distro) != nil {
                try? LinuxUserSetup.registry().forgetDefaultUser(for: distro)
                progress?("fresh disk: MSL will ask which Linux account to use on first start")
            }
        }
    }

    /// Gives a just-installed image a storage policy and room to work.
    ///
    /// Without this an installed image had no stored policy, so `DiskStorage`
    /// described it as exactly its published size with auto-grow off - a
    /// 4 GiB disk that never grew. A reinstall keeps whatever policy the
    /// user already chose for the distro.
    static func prepareStorage(forInstalledImage image: URL, distro: GuestDistro, progress: ((String) -> Void)?) {
        let name = distro.diskImageFilename
        let policy: StoragePolicy
        if let stored = DiskStorage.storedPolicy(forImageNamed: name) {
            policy = stored
        } else {
            policy = StoragePolicy()
            DiskStorage.setPolicy(policy, forImageNamed: name)
        }
        let target = policy.mode == .fixed ? policy.size : min(policy.size, installedStartingCapacity)
        guard target > DiskStorage.capacity(of: image.path) else { return }
        do {
            var lastTenth = -1
            try DiskStorage.setCapacity(of: image.path, to: target, reserveSpace: policy.mode == .fixed) { update in
                // Every 10%, so a log or the app's install sheet isn't flooded.
                let tenth = Int(update.fraction * 10)
                guard tenth != lastTenth else { return }
                lastTenth = tenth
                progress?("reserving disk space: \(Int(update.fraction * 100))% - \(update.description)")
            }
            DiskStorage.markFilesystemResizePending(forImageNamed: name)
            progress?("disk is \(DiskStorage.format(target)); Linux's filesystem grows to fill it on first start")
        } catch {
            // Not fatal: the image is installed and boots at its published
            // size, and the Storage card can grow it later.
            progress?("couldn't enlarge the disk yet (\(error)) - it starts at its published size")
        }
    }

    /// Downloads `artifact.url`, verifies its sha256 against
    /// `artifact.sha256`, unpacks it if it's compressed, and only then
    /// atomically installs it at `destination` - see the type's doc comment
    /// on why in this order, never the reverse.
    public static func downloadAndVerify(_ artifact: Artifact, to destination: URL, progress: ((String) -> Void)? = nil) throws {
        // In the SAME directory as the destination, not /tmp - rename(2)
        // cannot cross filesystems, and this project's own disk images
        // already live on whatever volume Application Support is on.
        let directory = destination.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmpURL = directory.appendingPathComponent(".\(destination.lastPathComponent).download-\(pid)")
        let unpackedURL = directory.appendingPathComponent(".\(destination.lastPathComponent).unpacked-\(pid)")
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
            try? FileManager.default.removeItem(at: unpackedURL)
        }

        // Refused before downloading anything: an unknown format can't be
        // installed however the download goes.
        var format: ImageDecompressor.Format?
        if let compression = artifact.compression {
            guard let known = ImageDecompressor.Format(rawValue: compression) else {
                throw InstallerError.unsupportedCompression(compression, url: artifact.url)
            }
            format = known
        }

        progress?("downloading \(artifact.url) (\(formatBytes(artifact.size))) ...")
        try runCurlToFile(url: artifact.url, destination: tmpURL)

        progress?("verifying sha256 ...")
        let actualHash = try sha256Hex(of: tmpURL)
        guard actualHash.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw InstallerError.checksumMismatch(artifact.url, expected: artifact.sha256, actual: actualHash)
        }

        var ready = tmpURL
        if let format {
            let label = artifact.installedSize.map { " to \(formatBytes($0))" } ?? ""
            progress?("unpacking\(label) ...")
            let written = try ImageDecompressor.decompress(format, from: tmpURL, to: unpackedURL)
            if let expected = artifact.installedSize, expected != written {
                throw InstallerError.installedSizeMismatch(artifact.url, expected: expected, actual: written)
            }
            ready = unpackedURL
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: ready, to: destination)
        progress?("installed \(destination.lastPathComponent)")
    }

    // MARK: - curl / hashing

    private static func runCurl(url: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fsSL", url]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallerError.manifestFetchFailed(url, process.terminationStatus)
        }
        return data
    }

    /// `--progress-bar` writes curl's own progress indicator to stderr,
    /// inherited as-is (not captured) - a multi-gigabyte download benefits
    /// from curl's own battle-tested progress rendering far more than
    /// anything worth hand-rolling here.
    private static func runCurlToFile(url: String, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fL", "--progress-bar", "-o", destination.path, url]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallerError.downloadFailed(url, process.terminationStatus)
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
