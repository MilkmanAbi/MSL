import CryptoKit
import Foundation

/// One instance, frozen into a single file another MSL can install.
///
/// A `.mslship` is a zip holding two members:
///
///     msl.json         the manifest
///     rootfs.img.xz    the instance's disk, xz-compressed
///
/// A zip because its central directory makes one member readable on its own:
/// `info` reads the manifest in milliseconds without touching the gigabyte
/// beside it, which is what lets someone see what they are about to install
/// before committing to the unpack. The disk goes in **stored**, not deflated
/// - it is already xz'd, and asking zip to compress it again costs minutes to
/// make it slightly larger.
///
/// This is cheap only because instances own their disks (`InstanceDisk`): a
/// shipment is that one file plus the per-instance records around it.
public enum Shipment {
    public static let fileExtension = "mslship"
    static let manifestName = "msl.json"
    /// Named without an extension; the manifest says how it is compressed.
    static let diskName = "rootfs.img.z"
    static let kernelName = "kernel.z"
    static let initramfsName = "initramfs.z"
    /// Bumped when the layout changes in a way an older MSL cannot read.
    /// 2 added the kernel and initramfs, so a shipment installs and runs on
    /// a Mac that has downloaded nothing. Format 1 is still readable; it just
    /// needs a distro present, and `install` says so.
    public static let formatVersion = 2

    public struct Manifest: Codable {
        public struct Source: Codable {
            public var instance: String
            public var distro: String
            public var custom: Bool
        }
        public struct Disk: Codable {
            public var file: String
            public var compression: String
            public var sha256: String
            public var uncompressedSize: UInt64
        }
        /// The kernel and initramfs the instance was built against, when
        /// the shipment carries them - which, from format 2, it always does.
        /// Absent in a format-1 shipment, which relied on the receiving Mac
        /// already having a distro downloaded.
        public struct Boot: Codable {
            public var kernel: String
            public var initramfs: String
            public var compression: String
        }
        /// The format this file is written in.
        public var shipment: Int
        /// **The oldest reader that can still make sense of it.**
        ///
        /// Without this, version checking has to be pessimistic: anything
        /// newer than the running MSL gets refused, even when the only
        /// difference is fields it would have ignored anyway. Most format
        /// changes are additive, so most newer shipments are perfectly
        /// readable by an older MSL - it just loses the parts it has never
        /// heard of, which it can say out loud.
        ///
        /// A genuinely breaking change raises this, and then an old MSL
        /// refuses with a reason instead of unpacking something it would
        /// get wrong. Absent means "same as `shipment`", which is how every
        /// file written before this existed behaves.
        public var minimumReader: Int?

        /// The INSTANCE's identity token, as it stood when this was
        /// packed - a different axis from `id`/`parent` below, which track
        /// the shipment.
        ///
        /// **Optional, and that is load-bearing.** `minimumReader` exists
        /// so additive changes do not need a version bump, and this is
        /// exactly such a change: an older MSL ignores a field it has
        /// never heard of, and a shipment written before this existed
        /// simply has none.
        ///
        /// The receiving Mac cannot VERIFY it - it was signed by a key the
        /// sender holds - so it is read for what it says rather than
        /// trusted. What the receiver does with it is in
        /// `InstanceIdentityStore.adoptImported`, and the short version is
        /// that an import is a copy by definition, so it is recorded as
        /// one whatever the token claims.
        public var instanceIdentity: String?

        /// This shipment's own identity, so one can be recognised again
        /// after being renamed, copied, or passed along.
        public var id: String?
        /// The shipment this environment itself came from, if it did.
        /// Follow the chain and you have where an environment has been.
        public var parent: String?
        /// What it was made on. Architecture matters most - an arm64 disk
        /// is not going to boot on anything else, and knowing before
        /// unpacking 15 GB is worth the two lines.
        public var host: Host?

        public struct Host: Codable {
            public var architecture: String
            public var macOS: String?
        }

        public var created: Date
        public var mslVersion: String
        public var source: Source
        public var disk: Disk
        public var boot: Boot?
        public var defaultUser: String?
        public var resources: ResourcePolicy?
        public var sandbox: SandboxPolicy?
        public var experiments: MSLExperimentalSettings?
        public var apps: [String]?
        /// The badge and tint somebody gave this instance. Cosmetic, and
        /// the first thing they notice is missing if it does not travel.
        public var appearance: InstanceAppearance?
        public var note: String?
    }

    public enum ShipmentError: Error, CustomStringConvertible {
        /// An administrator's policy forbids this. Carries the reason so
        /// the person is told who decided and why, not just "no".
        case refusedByPolicy(String)
        case instanceRunning(String)
        case noDisk(String)
        case notAShipment(String)
        case tooNew(Int)
        case nameTaken(String)
        case toolFailed(String, Int32)
        /// The archive is not what it says it is.
        case damaged
        case checksumMismatch
        case missingTool(String)

        public var description: String {
            switch self {
            case .refusedByPolicy(let reason): return reason
            case .instanceRunning(let name):
                return "\(name) is running - shut it down first, or its filesystem is captured half-written"
            case .noDisk(let name):
                return "\(name) has no disk yet - start it once before shipping it"
            case .notAShipment(let path):
                return "\(path) isn't an MSL shipment (no \(manifestName) inside)"
            case .tooNew(let version):
                return "this shipment was made by a newer MSL (format \(version); this one reads \(formatVersion))"
            case .nameTaken(let name):
                return "there's already an instance called '\(name)' - choose another name"
            case .damaged:
                return """
                    this shipment is damaged - what is inside does not match the checksum it \
                    was packed with. Something altered it in transit, so nothing has been \
                    installed. Ask for it again.
                    """
            case .toolFailed(let tool, let status):
                return "\(tool) failed (exit \(status))"
            case .checksumMismatch:
                return "the disk inside this shipment is damaged - its checksum doesn't match the manifest"
            case .missingTool(let tool):
                return "this shipment is compressed with \(tool), which isn't installed on this Mac - `brew install \(tool)`"
            }
        }
    }

    // MARK: - Making one

    /// Packages `instance` into `destination`.
    ///
    /// The disk is **cloned first** and the clone is what gets compressed, so
    /// the instance is usable again immediately instead of being locked for
    /// the minutes xz takes. The clone is free (`clonefile`) and removed
    /// afterwards.
    public static func create(instance: String, distro: GuestDistro, destination: URL,
                              note: String? = nil, apps: [String] = [],
                              isRunning: Bool = false,
                              appSupport: URL = MSLPaths.appSupport,
                              progress: ((String) -> Void)? = nil) throws {
        // MSLAP: writing an instance out is the main route by which a
        // managed machine's contents leave it. Checked here rather than at
        // the button, because the CLI reaches this function too.
        guard MSLAPGate.allows("shipment.export", instance: instance) else {
            throw ShipmentError.refusedByPolicy(
                MSLAPGate.reason("shipment.export", instance: instance)
                ?? "Not allowed by the MSL Admin Portal")
        }
        guard !isRunning else { throw ShipmentError.instanceRunning(instance) }
        let disk = InstanceDisk.url(instance: instance, appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: disk.path) else {
            throw ShipmentError.noDisk(instance)
        }

        let staging = appSupport.appendingPathComponent(".shipment-\(instance)-\(ProcessInfo.processInfo.processIdentifier)",
                                                       isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        progress?("taking a snapshot of \(instance)'s disk")
        let snapshot = staging.appendingPathComponent("rootfs.img")
        if clonefile(disk.path, snapshot.path, 0) != 0 {
            // Off APFS a clone is impossible; copy instead rather than
            // refusing outright - the instance is stopped anyway.
            try FileManager.default.copyItem(at: disk, to: snapshot)
        }

        progress?("compressing (this is the slow part)")
        let compressed = staging.appendingPathComponent(diskName)
        let compressor = Compressor.best()
        try run(compressor.tool, compressor.compressArguments + [snapshot.path], writingTo: compressed)
        let uncompressed = (try? FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)??.uint64Value ?? 0
        try? FileManager.default.removeItem(at: snapshot)

        // The kernel and initramfs the instance actually boots with. Without
        // them a shipment is not standalone: the receiving Mac may have
        // downloaded no distro at all, and even one that has may be on a
        // different MSL build with a different kernel - which is not the
        // machine that was shipped.
        progress?("including the kernel")
        let boot = distro.bootFiles(instance: instance, appSupport: appSupport)
        var bootManifest: Manifest.Boot?
        if FileManager.default.fileExists(atPath: boot.kernel.path),
           FileManager.default.fileExists(atPath: boot.initramfs.path) {
            let kernelOut = staging.appendingPathComponent(kernelName)
            let initrdOut = staging.appendingPathComponent(initramfsName)
            try run(compressor.tool, compressor.compressArguments + [boot.kernel.path], writingTo: kernelOut)
            try run(compressor.tool, compressor.compressArguments + [boot.initramfs.path], writingTo: initrdOut)
            bootManifest = .init(kernel: kernelName, initramfs: initramfsName,
                                 compression: compressor.name)
        }

        progress?("writing the manifest")
        let manifest = Manifest(
            shipment: formatVersion,
            // Every field added since v2 is optional, so a v2 reader loses
            // only the parts it never knew about. Raise this only for a
            // change that would make an older MSL get something *wrong* -
            // refusing to open is far better than unpacking incorrectly.
            minimumReader: 2,
            // Unverified by whoever receives it, and recorded anyway: the
            // lineage is the useful part, and claiming a lineage can only
            // make an instance MORE restricted on arrival, never less.
            instanceIdentity: InstanceIdentityStore.rawToken(
                for: instance, appSupport: appSupport),
            id: UUID().uuidString,
            parent: ShipmentLineage.parent(of: instance, appSupport: appSupport),
            host: .init(architecture: hostArchitecture(),
                        macOS: ProcessInfo.processInfo.operatingSystemVersionString),
            created: Date(),
            mslVersion: MSLVersion.display,
            source: .init(instance: instance, distro: distro.rawValue, custom: distro.isCustom),
            disk: .init(file: diskName, compression: compressor.name,
                        sha256: try sha256(of: compressed), uncompressedSize: uncompressed),
            boot: bootManifest,
            defaultUser: LinuxUserSetup.registry().defaultUser(forInstance: instance),
            resources: ResourcePolicyStore.load(instance: instance),
            sandbox: SandboxPolicyStore.load(instance: instance),
            experiments: InstanceExperiments.effective(for: instance, appSupport: appSupport),
            apps: apps.isEmpty ? nil : apps,
            appearance: InstanceAppearanceStore.load(appSupport: appSupport)[instance],
            note: note)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))

        progress?("packaging")
        try? FileManager.default.removeItem(at: destination)
        // -0: stored. The disk is already xz'd and the manifest is tiny.
        // -j: no directory names inside the archive.
        var members = [staging.appendingPathComponent(manifestName).path, compressed.path]
        if bootManifest != nil {
            members.append(staging.appendingPathComponent(kernelName).path)
            members.append(staging.appendingPathComponent(initramfsName).path)
        }
        try run("/usr/bin/zip", ["-0", "-j", "-q", destination.path] + members)
    }

    // MARK: - Reading one

    /// The manifest, without unpacking the disk.
    public static func info(at url: URL) throws -> Manifest {
        let data = try readMember(manifestName, from: url)
        guard !data.isEmpty else { throw ShipmentError.notAShipment(url.lastPathComponent) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            throw ShipmentError.notAShipment(url.lastPathComponent)
        }
        // **The minimum reader decides, not the format number.** A newer
        // shipment whose changes are additive is readable here; it simply
        // arrives without the parts this MSL has never heard of. Only a
        // file that says it needs a newer reader is refused, and then for a
        // reason rather than out of caution.
        let required = manifest.minimumReader ?? manifest.shipment
        guard required <= formatVersion else { throw ShipmentError.tooNew(manifest.shipment) }
        return manifest
    }

    // MARK: - Installing one

    /// Unpacks `url` into a new instance called `name`.
    ///
    /// Everything per-instance travels: the disk, the Linux account, the
    /// resource policy, the sandbox posture and the experiments - the last of
    /// those as **overrides for this instance only**, never app-wide
    /// (`InstanceExperiments`).
    @discardableResult
    public static func install(_ url: URL, as name: String,
                               existingInstances: [String: GuestDistro],
                               appSupport: URL = MSLPaths.appSupport,
                               progress: ((String) -> Void)? = nil) throws -> [InstanceExperiments.Outcome] {
        // And the main route by which something arrives. An imported
        // instance brings its own disk, so a policy that restricts what
        // this Mac may run has to cover it.
        guard MSLAPGate.allows("shipment.import", instance: name) else {
            throw ShipmentError.refusedByPolicy(
                MSLAPGate.reason("shipment.import", instance: name)
                ?? "Not allowed by the MSL Admin Portal")
        }
        let manifest = try info(at: url)
        guard existingInstances[name] == nil else { throw ShipmentError.nameTaken(name) }

        // **The checksum is checked, not merely recorded.**
        //
        // It was written at pack time and never looked at again, which made
        // it decoration. A shipment is the one MSL artefact that travels -
        // over the internet, through chat apps, onto USB sticks - so a
        // truncated or altered file is a real thing that happens, and
        // without this it becomes a filesystem that mounts and then behaves
        // strangely, days later, for no visible reason.
        //
        // Checked against the compressed member while it is still inside
        // the archive, so nothing is written to disk before it is known to
        // be what it claims.
        if !manifest.disk.sha256.isEmpty {
            progress?("checking the archive is intact")
            let actual = try sha256OfMember(manifest.disk.file, in: url)
            guard actual == manifest.disk.sha256 else {
                throw ShipmentError.damaged
            }
        }

        progress?("unpacking \(manifest.source.distro) (\(ByteCountFormatter.string(fromByteCount: Int64(manifest.disk.uncompressedSize), countStyle: .file)))")
        try FileManager.default.createDirectory(at: InstanceDisk.directory(appSupport: appSupport),
                                                withIntermediateDirectories: true)
        let destination = InstanceDisk.url(instance: name, appSupport: appSupport)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(name).img.unpacking-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: staging)
        // Streamed, so a 15 GB filesystem never exists twice on disk.
        let decompressor = try Compressor.named(manifest.disk.compression)
        try shell("/usr/bin/unzip -p \(quote(url.path)) \(quote(manifest.disk.file)) | \(quote(decompressor.tool)) \(decompressor.decompressFlags) > \(quote(staging.path))")
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        // The kernel it was built against, beside its disk. This is what
        // makes a shipment standalone: it runs on a Mac that has downloaded
        // nothing, and it keeps the kernel its filesystem expects rather
        // than whatever this MSL build happens to ship.
        if let boot = manifest.boot {
            progress?("unpacking the kernel")
            let decompressor = try Compressor.named(boot.compression)
            let kernel = InstanceDisk.kernelURL(instance: name, appSupport: appSupport)
            let initramfs = InstanceDisk.initramfsURL(instance: name, appSupport: appSupport)
            do {
                try shell("/usr/bin/unzip -p \(quote(url.path)) \(quote(boot.kernel)) | \(quote(decompressor.tool)) \(decompressor.decompressFlags) > \(quote(kernel.path))")
                try shell("/usr/bin/unzip -p \(quote(url.path)) \(quote(boot.initramfs)) | \(quote(decompressor.tool)) \(decompressor.decompressFlags) > \(quote(initramfs.path))")
            } catch {
                // Both or neither: a kernel without its initramfs boots
                // against the wrong modules, which is worse than falling back
                // to the shared pair.
                try? FileManager.default.removeItem(at: kernel)
                try? FileManager.default.removeItem(at: initramfs)
                throw error
            }
        }

        progress?("restoring settings")
        if let user = manifest.defaultUser {
            try? LinuxUserSetup.registry().setDefaultUser(user, forInstance: name)
        }
        if let resources = manifest.resources { ResourcePolicyStore.save(resources, instance: name) }
        // The badge and tint. Cosmetic, and the first thing somebody
        // notices is missing - an environment that arrives looking like
        // every other one does not feel like the machine they were sent.
        if let appearance = manifest.appearance {
            // A custom image cannot travel in the manifest - only the badge,
            // symbol and tint do - so one that referenced an imported file
            // arrives without it rather than pointing at nothing.
            InstanceAppearanceStore.set(appearance.withoutImportedImage, for: name,
                                        appSupport: appSupport)
        }
        // Remembered so a shipment made *from* this instance can say where
        // it is descended from. See ShipmentLineage.
        ShipmentLineage.record(shipmentID: manifest.id, instance: name, appSupport: appSupport)
        // The instance's own lineage, which is a different axis from the
        // shipment's. **Here rather than in either caller**, so the CLI and
        // the app cannot drift - and before `createInstance` registers the
        // instance, which is why `issueFresh` refuses to overwrite: it runs
        // afterwards and would otherwise stamp a fresh generation-0
        // identity over this, turning every import into an original.
        //
        // An import is a copy by definition, so this records it one
        // generation deeper whatever the token claims. That is what makes
        // `instance.clone` refuse an imported copy on a Mac where copying
        // is forbidden - the route this feature was asked about.
        InstanceIdentityStore.adoptImported(manifest.instanceIdentity, as: name,
                                            appSupport: appSupport)
        // Seals travel only in the safe direction: a sealed shipment installs
        // sealed, an open one leaves this Mac's defaults alone.
        if let sandbox = manifest.sandbox, !sandbox.isOpen {
            _ = SandboxPolicyStore.save(sandbox, instance: name)
        }
        // Said here, where it can still be acted on. A shipment carries the
        // filesystem and nothing else; the kernel and initramfs are shared by
        // every distro and arrive with the first one downloaded. Installing
        // one onto a Mac that has never downloaded a distro therefore makes a
        // complete-looking instance that cannot boot, and the only sign used
        // to be a raw `VZErrorDomain` boot-loader dump at start (2026-10-02).
        if manifest.boot == nil,
           let distro = GuestDistro(rawValue: manifest.source.distro),
           distro.bootFiles(instance: name, appSupport: appSupport)
               .missingDescription(distro: distro) != nil {
            progress?("""
                installed, but \(manifest.source.distro) isn't downloaded on this Mac yet - \
                run `msl install \(manifest.source.distro)` before starting \(name)
                """)
        }

        guard let experiments = manifest.experiments else { return [] }
        return InstanceExperiments.apply(experiments, to: name, appSupport: appSupport)
    }

    /// Whether `instance` has everything it needs to boot after a shipment
    /// install - the one thing a shipment cannot bring with it.
    ///
    /// Separate from `install` so the app can say it in a banner that stays
    /// on screen, rather than in a progress line that scrolls past.
    public static func missingDistroImage(for instance: String, distro: GuestDistro,
                                          appSupport: URL = MSLPaths.appSupport) -> String? {
        distro.bootFiles(instance: instance, appSupport: appSupport)
            .missingDescription(distro: distro)
    }

    /// Which compressor to use, because none is guaranteed.
    ///
    /// `xz` is much better on a sparse filesystem image but is not part of
    /// macOS - it arrives with Homebrew or MacPorts, and a shipment must not
    /// need either. `gzip` is always at `/usr/bin/gzip`, so it is the floor.
    /// The manifest records which one was used, so a shipment made on a Mac
    /// with xz still installs on a Mac without it, provided that Mac can
    /// decompress it - which is why the error below names the tool.
    struct Compressor {
        var name: String
        var tool: String
        var compressArguments: [String]
        var decompressFlags: String

        static let searchPaths = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin"]

        static func locate(_ tool: String) -> String? {
            searchPaths.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        static func best() -> Compressor {
            if let xz = locate("xz") {
                // -T0 uses every core; -6 rather than the publishing
                // pipeline's -9e, because someone is waiting on this.
                return Compressor(name: "xz", tool: xz,
                                  compressArguments: ["-6", "-T0", "-c"], decompressFlags: "-dc")
            }
            return Compressor(name: "gzip", tool: "/usr/bin/gzip",
                              compressArguments: ["-6", "-c"], decompressFlags: "-dc")
        }

        static func named(_ name: String) throws -> Compressor {
            switch name {
            case "xz":
                guard let xz = locate("xz") else { throw ShipmentError.missingTool("xz") }
                return Compressor(name: "xz", tool: xz, compressArguments: [], decompressFlags: "-dc")
            case "gzip":
                return Compressor(name: "gzip", tool: "/usr/bin/gzip",
                                  compressArguments: [], decompressFlags: "-dc")
            default:
                throw ShipmentError.missingTool(name)
            }
        }
    }

    // MARK: - Plumbing

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readMember(_ member: String, from url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// The checksum of one member, read straight out of the archive so the
    /// file never has to be unpacked to be doubted.
    static func sha256OfMember(_ member: String, in archive: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "/usr/bin/unzip -p \(quote(archive.path)) \(quote(member)) | /usr/bin/shasum -a 256"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return String(text.split(separator: " ").first ?? "")
    }

    private static func run(_ tool: String, _ arguments: [String], writingTo output: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShipmentError.toolFailed((tool as NSString).lastPathComponent, process.terminationStatus)
        }
    }

    private static func shell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `pipefail`, or a failing `unzip` is hidden by a happy `xz`.
        process.arguments = ["-o", "pipefail", "-c", command]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShipmentError.toolFailed("unpacking", process.terminationStatus)
        }
    }

    /// What this Mac is. An arm64 disk will not boot anywhere else, and
    /// knowing that before unpacking fifteen gigabytes is worth two lines.
    static func hostArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Where an environment came from.
///
/// A shipment records the id of the shipment its source instance was
/// installed from, so a chain of them reads as a history: this environment
/// came from that one, which came from the one before. Useful for exactly
/// the thing shipments are for - somebody hands you a machine and you want
/// to know what it is descended from.
public enum ShipmentLineage {
    static func file(instance: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent("shipments/\(instance).parent")
    }

    /// Remembers which shipment an instance was installed from.
    public static func record(shipmentID: String?, instance: String, appSupport: URL) {
        guard let shipmentID, !shipmentID.isEmpty else { return }
        let url = file(instance: instance, appSupport: appSupport)
        _ = MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        try? Data(shipmentID.utf8).write(to: url, options: .atomic)
    }

    public static func parent(of instance: String, appSupport: URL) -> String? {
        guard let data = try? Data(contentsOf: file(instance: instance, appSupport: appSupport))
        else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func forget(instance: String, appSupport: URL) {
        try? FileManager.default.removeItem(at: file(instance: instance, appSupport: appSupport))
    }
}
