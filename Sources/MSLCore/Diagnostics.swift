import Foundation

/// Checks an MSL installation for the problems that accumulate quietly:
/// state files for instances that no longer exist, generated `.app` bundles
/// pointing at nothing, registered instances whose distro image was never
/// installed, and tools that are missing from the install directory.
///
/// None of this is reachable through any other command. Instances are
/// registered when their VM manager is built - before any boot succeeds -
/// so a typo or an abandoned experiment leaves a machine identity file
/// behind, and removing an instance by editing `instances.json` directly
/// (which is what people do when the registry is confusing) leaves
/// everything else.
///
/// Every path is injected rather than read from `MSLPaths`, so the whole
/// thing runs against a temporary directory in tests.
public enum Diagnostics {

    public enum Severity: String, Sendable {
        case ok
        case warning
        case problem

        public var symbol: String {
            switch self {
            case .ok: return "OK  "
            case .warning: return "WARN"
            case .problem: return "BAD "
            }
        }
    }

    public struct Finding: Sendable {
        public let severity: Severity
        public let title: String
        public let detail: String
        /// Files this finding would delete if the user asks it to. Empty
        /// when there is nothing safely removable.
        public let removable: [URL]

        public init(severity: Severity, title: String, detail: String, removable: [URL] = []) {
            self.severity = severity
            self.title = title
            self.detail = detail
            self.removable = removable
        }
    }

    public struct Environment: Sendable {
        public let appSupport: URL
        public let generatedApps: URL
        public let binDirectory: URL
        public let instances: [String: GuestDistro]
        public let expectedTools: [String]
        public let daemonRunning: Bool

        public init(
            appSupport: URL, generatedApps: URL, binDirectory: URL,
            instances: [String: GuestDistro], expectedTools: [String], daemonRunning: Bool
        ) {
            self.appSupport = appSupport
            self.generatedApps = generatedApps
            self.binDirectory = binDirectory
            self.instances = instances
            self.expectedTools = expectedTools
            self.daemonRunning = daemonRunning
        }
    }

    public static func run(_ environment: Environment) -> [Finding] {
        var findings: [Finding] = []
        findings.append(contentsOf: toolFindings(environment))
        findings.append(daemonFinding(environment))
        findings.append(contentsOf: instanceFindings(environment))
        findings.append(contentsOf: orphanFindings(environment))
        findings.append(contentsOf: diskFindings(environment))
        return findings
    }

    // MARK: - Checks

    private static func toolFindings(_ environment: Environment) -> [Finding] {
        let missing = environment.expectedTools.filter {
            !FileManager.default.fileExists(atPath: environment.binDirectory.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else {
            return [Finding(severity: .ok, title: "Host tools installed",
                            detail: "\(environment.expectedTools.count) in \(display(environment.binDirectory))")]
        }
        return [Finding(
            severity: .problem, title: "Host tools missing",
            detail: "\(missing.joined(separator: ", ")) - generated apps and the daemon launch from here. Run `msl install-tools` from a build.")]
    }

    private static func daemonFinding(_ environment: Environment) -> Finding {
        environment.daemonRunning
            ? Finding(severity: .ok, title: "Daemon reachable", detail: "mslhd is accepting connections")
            : Finding(severity: .warning, title: "Daemon not running",
                      detail: "mslhd starts on demand, so this is only a problem if it fails to.")
    }

    /// A registered instance whose distro image is absent can never boot -
    /// worth saying plainly, because the failure it produces otherwise is a
    /// boot error rather than "you never installed this".
    private static func instanceFindings(_ environment: Environment) -> [Finding] {
        guard !environment.instances.isEmpty else {
            return [Finding(severity: .warning, title: "No instances registered",
                            detail: "Create one with `msl new <name>`.")]
        }
        var findings: [Finding] = []
        for (name, distro) in environment.instances.sorted(by: { $0.key < $1.key }) {
            if let slug = distro.customSlug {
                if let image = CustomImage.find(slug: slug, appSupport: environment.appSupport) {
                    if !image.isUsable {
                        findings.append(Finding(
                            severity: .problem, title: "\(name): custom image \(slug) can't boot",
                            detail: image.problems.joined(separator: "\n      ")))
                    }
                } else {
                    findings.append(Finding(
                        severity: .problem, title: "\(name): custom image \(slug) is gone",
                        detail: "Its folder, Custom Images/\(slug), no longer exists - put it back, or remove the instance."))
                }
                continue
            }
            let image = distro.bootFiles(appSupport: environment.appSupport).disk
            if !FileManager.default.fileExists(atPath: image.path) {
                findings.append(Finding(
                    severity: .problem, title: "\(name): \(distro.rawValue) image not installed",
                    detail: "\(distro.diskImageFilename) is missing - run `msl install \(distro.rawValue)`."))
            }
        }
        if findings.isEmpty {
            findings.append(Finding(
                severity: .ok, title: "\(environment.instances.count) instance(s) registered",
                detail: environment.instances.keys.sorted().joined(separator: ", ")))
        }
        return findings
    }

    /// State belonging to instances that are not registered.
    private static func orphanFindings(_ environment: Environment) -> [Finding] {
        var findings: [Finding] = []
        let known = Set(environment.instances.keys)

        // `vm-<name>.machineid`, and the snapshots that sit beside it.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: environment.appSupport, includingPropertiesForKeys: nil)) ?? []
        var orphanFiles: [URL] = []
        var orphanNames = Set<String>()
        for url in contents {
            guard case .orphaned(let label) = owner(ofStateFile: url.lastPathComponent, known: known)
            else { continue }
            orphanFiles.append(url)
            orphanNames.insert(label)
        }
        if !orphanFiles.isEmpty {
            findings.append(Finding(
                severity: .warning, title: "State left by \(orphanNames.count) removed instance(s)",
                detail: "\(orphanNames.sorted().joined(separator: ", ")) - \(orphanFiles.count) file(s). Nothing reads these.",
                removable: orphanFiles))
        }

        // Cached app catalogs.
        let catalogRoot = environment.appSupport.appendingPathComponent("AppCatalog")
        let catalogs = (try? FileManager.default.contentsOfDirectory(
            at: catalogRoot, includingPropertiesForKeys: nil)) ?? []
        let orphanCatalogs = catalogs.filter { !known.contains($0.lastPathComponent) }
        if !orphanCatalogs.isEmpty {
            findings.append(Finding(
                severity: .warning, title: "Cached app lists for \(orphanCatalogs.count) removed instance(s)",
                detail: orphanCatalogs.map(\.lastPathComponent).sorted().joined(separator: ", "),
                removable: orphanCatalogs))
        }

        // Generated .app bundles that would launch an instance that no
        // longer exists - these are the worst kind, because they are in the
        // user's Applications folder and look like working apps.
        let bundleDirectories = (try? FileManager.default.contentsOfDirectory(
            at: environment.generatedApps, includingPropertiesForKeys: nil)) ?? []
        let orphanBundles = bundleDirectories.filter {
            !known.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".")
        }
        if !orphanBundles.isEmpty {
            findings.append(Finding(
                severity: .problem, title: "Applications pointing at removed instance(s)",
                detail: "\(orphanBundles.map(\.lastPathComponent).sorted().joined(separator: ", ")) - these are in your Applications folder and will fail to launch.",
                removable: orphanBundles))
        }
        return findings
    }

    /// Whether a file in the support directory is per-instance state, and
    /// if so whether any registered instance still owns it.
    enum Ownership: Equatable {
        /// Not per-instance state at all - a kernel, a distro image, the
        /// socket. Most of the directory.
        case notInstanceState
        case owned(String)
        /// Per-instance state whose instance is gone. The string is a
        /// display label, not necessarily a bare instance name.
        case orphaned(String)
    }

    /// Answers ownership by asking the registry, never by parsing alone.
    ///
    /// Snapshots are `vm-<instance>-<snapshot>.state` and the implicit one
    /// is `vm-<instance>.state`, so a filename on its own is genuinely
    /// ambiguous: `vm-test-box.state` is either the implicit snapshot of an
    /// instance called `test-box` or the `box` snapshot of one called
    /// `test`. Splitting on the first hyphen picks `test` and, if only
    /// `test-box` exists, reports a live instance's saved state as garbage
    /// - which `--fix` would then delete. Hyphenated instance names are
    /// completely ordinary, so this has to be right rather than likely.
    ///
    /// The question that actually needs answering is only "does any
    /// registered instance own this file", which the registry can settle
    /// exactly. Nothing needs to guess a name back out of the filename.
    static func owner(ofStateFile file: String, known: Set<String>) -> Ownership {
        guard file.hasPrefix("vm-") else { return .notInstanceState }
        let body: String
        if file.hasSuffix(".machineid") {
            // Unambiguous: everything between the prefix and the suffix is
            // the instance name, hyphens and all.
            body = String(file.dropFirst(3).dropLast(".machineid".count))
            return known.contains(body) ? .owned(body) : .orphaned(body)
        }
        if file.hasSuffix(".state") {
            body = String(file.dropFirst(3).dropLast(".state".count))
        } else {
            return .notInstanceState
        }
        if known.contains(body) { return .owned(body) }
        // A snapshot of a live instance: `<instance>-<snapshot>`.
        if let owner = known.first(where: { body.hasPrefix($0 + "-") }) { return .owned(owner) }
        return .orphaned(body)
    }

    private static func diskFindings(_ environment: Environment) -> [Finding] {
        var total: Int64 = 0
        var lines: [String] = []
        for distro in GuestDistro.allCases {
            let url = environment.appSupport.appendingPathComponent(distro.diskImageFilename)
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
                  let allocated = values.totalFileAllocatedSize else { continue }
            total += Int64(allocated)
            let apparent = values.fileSize ?? allocated
            let inUse = environment.instances.values.contains(distro)
            lines.append("\(distro.rawValue): \(bytes(Int64(allocated))) on disk of \(bytes(Int64(apparent)))\(inUse ? "" : " - no instance uses this")")
        }
        guard !lines.isEmpty else { return [] }
        return [Finding(
            severity: .ok, title: "Disk images total \(bytes(total))",
            detail: lines.joined(separator: "\n      "))]
    }

    // MARK: - Formatting

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    private static func display(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
