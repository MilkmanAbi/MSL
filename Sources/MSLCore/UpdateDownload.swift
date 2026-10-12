// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Fetching the installer package for a release `UpdateCheck` chose.
///
/// `UpdateCheck` decides *whether* to update; this gets the thing. The two
/// are deliberately separate, and this one never decides anything: it is
/// given a `Release` and does as it is told.
///
/// The order is the part that matters, and it is OneInstallSystem's own
/// invariant - *"a failure anywhere leaves the current install untouched"*
/// (`ois/core/update.sh`). Everything here happens **before** a single file
/// of the existing MSL is touched: download, verify, and only then is the
/// package handed over and the old copy removed. Downloading after the
/// uninstall would turn a flaky connection into "no MSL, and no installer
/// either".
public enum UpdateDownload {

    // MARK: - Finding the asset

    /// Release asset names to try, most specific first - OIS's
    /// `ois_asset_candidates`. `Scripts/build-installer.sh` writes
    /// `MSL-<version>.pkg`, and v1.0.0 shipped exactly that.
    public static func assetCandidates(version: String) -> [String] {
        ["MSL-\(version).pkg", "MSL.pkg"]
    }

    /// Where a named asset of `tag` lives.
    public static func assetURL(tag: String, name: String,
                                repository: String = UpdateCheck.repository) -> URL? {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(escaped)")
    }

    /// The base every asset URL is built from. Overridable so the whole flow
    /// can be driven offline from a `file://` directory, the same lever
    /// `MSL_MANIFEST_URL` gives the distro installer - there is no newer MSL
    /// release to test against, and there must never need to be.
    public static var releaseBaseOverride: String? {
        ProcessInfo.processInfo.environment["MSL_RELEASE_BASE"]
    }

    /// Asset URLs to try for `release`, in order.
    ///
    /// The published asset list would be more precise, but it costs a REST
    /// API call - the thing `UpdateCheck`'s notes say to avoid - and the
    /// naming has been stable since v1.0.0. A name that isn't there simply
    /// fails and the next candidate is tried; if none works the caller falls
    /// back to opening the release page, which is what MSL did before.
    public static func candidateURLs(for release: UpdateCheck.Release) -> [URL] {
        let names = assetCandidates(version: release.version.description)
        if let base = releaseBaseOverride {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            return names.compactMap { URL(string: "\(trimmed)/\($0)") }
        }
        return names.compactMap { assetURL(tag: release.tag, name: $0) }
    }

    // MARK: - Errors

    public enum Failure: LocalizedError, Equatable {
        case noAsset(tag: String)
        case downloadFailed(String)
        case notAPackage
        case wrongIdentifier(String)
        /// The package says it is a different version from the release it was
        /// fetched for - a mis-uploaded asset, and the one mistake a
        /// publisher is most likely to make.
        case versionMismatch(expected: String, found: String)
        case checksumMismatch
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noAsset(let tag):
                return "Release \(tag) has no installer package to download."
            case .downloadFailed(let why):
                return "The download didn't finish - \(why)"
            case .notAPackage:
                return "What came back isn't an installer package. The download may have been intercepted."
            case .wrongIdentifier(let found):
                return "That package installs “\(found)”, not MSL."
            case .versionMismatch(let expected, let found):
                return "That package is MSL \(found), but the release says \(expected). Nothing was changed."
            case .checksumMismatch:
                return "The download doesn't match the checksum this release publishes. Nothing was changed."
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    // MARK: - Verifying

    /// What a `.pkg` says about itself: read from its `Distribution` member
    /// alone, which `xar` extracts in milliseconds without unpacking the
    /// 30 MB payload.
    public struct PackageIdentity: Equatable, Sendable {
        public let identifier: String
        public let version: String

        public init(identifier: String, version: String) {
            self.identifier = identifier
            self.version = version
        }
    }

    /// Reads `identity` out of a flat package. Nil when the file is not one -
    /// which is itself the check that matters most, because a captive portal
    /// or a 404 page saved as `.pkg` is the realistic failure, not a forged
    /// installer.
    public static func identity(of pkg: URL) -> PackageIdentity? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-pkgid-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let xar = Process()
        xar.executableURL = URL(fileURLWithPath: "/usr/bin/xar")
        xar.arguments = ["-x", "-C", scratch.path, "-f", pkg.path, "Distribution"]
        xar.standardOutput = FileHandle.nullDevice
        xar.standardError = FileHandle.nullDevice
        guard (try? xar.run()) != nil else { return nil }
        xar.waitUntilExit()
        guard xar.terminationStatus == 0,
              let text = try? String(contentsOf: scratch.appendingPathComponent("Distribution"),
                                     encoding: .utf8)
        else { return nil }
        return identity(inDistribution: text)
    }

    /// Split out so it can be tested without building a package.
    static func identity(inDistribution text: String) -> PackageIdentity? {
        // `<pkg-ref id="com.msl.app" version="2.0.0"ved…>` - the only
        // `pkg-ref` that carries a version is the component's.
        let pattern = #"<pkg-ref\s+id="([^"]+)"\s+version="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let id = Range(match.range(at: 1), in: text),
              let version = Range(match.range(at: 2), in: text)
        else { return nil }
        return PackageIdentity(identifier: String(text[id]), version: String(text[version]))
    }

    /// `SHA256SUMS`, as OIS publishes it: `<hash>  <name>` per line.
    static func checksum(for name: String, inSums text: String) -> String? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }
            // The name may carry a leading `*` (binary mode) or `./`.
            let listed = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*./"))
            if listed == name { return fields[0].lowercased() }
        }
        return nil
    }

    /// How a download was checked, so the caller can say so out loud.
    public enum Verification: Equatable, Sendable {
        /// Checked against the release's own `SHA256SUMS`.
        case checksum
        /// The release publishes no checksum for this asset, so only the
        /// package's own identity was checked. OIS treats this the same way:
        /// a *missing* entry is a warning, a *wrong* one is fatal.
        case identityOnly
    }

    /// Checks a downloaded package is the one that was asked for.
    ///
    /// `sums` is the release's `SHA256SUMS` when it ships one. A mismatch is
    /// fatal; its absence is not, because MSL's releases have never shipped
    /// one and refusing them all would make this feature useless on every
    /// existing release.
    public static func verify(_ pkg: URL, assetName: String,
                              expecting release: UpdateCheck.Release,
                              sums: String?) throws -> Verification {
        var verification = Verification.identityOnly
        if let sums, let expected = checksum(for: assetName, inSums: sums) {
            guard let actual = sha256(of: pkg), actual == expected else {
                throw Failure.checksumMismatch
            }
            verification = .checksum
        }
        guard let identity = identity(of: pkg) else { throw Failure.notAPackage }
        guard identity.identifier == "com.msl.app" else {
            throw Failure.wrongIdentifier(identity.identifier)
        }
        guard identity.version == release.version.description else {
            throw Failure.versionMismatch(expected: release.version.description,
                                          found: identity.version)
        }
        return verification
    }

    static func sha256(of url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: " ").first.map { $0.lowercased() }
    }

    // MARK: - Where it lands

    /// A free path in `directory` for `name`, never overwriting.
    ///
    /// An existing file with the same name that is *already* the package
    /// being fetched is reused rather than re-downloaded or duplicated -
    /// someone who ran the update, quit, and ran it again should not end up
    /// with `MSL-2.1.0 2.pkg`.
    public static func destination(for name: String, in directory: URL,
                                   matching release: UpdateCheck.Release? = nil)
        -> (url: URL, alreadyThere: Bool) {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: direct.path) else { return (direct, false) }
        if let release, let identity = identity(of: direct),
           identity.identifier == "com.msl.app",
           identity.version == release.version.description {
            return (direct, true)
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while index < 100 {
            let candidate = directory.appendingPathComponent("\(stem) \(index).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return (candidate, false) }
            index += 1
        }
        return (direct, false)
    }

    public static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    // MARK: - The whole fetch

    public struct Fetched: Sendable {
        public let url: URL
        public let verification: Verification
        /// True when the file was already in Downloads and verified as the
        /// same release, so nothing was transferred.
        public let reused: Bool
    }

    /// Downloads, verifies and places the package for `release`.
    ///
    /// Nothing outside `directory` is touched, and on any failure the
    /// partial file is removed - so a second attempt starts clean and the
    /// installed MSL is untouched either way.
    public static func fetch(_ release: UpdateCheck.Release,
                             into directory: URL = downloadsDirectory,
                             transfer: ((DistroInstaller.TransferProgress) -> Void)? = nil,
                             cancellation: DistroInstaller.InstallCancellation? = nil,
                             log: ((String) -> Void)? = nil) throws -> Fetched {
        // MSLAP, at the one function both `msl update --install` and the
        // app's updater call. Gated on the DOWNLOAD rather than the
        // install because that is the shared step - and because a managed
        // fleet usually wants MSL's version decided centrally rather than
        // by whoever is sitting at the machine.
        guard MSLAPGate.allows("system.update", instance: nil) else {
            throw MSLAPRefusal(MSLAPGate.reason("system.update", instance: nil)
                               ?? "Not allowed by the MSL Admin Portal")
        }
        let sums = fetchSums(for: release)
        var lastFailure: Error = Failure.noAsset(tag: release.tag)

        for url in candidateURLs(for: release) {
            let name = url.lastPathComponent
            let placed = destination(for: name, in: directory, matching: release)
            if placed.alreadyThere {
                log?("\(name) is already in \(directory.lastPathComponent)")
                let verification = try verify(placed.url, assetName: name,
                                              expecting: release, sums: sums)
                return Fetched(url: placed.url, verification: verification, reused: true)
            }

            // Does it exist at all? `runCurlToFile` retries five times with a
            // three-second delay and `--retry-all-errors`, which is right for
            // a half-delivered 30 MB package and absurd for a 404: trying two
            // candidate names cost thirty seconds of waiting before MSL could
            // say "no installer in that release". `DistroInstaller` already
            // draws this exact line between a missing manifest and a broken
            // transfer; this is the same line.
            guard exists(url) else {
                log?("no \(name) in this release")
                lastFailure = Failure.noAsset(tag: release.tag)
                continue
            }

            // Downloaded beside the destination rather than into it, so a
            // half-finished file never looks like a usable installer in the
            // Finder window someone is watching.
            let scratch = directory.appendingPathComponent(".\(name).msldownload")
            try? FileManager.default.removeItem(at: scratch)
            do {
                log?("downloading \(name)")
                try DistroInstaller.runCurlToFile(url: url.absoluteString, destination: scratch,
                                                  transfer: transfer, cancellation: cancellation)
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                if cancellation?.isCancelled == true { throw Failure.cancelled }
                lastFailure = error
                continue
            }

            do {
                let verification = try verify(scratch, assetName: name,
                                              expecting: release, sums: sums)
                try? FileManager.default.removeItem(at: placed.url)
                try FileManager.default.moveItem(at: scratch, to: placed.url)
                log?("verified \(name)")
                return Fetched(url: placed.url, verification: verification, reused: false)
            } catch {
                // A package that downloaded but is not the right one is a
                // hard stop, not a reason to try the next name: something is
                // wrong with the release, and trying `MSL.pkg` next would at
                // best find the same problem.
                try? FileManager.default.removeItem(at: scratch)
                throw error
            }
        }
        throw lastFailure
    }

    /// Whether there is anything at `url`, asked once and cheaply.
    ///
    /// A local file is answered without running anything; anything else is a
    /// HEAD with no retries, because the question is "is it there", and a
    /// retry cannot change the answer.
    static func exists(_ url: URL) -> Bool {
        if url.isFileURL { return FileManager.default.fileExists(atPath: url.path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fsIL", "--max-time", "15", "-o", "/dev/null", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The release's `SHA256SUMS`, when it has one. Best effort by design.
    static func fetchSums(for release: UpdateCheck.Release) -> String? {
        let url: URL?
        if let base = releaseBaseOverride {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            url = URL(string: "\(trimmed)/SHA256SUMS")
        } else {
            url = assetURL(tag: release.tag, name: "SHA256SUMS")
        }
        guard let url else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fsSL", "--max-time", "15", url.absoluteString]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
