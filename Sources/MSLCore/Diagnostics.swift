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
        /// Whether MSL's observer is running. nil when the caller did not
        /// look - a test building an environment by hand is not making a
        /// claim about a watchdog it never asked about.
        public let observerRunning: Bool?
        /// The MSLAP policy in force, or nil on an unmanaged Mac.
        ///
        /// Injected like every other path here, so the protection checks
        /// run against a policy a test built rather than whatever is
        /// installed on the machine running the test.
        public let policy: MSLAPPolicy?

        public init(
            appSupport: URL, generatedApps: URL, binDirectory: URL,
            instances: [String: GuestDistro], expectedTools: [String], daemonRunning: Bool,
            // Defaulted so every existing call site keeps compiling and
            // keeps meaning what it meant: no policy, no protection checks,
            // and no claim either way about the observer.
            policy: MSLAPPolicy? = nil,
            observerRunning: Bool? = nil
        ) {
            self.appSupport = appSupport
            self.generatedApps = generatedApps
            self.binDirectory = binDirectory
            self.instances = instances
            self.expectedTools = expectedTools
            self.daemonRunning = daemonRunning
            self.observerRunning = observerRunning
            self.policy = policy
        }
    }

    /// Whether the installed MSL.app is older than the command-line tools
    /// it would overwrite, and by how long.
    ///
    /// This is the shape of a bug that cost a whole morning: `MSL.app` in
    /// /Applications was weeks older than everything else, so the app being
    /// used had none of the fixes - and because it reinstalls its own tools
    /// at launch, opening it could also drag `mslhd` and `msl` back in time.
    /// Nothing anywhere said so; the app looks the same either way.
    public static func staleAppFinding(bundle: URL, toolsDirectory: URL,
                                       now: Date = Date()) -> Finding? {
        func modified(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let appBinary = bundle.appendingPathComponent("Contents/MacOS/MSLApp")
        guard FileManager.default.fileExists(atPath: appBinary.path),
              let appDate = modified(appBinary),
              let toolDate = modified(toolsDirectory.appendingPathComponent("mslhd"))
        else { return nil }
        let days = toolDate.timeIntervalSince(appDate) / 86_400
        guard days >= 1 else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return Finding(
            severity: .problem,
            title: "\(bundle.lastPathComponent) is \(Int(days)) day(s) older than MSL's tools",
            detail: "The app at \(bundle.path) is from \(formatter.string(from: appDate)) and the "
                  + "installed tools are from \(formatter.string(from: toolDate)). That app has none "
                  + "of the newer fixes, and opening it reinstalls its own copies of the tools. "
                  + "Replace it with a current build.")
    }

    public static func run(_ environment: Environment) -> [Finding] {
        var findings: [Finding] = []
        findings.append(contentsOf: toolFindings(environment))
        findings.append(daemonFinding(environment))
        findings.append(observerFinding(environment))
        findings.append(contentsOf: instanceFindings(environment))
        findings.append(contentsOf: orphanFindings(environment))
        findings.append(contentsOf: diskFindings(environment))
        findings.append(contentsOf: protectionFindings(environment))
        findings.append(contentsOf: identityFindings(environment))
        return findings
    }

    // MARK: - Checks

    /// What each instance's identity says, and nothing more.
    ///
    /// **Report before enforce.** Nothing refuses a start on an identity
    /// yet, deliberately: this touches the boot path of every instance on
    /// every Mac, and a read-only verdict is the only way to learn what
    /// real machines say before a refusal can strand anybody. See
    /// `READMES/31-INSTANCE-IDENTITY.md` step 3.
    ///
    /// Severities say exactly what is known:
    /// - a **duplicate serial** is `problem`. Two registered instances
    ///   cannot be the same instance, so something was copied. It is
    ///   self-contradictory rather than merely unproven, which is why it
    ///   will be the one verdict refused even with no policy.
    /// - an identity that **does not verify** is `problem`: somebody
    ///   edited it.
    /// - **no identity** is not a finding at all on its own. Every
    ///   instance in existence today is in that state, and warning about
    ///   all of them would teach people to ignore the section.
    static func identityFindings(_ environment: Environment) -> [Finding] {
        let identities = InstanceIdentityStore.all(appSupport: environment.appSupport)
        guard !identities.isEmpty else { return [] }
        var findings: [Finding] = []

        for (name, verdict) in identities.sorted(by: { $0.key < $1.key }) {
            guard case .invalid(let why) = verdict else { continue }
            findings.append(Finding(
                severity: .problem,
                title: "\(name)'s identity does not verify",
                detail: "\(why) Somebody edited it, or it was signed by a key this Mac does "
                      + "not accept. `msl identity \(name)` says more."))
        }

        for (serial, names) in InstanceIdentityStore
            .duplicateSerials(appSupport: environment.appSupport)
            .sorted(by: { $0.key < $1.key }) {
            findings.append(Finding(
                severity: .problem,
                title: "\(names.joined(separator: " and ")) claim to be the same instance",
                detail: "They share identity serial \(serial), and two registered instances "
                      + "cannot both be the same instance - one of them is a copy that did not "
                      + "come through MSL."))
        }

        // State left by instances that no longer exist, the same class of
        // finding already reported for app lists and disks.
        let orphans = identities.keys
            .filter { environment.instances[$0] == nil }.sorted()
        if !orphans.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Identities left by \(orphans.count) removed instance(s)",
                detail: orphans.joined(separator: ", "),
                removable: orphans.map {
                    InstanceIdentityStore.file(for: $0, appSupport: environment.appSupport)
                }))
        }

        let valid = identities.values.filter { $0.identity != nil }.count
        let clones = identities.values.filter { $0.identity?.isClone == true }.count
        if findings.isEmpty, valid > 0 {
            findings.append(Finding(
                severity: .ok,
                title: "\(valid) instance(s) have a verified identity",
                detail: clones == 0
                    ? "None of them is a copy of another."
                    : "\(clones) of them \(clones == 1 ? "is a copy" : "are copies") of another instance - `msl identity` says which."))
        }
        return findings
    }

    /// Whether an instance the policy means to keep uncopyable actually is.
    ///
    /// **Reported here because the answer is usually no, for a reason
    /// nobody would guess.** `mac_home` shares the Mac's whole home folder
    /// into every guest, writable, and instance disks live inside it - so
    /// denying `instance.clone` while leaving `sharing.macHome` open closes
    /// the button and leaves a one-line `cp` wide open. An administrator
    /// who has denied cloning believes they are done, and nothing told them
    /// otherwise until now.
    ///
    /// `problem`, not `warning`: the policy states an intention that is not
    /// being met, which is the same class of thing as a missing disk image.
    static func protectionFindings(_ environment: Environment) -> [Finding] {
        let policy = environment.policy
        guard policy != nil else { return [] }
        var findings: [Finding] = []
        for name in environment.instances.keys.sorted() {
            let reasons = ProtectedInstance.reasons(for: name, policy: policy)
            guard !reasons.isEmpty else { continue }
            let gaps = ProtectedInstance.gaps(for: name, policy: policy)
            guard let worst = gaps.first else {
                findings.append(Finding(
                    severity: .ok,
                    title: "\(name) is protected from being copied",
                    detail: "\(reasons.map(\.intent).joined(separator: ", ")), and no route is "
                          + "left for its disk image. What is inside it is still readable by "
                          + "anyone who can open a shell in it."))
                continue
            }
            findings.append(Finding(
                severity: .problem,
                title: "\(name) is meant to be protected, but \(worst.title)",
                detail: worst.detail
                      + (gaps.count > 1
                         ? " Also still open: "
                           + gaps.dropFirst().map(\.capability).joined(separator: ", ") + "."
                         : "")))
        }
        return findings
    }

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

    /// Whether anything is watching.
    ///
    /// Worth a line of its own because the observer is the one part of MSL
    /// whose absence is **silent by construction**: everything else announces
    /// itself by not working, and a missing watchdog looks exactly like a
    /// healthy Mac right up until the moment somebody needed it.
    ///
    /// A warning, never a problem. Nothing in MSL depends on the observer -
    /// that is the point of it - so its absence costs a report, not a
    /// capability.
    static func observerFinding(_ environment: Environment) -> Finding {
        guard environment.observerRunning ?? false else {
            return Finding(severity: .warning, title: "Nothing is watching MSL",
                           detail: "mslod isn't running, so a failure it would report "
                                 + "will just be a failure. Opening MSL installs and starts it.")
        }
        return Finding(severity: .ok, title: "Observer running",
                       detail: "mslod is watching; its record of this session is in "
                             + "~/Library/Logs/MSL/observer.log")
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
            // Two different "missing"s, and they want different advice: an
            // instance without its own disk has never been started (or its
            // disk was deleted), and it can be given one from the base
            // without downloading anything. A distro without a base needs
            // the download.
            if !InstanceDisk.exists(instance: name, appSupport: environment.appSupport) {
                if distro.baseIsInstalled(appSupport: environment.appSupport) {
                    findings.append(Finding(
                        severity: .ok, title: "\(name): disk is made on first start",
                        detail: "Its own copy of \(distro.rawValue) is cloned from the downloaded image the first time it starts."))
                } else {
                    findings.append(Finding(
                        severity: .problem, title: "\(name): \(distro.rawValue) isn't downloaded",
                        detail: "\(distro.diskImageFilename) is missing, so \(name) has nothing to clone - run `msl install \(distro.rawValue)`."))
                }
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

        // An MSL.app older than the tools it ships with.
        for bundle in [URL(fileURLWithPath: "/Applications/MSL.app"),
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Applications/MSL.app")] {
            if let finding = staleAppFinding(bundle: bundle, toolsDirectory: environment.binDirectory) {
                findings.append(finding)
            }
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
        // Bases first - the downloaded images new instances are cloned from.
        for distro in GuestDistro.allCases {
            let url = distro.baseImageURL(appSupport: environment.appSupport)
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
                  let allocated = values.totalFileAllocatedSize else { continue }
            total += Int64(allocated)
            let apparent = values.fileSize ?? allocated
            lines.append("\(distro.rawValue) (downloaded): \(bytes(Int64(allocated))) on disk of \(bytes(Int64(apparent)))")
        }
        // Then each instance's own disk. These are APFS clones, so the sizes
        // overlap: an instance that has written nothing shares every block
        // with its base and the two are not additive. Said plainly rather
        // than left to look like double counting.
        for instance in InstanceDisk.all(appSupport: environment.appSupport) {
            let url = InstanceDisk.url(instance: instance, appSupport: environment.appSupport)
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
                  let allocated = values.totalFileAllocatedSize else { continue }
            total += Int64(allocated)
            let apparent = values.fileSize ?? allocated
            let orphaned = environment.instances[instance] == nil
            lines.append("\(instance): \(bytes(Int64(allocated))) on disk of \(bytes(Int64(apparent)))\(orphaned ? " - no such instance" : "")")
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
