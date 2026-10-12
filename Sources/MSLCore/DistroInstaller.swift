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
        case cancelled(String)
        case allSourcesFailed([String])

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
            case .cancelled(let what):
                return "\(what) was cancelled; the part that had downloaded has been deleted."
            case .allSourcesFailed(let attempts):
                // Every attempt, not just the last: the last one is often the
                // least informative ("SourceForge timed out") while the first
                // says what actually went wrong.
                return "couldn't download from any image source.\n"
                    + attempts.map { "  - \($0)" }.joined(separator: "\n")
            }
        }
    }

    /// Somewhere the published images can be fetched from.
    ///
    /// MSL publishes the same files, with the same checksums, to more than
    /// one host. The manifest at each one points at its own copies, so a
    /// source is picked whole: its manifest and the files that manifest
    /// names. Falling back halfway - one host's manifest with another's
    /// files - would be the one combination nobody tested.
    public struct ImageSource: Sendable, Equatable {
        /// What to call it in a progress line, so "trying SourceForge
        /// instead" is something a person can act on.
        public let name: String
        public let manifestURL: String

        public init(name: String, manifestURL: String) {
            self.name = name
            self.manifestURL = manifestURL
        }
    }

    /// Hugging Face, tried first: measured several times faster than
    /// SourceForge from Asia (2026-10-01), which is most of what an install
    /// is. Files are served from the dataset's `resolve/main`, which is a
    /// stable URL per release.
    public static let huggingFaceSource = ImageSource(
        name: "Hugging Face",
        manifestURL: "https://huggingface.co/datasets/MilkmanAbi/MSL-Images/resolve/main/manifest.json")

    /// SourceForge's file release system, the fallback.
    ///
    /// A manifest at the project's root, whose entries point into a dated
    /// release folder (`msl-images-<date>/`). A new release is a new folder
    /// plus a new root manifest, so this URL never changes and old versions of
    /// MSL keep finding current images. `downloads.sourceforge.net` redirects
    /// to a mirror, which the installer's `curl -fL` follows.
    public static let sourceForgeSource = ImageSource(
        name: "SourceForge",
        manifestURL: "https://downloads.sourceforge.net/project/msl-files/manifest.json")

    /// Where images come from, in the order they are tried.
    public static let defaultSources = [huggingFaceSource, sourceForgeSource]

    /// How many times one source is tried before moving to the next.
    ///
    /// Two, because the failure this exists for is a transient one - a CDN
    /// closing a connection mid-transfer, which is exactly what SourceForge
    /// did on the first real install (`curl exited 18`, with the file intact
    /// on the server). curl already retries *within* a transfer; this is the
    /// larger retry, covering a manifest that would not parse or a file whose
    /// checksum came back wrong.
    public static let attemptsPerSource = 2

    /// The first source's manifest. Kept for callers that want a single URL.
    public static var defaultManifestURLString: String { defaultSources[0].manifestURL }

    /// The sources to try, honouring an explicit choice.
    ///
    /// `MSL_MANIFEST_URL` or `--manifest` means *that* manifest and nothing
    /// else: it is how the tests point at a local fixture, and silently
    /// falling back to the real internet would make a failing fixture look
    /// like a passing test.
    public static func resolveSources(override: String?) throws -> [ImageSource] {
        if let chosen = override ?? ProcessInfo.processInfo.environment["MSL_MANIFEST_URL"] {
            // `distro.source`. An override points MSL's installer at a
            // manifest - and so at kernels and root filesystems - that
            // nobody at MSL published, which is the same trust boundary as
            // a custom image or an imported shipment. A managed deployment
            // that allows installing Debian does not necessarily allow
            // installing somebody's Debian.
            //
            // **Thrown, never quietly ignored.** Falling back to the real
            // sources would have been the tempting "safe" answer, and it is
            // the wrong one twice over: the person would get an install they
            // did not ask for, and `MSL_MANIFEST_URL` is how the tests point
            // at a local fixture, so a silent fallback would send a failing
            // test to the actual internet and call it a pass.
            guard MSLAPGate.allows("distro.source", instance: nil) else {
                throw MSLAPRefusal(MSLAPGate.reason("distro.source", instance: nil)
                                   ?? "Not allowed by the MSL Admin Portal")
            }
            return [ImageSource(name: "the manifest you chose", manifestURL: chosen)]
        }
        return defaultSources
    }

    public static func resolveManifestURLString(override: String?) throws -> String {
        try resolveSources(override: override)[0].manifestURL
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

    /// How far a download has got, for a progress bar.
    ///
    /// Separate from the `progress` status lines because a spinner and a
    /// sentence cannot answer the only question someone watching a
    /// half-gigabyte transfer actually has - is this moving, or has it hung?
    ///
    /// Measured by watching the file grow rather than by parsing curl's
    /// output: the size is already known from the manifest, the destination
    /// is ours, and there is nothing to misparse.
    public struct TransferProgress: Sendable {
        /// Bytes on disk so far.
        public let completed: UInt64
        /// Bytes expected in total, from the manifest.
        public let total: UInt64
        /// Recent rate, not an average since the start, so it reflects what
        /// the connection is doing now.
        public let bytesPerSecond: Double

        public var fraction: Double {
            total > 0 ? min(1, Double(completed) / Double(total)) : 0
        }

        /// "243.1 MB of 534.0 MB - 7.8 MB/s", ready to put under a progress bar.
        ///
        /// **Deliberately a fixed shape.** `ByteCountFormatter` picks its unit
        /// per call and drops decimals as it likes, so the line changed width
        /// constantly and the whole block jiggled; and when a sample happened
        /// to see no growth the rate vanished entirely, so the text jumped
        /// shorter every few seconds (reported 2026-10-01). Here the unit for
        /// the sizes is chosen once from the *total*, so it never switches
        /// mid-download, both numbers always carry one decimal, and the rate
        /// is always MB/s - 0.4 MB/s rather than flipping to 400 KB/s.
        public var description: String {
            let megabyte = 1_000_000.0
            let gigabyte = 1_000_000_000.0
            let useGB = Double(total) >= gigabyte
            let unit = useGB ? "GB" : "MB"
            let divisor = useGB ? gigabyte : megabyte

            // Padded with FIGURE SPACE (U+2007), which is exactly as wide as
            // a digit. `monospacedDigit()` makes digits equal width but does
            // nothing about how MANY of them there are, so "9.4 of 534.0" and
            // "412.7 of 534.0" still differed by two characters and the line
            // visibly jumped. An ordinary space would not do: in a
            // proportional face it is narrower than a digit.
            func padded(_ value: Double, toWidthOf reference: String) -> String {
                let text = String(format: "%.1f", value)
                guard text.count < reference.count else { return text }
                return String(repeating: "\u{2007}", count: reference.count - text.count) + text
            }

            let all = String(format: "%.1f", Double(total) / divisor)
            let done = padded(Double(completed) / divisor, toWidthOf: all)
            // Five columns fits anything up to 999.9 MB/s.
            let rate = padded(bytesPerSecond / megabyte, toWidthOf: "999.9")
            return "\(done) of \(all) \(unit) - \(rate) MB/s"
        }
    }

    /// A handle for stopping an install that is already running.
    ///
    /// The work is a blocking call on a background thread with a child
    /// `curl` doing the actual transfer, so cancelling means terminating
    /// that child: the download then fails, and `downloadAndVerify`'s
    /// existing `defer` deletes the half-finished file on the way out. There
    /// is nothing left behind to clean up later.
    public final class InstallCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Process?
        private var stopped = false

        public init() {}

        /// Stops the install as soon as it can. Safe to call more than once,
        /// and safe to call before the download has started - the flag is
        /// checked at every step, so an early cancel is not missed.
        public func cancel() {
            lock.lock()
            stopped = true
            let process = current
            lock.unlock()
            process?.terminate()
        }

        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        /// Registers the process to kill. Returns false if cancellation
        /// already happened, so the caller never starts it at all.
        fileprivate func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            current = process
            return true
        }

        fileprivate func release() {
            lock.lock(); current = nil; lock.unlock()
        }
    }

    /// Installs `distro` from the first source that works.
    ///
    /// Each source is tried `attemptsPerSource` times before moving on, and
    /// a source is taken whole - its manifest and the files that manifest
    /// names. This is what both `msl install` and the app call, so they
    /// behave identically; the single-source overload below is what an
    /// explicit `--manifest` (and every test) uses.
    ///
    /// Anything already on disk is skipped by the single-source install, so
    /// falling back does not re-fetch a kernel that arrived from the first
    /// source. A part-downloaded file is deleted as its attempt unwinds, so
    /// no attempt inherits another's leftovers.
    public static func install(distro: GuestDistro, sources: [ImageSource], appSupportDir: URL,
                               force: Bool = false,
                               cancellation: InstallCancellation? = nil,
                               progress: ((String) -> Void)? = nil,
                               transfer: ((TransferProgress) -> Void)? = nil) throws {
        // Downloading a distro is how a managed Mac gains something new to
        // run, so it is app-wide rather than per-instance: no instance
        // exists yet to name.
        guard MSLAPGate.allows("distro.install", instance: nil) else {
            throw MSLAPRefusal(MSLAPGate.reason("distro.install", instance: nil)
                               ?? "Not allowed by the MSL Admin Portal")
        }
        if let slug = distro.customSlug { throw InstallerError.customImage(slug) }
        guard !sources.isEmpty else {
            throw InstallerError.allSourcesFailed(["no image sources were configured"])
        }

        var failures: [String] = []
        for source in sources {
            for attempt in 1...attemptsPerSource {
                // Checked before every attempt: without this, cancelling
                // during a download would be answered by starting the next
                // attempt, and a person pressing Cancel would watch it begin
                // again - up to four times.
                if cancellation?.isCancelled == true {
                    throw InstallerError.cancelled(distro.rawValue)
                }
                if failures.isEmpty {
                    progress?("downloading from \(source.name) ...")
                } else {
                    progress?("retrying from \(source.name) (attempt \(attempt)) ...")
                }
                do {
                    try install(distro: distro, manifestURLString: source.manifestURL,
                                appSupportDir: appSupportDir, force: force, cancellation: cancellation,
                                progress: progress, transfer: transfer)
                    return
                } catch let error as InstallerError {
                    switch error {
                    case .cancelled, .customImage:
                        // Not a source problem - trying somewhere else would
                        // be wrong, and for a cancel actively unwanted.
                        throw error
                    default:
                        failures.append("\(source.name), attempt \(attempt): \(error.description)")
                    }
                } catch {
                    failures.append("\(source.name), attempt \(attempt): \(error)")
                }
            }
            progress?("\(source.name) didn't work")
        }
        throw InstallerError.allSourcesFailed(failures)
    }

    /// Downloads and installs `distro`'s image plus the shared kernel/
    /// initramfs (skipped if already present - every distro shares them,
    /// so only the very first `msl install` of any distro needs to fetch
    /// them at all). `progress` receives human-readable status lines,
    /// suitable for writing straight to stderr; `transfer`, if given, is
    /// called repeatedly while bytes are arriving.
    ///
    /// One source only. Use the `sources:` overload for the real install
    /// path, which falls back when a host is down or slow.
    public static func install(distro: GuestDistro, manifestURLString: String, appSupportDir: URL,
                               force: Bool = false,
                               cancellation: InstallCancellation? = nil,
                               progress: ((String) -> Void)? = nil,
                               transfer: ((TransferProgress) -> Void)? = nil) throws {
        // Downloading a distro is how a managed Mac gains something new to
        // run, so it is app-wide rather than per-instance: no instance
        // exists yet to name.
        guard MSLAPGate.allows("distro.install", instance: nil) else {
            throw MSLAPRefusal(MSLAPGate.reason("distro.install", instance: nil)
                               ?? "Not allowed by the MSL Admin Portal")
        }
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
            try downloadAndVerify(manifest.kernel, to: kernelDest, progress: progress, transfer: transfer, cancellation: cancellation)
        }
        if FileManager.default.fileExists(atPath: initrdDest.path) {
            progress?("initramfs already installed, skipping (shared across every distro)")
        } else {
            try downloadAndVerify(manifest.initramfs, to: initrdDest, progress: progress, transfer: transfer, cancellation: cancellation)
        }
        // **A base that is already here is not downloaded again.** It is
        // downloaded once and kept: every instance of the distro is cloned
        // from it, and nothing ever boots or writes it, so a second instance
        // of a distro you already have costs nothing and takes no network.
        // Only the kernel and initramfs were skipped before, so `msl install`
        // on a distro you already had fetched a few hundred megabytes to
        // replace a byte-identical file.
        //
        // Recognised by a **marker beside the base**, not by the base's own
        // size or hash. Size cannot work: `prepareStorage` below grows the
        // base to the configured disk size straight after downloading it, so
        // it never again matches the published figure. Hashing cannot work
        // cheaply either - it is a 15 GB sparse file, and re-reading it to
        // prove what we already know would cost more than the download it
        // saves.
        //
        // So the install records the published checksum of what it fetched,
        // and that is what the next install compares. A new release has a new
        // checksum and downloads; the same release does not. `force` redoes
        // it regardless, for a base that is damaged rather than stale.
        if !force, installedMarker(for: diskDest) == distroArtifact.sha256 {
            progress?("\(distro.rawValue) is already downloaded - every instance is cloned from it, so there is nothing to fetch")
        } else {
            try downloadAndVerify(distroArtifact, to: diskDest, progress: progress, transfer: transfer, cancellation: cancellation)
            recordInstalled(distroArtifact.sha256, for: diskDest)
        }

        // Storage policies live in the real Application Support directory
        // only (`DiskStorage`), so a test installing into a scratch
        // directory must not touch them.
        if appSupportDir.standardizedFileURL.path == MSLPaths.appSupport.standardizedFileURL.path {
            prepareStorage(forInstalledImage: diskDest, distro: distro, progress: progress)
            // Nothing is forgotten here any more. This replaces the *base* -
            // the image new instances are cloned from - and no existing
            // instance boots it, so their disks and the accounts on them are
            // untouched. It used to be the disk every instance booted, and
            // the remembered account had to be forgotten with it or every
            // session pointed at a user the fresh image did not have
            // (shellinit refuses an unknown user with a silent exit 127).
            // Each instance now owns that question - see `InstanceDisk` and
            // `DefaultUserRegistry`.
        }
    }

    /// Where the record of what was downloaded lives: beside the base.
    ///
    /// A dotfile, so it never looks like something to open, and beside the
    /// image rather than in a shared index so that deleting the image by hand
    /// cannot leave MSL believing the download is still there.
    static func installedMarkerURL(for disk: URL) -> URL {
        disk.deletingLastPathComponent()
            .appendingPathComponent(".\(disk.lastPathComponent).installed")
    }

    static func installedMarker(for disk: URL) -> String? {
        guard FileManager.default.fileExists(atPath: disk.path),
              let text = try? String(contentsOf: installedMarkerURL(for: disk), encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recordInstalled(_ sha256: String, for disk: URL) {
        try? (sha256 + "\n").write(to: installedMarkerURL(for: disk), atomically: true, encoding: .utf8)
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
    public static func downloadAndVerify(_ artifact: Artifact, to destination: URL,
                                         progress: ((String) -> Void)? = nil,
                                         transfer: ((TransferProgress) -> Void)? = nil,
                                         cancellation: InstallCancellation? = nil) throws {
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
        try runCurlToFile(url: artifact.url, destination: tmpURL,
                          expectedSize: artifact.size, transfer: transfer,
                          cancellation: cancellation)

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
        // Small file, but it is the first thing every install does: a transient
        // CDN hiccup here reads as "MSL cannot find any images at all".
        //
        // **Deliberately not `--retry-all-errors`**, unlike the download
        // below. curl's default retry set is the transient one - timeouts,
        // 429, 5xx - and that is exactly right here: a manifest that is
        // genuinely *absent* (404, or a host that no longer publishes one)
        // should fail at once so the next source is tried immediately.
        // Retrying it was costing seconds of dead waiting before every
        // fallback, and made the installer's own tests take a minute.
        //
        // `--max-time` so a host that accepts the connection and then says
        // nothing cannot stall the whole install: 20s is far longer than this
        // file needs and far shorter than someone will wait.
        process.arguments = ["-fsSL", "--retry", "2", "--retry-delay", "1",
                             "--retry-connrefused", "--max-time", "20", url]
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
    ///
    /// **Retried and resumable, because these are half-gigabyte files over a
    /// CDN.** Installing Arch from SourceForge failed on the first attempt
    /// with `curl exited 18` - the mirror closed the connection mid-transfer
    /// with the object fully intact on the server (a ranged read of its tail
    /// returned 206, and the retry succeeded). Without this, one dropped
    /// connection discards 560 MB and the person has to start again.
    ///
    /// `-C -` resumes rather than restarting: the destination is a
    /// PID-specific temporary file removed on the way out, so there is never
    /// a stale partial from another release to resume into, and the sha256
    /// check immediately after is the backstop if there somehow were.
    ///
    /// `--retry-all-errors` is needed here because a mid-transfer close is
    /// not in curl's default "transient" set, which is exactly the failure
    /// seen. The manifest fetch above deliberately does NOT use it: a missing
    /// manifest should fall straight through to the next source, while a
    /// half-delivered image is worth another go.
    /// Internal rather than private: `UpdateDownload` fetches MSL's own
    /// installer package with exactly these semantics (resume, retry,
    /// progress, cancel), and a second copy of them would be a second place
    /// for the 560 MB lesson to be relearned.
    static func runCurlToFile(url: String, destination: URL,
                                      expectedSize: UInt64 = 0,
                                      transfer: ((TransferProgress) -> Void)? = nil,
                                      cancellation: InstallCancellation? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fL", "--progress-bar",
                             "--retry", "5", "--retry-delay", "3",
                             "--retry-all-errors", "--retry-connrefused",
                             "-C", "-",
                             "-o", destination.path, url]
        // Registered before it starts, so a cancel that lands in the gap
        // between the two is not lost: `adopt` refuses and nothing runs.
        guard cancellation?.adopt(process) ?? true else {
            throw InstallerError.cancelled(url)
        }
        try process.run()

        // Watch the file grow, on a thread, for as long as curl runs. The
        // rate is measured over the last sample rather than the whole
        // transfer, so a connection that stalls shows 0 B/s immediately
        // instead of coasting on an average that looks healthy.
        let watcher: Thread?
        if let transfer, expectedSize > 0 {
            let thread = Thread {
                var lastBytes: UInt64 = 0
                var lastAt = Date()
                // Smoothed, because curl writes in bursts: a raw per-sample
                // rate read 0 whenever a 0.4s window happened to fall between
                // writes, which made the figure vanish and the line jump
                // shorter every few seconds. An exponential average rides
                // over that while still falling away quickly if the transfer
                // really does stop.
                var smoothed: Double?
                while !Thread.current.isCancelled {
                    Thread.sleep(forTimeInterval: 0.4)
                    if Thread.current.isCancelled { break }
                    let attributes = try? FileManager.default
                        .attributesOfItem(atPath: destination.path)
                    let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastAt)
                    let sample = elapsed > 0 ? Double(bytes &- min(bytes, lastBytes)) / elapsed : 0
                    smoothed = smoothed.map { $0 * 0.7 + sample * 0.3 } ?? sample
                    transfer(TransferProgress(completed: bytes, total: expectedSize,
                                              bytesPerSecond: max(0, smoothed ?? 0)))
                    lastBytes = bytes
                    lastAt = now
                }
            }
            thread.start()
            watcher = thread
        } else {
            watcher = nil
        }

        process.waitUntilExit()
        watcher?.cancel()
        cancellation?.release()
        // A cancelled download is not a failure to report as one: curl was
        // killed on purpose, and the caller wants "cancelled", not "exited
        // 15". The partial file is removed by `downloadAndVerify`'s `defer`
        // as this throws.
        if cancellation?.isCancelled == true {
            throw InstallerError.cancelled(url)
        }
        guard process.terminationStatus == 0 else {
            throw InstallerError.downloadFailed(url, process.terminationStatus)
        }
        // One last update so the bar lands on full rather than wherever the
        // final poll happened to catch it.
        if let transfer, expectedSize > 0 {
            transfer(TransferProgress(completed: expectedSize, total: expectedSize,
                                      bytesPerSecond: 0))
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
