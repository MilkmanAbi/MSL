import Foundation

/// Removing MSL from a Mac without removing the Linux on it.
///
/// The two are already in different places - MSL.app and the tools it
/// installs are replaceable, `Application Support/MSL` is the part that took
/// hours to download and years of somebody's work to fill - so "uninstall"
/// has a default that keeps the second and a deliberate, typed-confirmation
/// mode that doesn't.
///
/// Everything is expressed as a `Plan` first, because the worst possible
/// version of this feature is one that starts deleting and then tells you
/// what it deleted. `plan` only reads; `perform` only acts on what a plan
/// listed. Both take `Locations`, so the tests run against a temporary home
/// directory and never touch the real one.
///
/// Order matters in `perform` and is not cosmetic - see its doc comment.
public enum Uninstaller {

    public enum Mode: String, Sendable, CaseIterable {
        /// Remove MSL. Keep every image, instance and setting.
        case keepLinux
        /// Remove MSL and everything it ever stored, Linux included.
        case everything
    }

    /// One thing that will be removed, or one thing that will be kept.
    public struct Item: Equatable, Sendable {
        public let label: String
        public let path: String
        public let bytes: UInt64
        /// Why it's in this list, when that isn't obvious from the name.
        public let note: String?

        public init(label: String, path: String, bytes: UInt64, note: String? = nil) {
            self.label = label
            self.path = path
            self.bytes = bytes
            self.note = note
        }
    }

    public struct Plan: Sendable {
        public let mode: Mode
        public let removing: [Item]
        public let keeping: [Item]
        /// Things the user should know before saying yes.
        public let warnings: [String]
        /// Instances that will stop, and in `.everything` also be deleted.
        public let instances: [String]

        public var removingBytes: UInt64 { removing.reduce(0) { $0 + $1.bytes } }
        public var keepingBytes: UInt64 { keeping.reduce(0) { $0 + $1.bytes } }
    }

    /// Where everything lives. Injected so tests can build a whole fake Mac
    /// in a temporary directory.
    public struct Locations: Sendable {
        public var home: URL
        public var appSupport: URL
        /// Candidate locations for MSL.app and MSL Files.app. Every one that
        /// exists is removed: an upgrade people did by hand can leave two.
        public var appBundles: [URL]
        /// `/usr/local/bin/msl`, the symlink the installer package puts on
        /// PATH. `nil` outside the live locations, so a test never points
        /// this at the real one.
        public var commandSymlink: URL?

        /// `/Users/Shared/MSL` - the MSLAP administrator password, the
        /// signing keys, the pinned signers, the vault secret **and the
        /// encrypted containers themselves**.
        ///
        /// Missed entirely until now, and it is the worst thing to miss:
        /// a container can be gigabytes, so "uninstalled" could leave more
        /// behind than it removed. It is outside the home folder on
        /// purpose (it has to be outside the guest's `/mnt/mac` view), and
        /// that is exactly why a sweep of the home folder never found it.
        ///
        /// `nil` outside the live locations, so a test never points at the
        /// real one.
        public var sharedSupport: URL?

        /// `/Library/Application Support/MSL` - the enrolled MSLAP policy
        /// and any lineage certificates. Root-owned, so removing it needs
        /// authorisation; see `Plan.needsAuthorisation`.
        public var systemSupport: URL?

        public init(home: URL, appSupport: URL, appBundles: [URL],
                    commandSymlink: URL? = nil,
                    sharedSupport: URL? = nil, systemSupport: URL? = nil) {
            self.home = home
            self.appSupport = appSupport
            self.appBundles = appBundles
            self.commandSymlink = commandSymlink
            self.sharedSupport = sharedSupport
            self.systemSupport = systemSupport
        }

        public static var live: Locations {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return Locations(
                home: home,
                appSupport: MSLPaths.appSupport,
                appBundles: [
                    URL(fileURLWithPath: "/Applications/MSL.app"),
                    home.appendingPathComponent("Applications/MSL.app"),
                    // MSL Files ships with MSL as its own app, so it goes too.
                    URL(fileURLWithPath: "/Applications/MSL Files.app"),
                    home.appendingPathComponent("Applications/MSL Files.app"),
                ],
                commandSymlink: URL(fileURLWithPath: "/usr/local/bin/msl"),
                sharedSupport: MSLAPKeyStore.directory,
                systemSupport: URL(fileURLWithPath: "/Library/Application Support/MSL"))
        }

        var launchAgents: [URL] {
            let directory = home.appendingPathComponent("Library/LaunchAgents")
            return [MSLPaths.launchAgentLabel, LoginItem.terminal.label, LoginItem.app.label]
                .map { directory.appendingPathComponent("\($0).plist") }
        }

        var generatedApps: URL { home.appendingPathComponent("Applications/MSL") }
        var caches: URL { home.appendingPathComponent("Library/Caches/MSL") }
        /// What macOS itself keeps for the app under its bundle id - URL
        /// caches and cookies. Missed until 2026-09-16.
        var appCaches: URL { home.appendingPathComponent("Library/Caches/com.msl.app") }
        var httpStorage: URL { home.appendingPathComponent("Library/HTTPStorages/com.msl.app") }
        var logs: URL { home.appendingPathComponent("Library/Logs/MSL") }
        var preferences: URL { home.appendingPathComponent("Library/Preferences/com.msl.app.plist") }
        var savedState: URL { home.appendingPathComponent("Library/Saved Application State/com.msl.app.savedState") }
        /// MSL Files keeps its own, under its own bundle id: theme, view mode,
        /// open windows.
        var filesPreferences: URL { home.appendingPathComponent("Library/Preferences/com.msl.files.plist") }
        var filesSavedState: URL { home.appendingPathComponent("Library/Saved Application State/com.msl.files.savedState") }
        var binDirectory: URL { appSupport.appendingPathComponent("bin") }
    }

    /// The guest-side helpers that share `bin/` with MSL's own tools. They
    /// are Linux binaries the host copies *into* instances, so they belong
    /// to the Linux side of the split, not to MSL the Mac app.
    public static let guestHelpers: Set<String> = ["x11tunnel", "fileopsd", "shellinit", "trafficd", "memd"]

    // MARK: - Planning

    /// Reads the disk and says what each mode would do. Never changes
    /// anything.
    /// What signs instance identities, and so must survive an uninstall that
    /// keeps the instances.
    static let identityEntries = ["machine-key", "identity-signers.json"]

    /// Everything in `/Users/Shared/MSL` that is the administrator's rather
    /// than the person's instances.
    static func adminOnlyEntries(in directory: URL) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { !identityEntries.contains($0) }.sorted()
    }

    public static func plan(mode: Mode, locations: Locations = .live,
                            instances: [String]? = nil) -> Plan {
        let fm = FileManager.default
        var removing: [Item] = []
        var keeping: [Item] = []
        var warnings: [String] = []

        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func item(_ label: String, _ url: URL, note: String? = nil) -> Item? {
            guard exists(url) else { return nil }
            return Item(label: label, path: url.path, bytes: size(of: url), note: note)
        }

        for bundle in locations.appBundles {
            if let found = item(bundle.lastPathComponent, bundle) { removing.append(found) }
        }
        if let link = locations.commandSymlink, linkExists(link) {
            removing.append(Item(label: "The msl command", path: link.path, bytes: 0,
                                 note: "the link on PATH, put there by the installer"))
        }
        let profiles = ShellPathSetup.uninstall(home: locations.home, appSupport: locations.appSupport, dryRun: true)
        if !profiles.isEmpty {
            removing.append(Item(label: "msl on your shell's PATH", path: profiles.map(\.path).joined(separator: ", "),
                                 bytes: 0, note: "MSL's marked lines in \(profiles.map(\.lastPathComponent).joined(separator: ", "))"))
        }
        let agents = locations.launchAgents.filter(exists)
        if !agents.isEmpty {
            removing.append(Item(
                label: agents.count == 1 ? "Background service" : "Background service and login items",
                path: agents.map(\.path).joined(separator: ", "),
                bytes: agents.reduce(0) { $0 + size(of: $1) },
                note: "MSL stops starting when you log in"))
        }
        if let found = item("Linux apps added to your Mac", locations.generatedApps,
                            note: "the .app shortcuts in ~/Applications/MSL") { removing.append(found) }
        if let found = item("Caches", locations.caches) { removing.append(found) }
        if let found = item("App caches", locations.appCaches) { removing.append(found) }
        if let found = item("Web storage", locations.httpStorage) { removing.append(found) }
        if let found = item("Logs", locations.logs) { removing.append(found) }
        if let found = item("Saved window state", locations.savedState) { removing.append(found) }
        if let found = item("MSL Files window state", locations.filesSavedState) { removing.append(found) }

        // **The administrator's own files, and the encrypted containers.**
        //
        // `/Users/Shared/MSL` lives outside the home folder on purpose -
        // it has to be outside the guest's `/mnt/mac` view - which is
        // exactly why a sweep of the home folder never found it. It holds
        // the MSLAP password and signing keys, the pinned signers, the
        // vault secret, and the encrypted containers themselves. Those can
        // be gigabytes, so missing this meant "uninstalled" could leave
        // more behind than it removed.
        //
        // The admin material always goes: it is MSL's record of who
        // administers this Mac, not the person's Linux.
        //
        // **But not `machine-key`, when the Linux is being kept.** That key
        // is what signs instance identities, and an instance outlives an
        // uninstall only to find its own identity unverifiable - `msl
        // doctor` reports "issued by key …, which this Mac does not accept"
        // for every instance that was kept, and there is no way back,
        // because refusing to re-sign an identity is the whole point of the
        // scheme. Removing the key that validates the thing being kept is
        // incoherent, so in `keepLinux` the identity keys stay and only the
        // administrator's own material is taken.
        if let shared = locations.sharedSupport, exists(shared) {
            let vaults = shared.appendingPathComponent("vaults")
            if mode == .everything {
                removing.append(Item(
                    label: "Administrator keys and encrypted disks",
                    path: shared.path, bytes: size(of: shared),
                    note: exists(vaults)
                        ? "the admin password, the signing keys, and the encrypted containers - "
                          + "an instance kept below is moved back out of its container first"
                        : "the admin portal's password and signing keys"))
            } else {
                for name in adminOnlyEntries(in: shared) {
                    let item = shared.appendingPathComponent(name)
                    removing.append(Item(
                        label: name == "vaults" ? "Encrypted disks" : "Administrator keys",
                        path: item.path, bytes: size(of: item),
                        note: name == "vaults"
                            ? "the containers - an instance kept below is moved out of its first"
                            : "the admin portal's password and signing keys"))
                }
                for name in identityEntries where exists(shared.appendingPathComponent(name)) {
                    keeping.append(Item(
                        label: "Instance identity keys",
                        path: shared.appendingPathComponent(name).path,
                        bytes: size(of: shared.appendingPathComponent(name)),
                        note: "what proves your instances are yours - removing this would "
                              + "leave every instance below unverifiable"))
                }
            }
        }
        if let system = locations.systemSupport, exists(system) {
            removing.append(Item(
                label: "The managed policy",
                path: system.path, bytes: size(of: system),
                note: "owned by the system, so removing it asks for your password"))
        }

        let tools = hostTools(in: locations.binDirectory)
        if !tools.isEmpty {
            removing.append(Item(
                label: "MSL's own programs",
                path: locations.binDirectory.path,
                bytes: tools.reduce(0) { $0 + size(of: $1) },
                note: tools.map { $0.lastPathComponent }.sorted().joined(separator: ", ")))
        }

        let names = instances ?? InstanceRegistry(path: locations.appSupport.appendingPathComponent("instances.json")).list()

        switch mode {
        case .keepLinux:
            keeping.append(contentsOf: linuxItems(locations: locations, instanceCount: names.count))
            if let found = item("Your MSL settings", locations.preferences,
                                note: "so a reinstall remembers them") { keeping.append(found) }
            if let found = item("Your MSL Files settings", locations.filesPreferences,
                                note: "theme and view choices") { keeping.append(found) }
            if !names.isEmpty {
                warnings.append("\(names.count) instance\(names.count == 1 ? "" : "s") will be shut down, not deleted.")
            }
        case .everything:
            for entry in linuxItems(locations: locations, instanceCount: names.count) {
                removing.append(entry)
            }
            if let found = item("Your MSL settings", locations.preferences) { removing.append(found) }
            if let found = item("Your MSL Files settings", locations.filesPreferences) { removing.append(found) }
            if !names.isEmpty {
                warnings.append("\(names.count) instance\(names.count == 1 ? "" : "s") - \(names.sorted().joined(separator: ", ")) - will be deleted with everything in them.")
            }
            warnings.append("Nothing here can be recovered afterwards. Downloaded images have to be downloaded again.")
        }
        return Plan(mode: mode, removing: removing, keeping: keeping, warnings: warnings, instances: names.sorted())
    }

    /// The Linux side: what `keepLinux` keeps and `everything` removes.
    private static func linuxItems(locations: Locations, instanceCount: Int) -> [Item] {
        let fm = FileManager.default
        let support = locations.appSupport
        guard fm.fileExists(atPath: support.path) else { return [] }
        var items: [Item] = []

        // The disk images, which are almost always the whole of the size.
        let entries = (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        let imageFiles = entries.filter {
            $0.pathExtension == "img" || $0.lastPathComponent == "disk-Image"
                || $0.lastPathComponent.hasPrefix("disk-initramfs") || $0.lastPathComponent == "Image"
        }
        if !imageFiles.isEmpty {
            items.append(Item(
                label: "Linux disk images",
                path: support.path,
                bytes: imageFiles.reduce(0) { $0 + size(of: $1) },
                note: "\(imageFiles.count) file\(imageFiles.count == 1 ? "" : "s")"))
        }
        let customImages = support.appendingPathComponent(CustomImage.folderName)
        if fm.fileExists(atPath: customImages.path) {
            let built = CustomImage.scan(appSupport: support).count
            items.append(Item(label: "Custom images", path: customImages.path, bytes: size(of: customImages),
                              note: built == 0 ? nil : "\(built) image\(built == 1 ? "" : "s") you made"))
        }
        // Everything else in the folder, counted together: the registry, the
        // remembered accounts, storage policies, SSH keys, the app catalog.
        let rest = entries.filter {
            !imageFiles.contains($0) && $0.lastPathComponent != CustomImage.folderName
                && $0.lastPathComponent != "bin" && $0.lastPathComponent != "mslhd.sock"
        }
        if !rest.isEmpty {
            items.append(Item(
                label: "Instances, accounts and settings",
                path: support.path,
                bytes: rest.reduce(0) { $0 + size(of: $1) },
                note: instanceCount == 0 ? nil : "\(instanceCount) instance\(instanceCount == 1 ? "" : "s")"))
        }
        return items
    }

    /// MSL's own programs in `bin/`, which is shared with the guest helpers.
    ///
    /// Matched by name rather than against `HostToolInstaller.tools` alone:
    /// older builds and hand-made backups leave things like
    /// `mslhd.pre-power-hardening` behind, and an uninstall that leaves a
    /// stray daemon binary in place isn't an uninstall.
    static func hostTools(in binDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { url in
            let name = url.lastPathComponent
            if guestHelpers.contains(name) { return false }
            return name.hasPrefix("msl") || name == "virtualization.entitlements"
        }
    }

    // MARK: - Performing

    /// The parts that touch the running system rather than the filesystem.
    /// Replaced wholesale in tests.
    public struct Actions: Sendable {
        /// Unmount any instance still showing in Finder. First, always:
        /// webdavfs keeps polling a mount whose daemon has gone, and a poll
        /// has restarted a VM and thrown its saved state away before.
        public var unmountGuestVolumes: @Sendable () -> Void
        /// Power off everything that's running. Not hibernate: a saved
        /// state with no MSL to restore it is worse than a clean shutdown.
        public var shutdownInstances: @Sendable ([String]) -> Void
        /// `launchctl bootout` for one label, before its plist is deleted.
        public var bootout: @Sendable (String) -> Void
        /// Remove an instance's `~/.ssh/config` block and key record.
        public var forgetSSH: @Sendable (String) -> Void
        /// Close any tunnel publishing an instance to the internet.
        ///
        /// **Before anything else that stops MSL.** A tunnel is an ordinary
        /// `ssh` process, and nothing about removing MSL makes it exit: an
        /// uninstall performed while something was published would leave
        /// that instance reachable from the internet, by a process with no
        /// MSL left to stop it and nothing on screen saying it was there.
        /// The guest is about to be shut down or deleted, so the tunnel
        /// would route nowhere - but it would still be a listening address
        /// in somebody's hands.
        public var closePublicTunnels: @Sendable () -> Void

        /// Drop a preferences domain through `cfprefsd`.
        ///
        /// **Deleting the `.plist` is not enough and never was.** macOS
        /// reads and writes preferences through `cfprefsd`, which keeps the
        /// domain in memory: delete the file and the daemon simply writes
        /// it back out from its cache, settings intact. Measured on
        /// 2026-10-04 - MSL was uninstalled, the file removed, and
        /// `defaults read com.msl.app msl.welcome.seen` still answered `1`.
        /// The plist reappeared with a fresh timestamp, and the next fresh
        /// install skipped its first-run welcome because the flag had
        /// survived an uninstall that reported success.
        public var forgetDefaults: @Sendable (String) -> Void

        /// Tell LaunchServices to forget a bundle that has been removed.
        ///
        /// **Deleting the bundle is not enough.** LaunchServices keeps a
        /// removed app registered, and Spotlight indexes by NAME - so
        /// "MSL" keeps turning up in search and Launchpad after an
        /// uninstall that reported success. Same shape of problem as
        /// `forgetDefaults`, and found the same way: by looking afterwards.
        public var forgetLaunchServices: @Sendable (String) -> Void

        public init(unmountGuestVolumes: @escaping @Sendable () -> Void,
                    shutdownInstances: @escaping @Sendable ([String]) -> Void,
                    bootout: @escaping @Sendable (String) -> Void,
                    forgetSSH: @escaping @Sendable (String) -> Void,
                    forgetDefaults: @escaping @Sendable (String) -> Void = { _ in },
                    forgetLaunchServices: @escaping @Sendable (String) -> Void = { _ in },
                    closePublicTunnels: @escaping @Sendable () -> Void = {}) {
            self.forgetLaunchServices = forgetLaunchServices
            self.unmountGuestVolumes = unmountGuestVolumes
            self.shutdownInstances = shutdownInstances
            self.bootout = bootout
            self.forgetSSH = forgetSSH
            self.forgetDefaults = forgetDefaults
            self.closePublicTunnels = closePublicTunnels
        }

        public static var live: Actions {
            Actions(
                unmountGuestVolumes: { unmountEveryGuestVolume() },
                shutdownInstances: { names in
                    for name in names {
                        guard let status = DaemonClient.send(.status(instance: name), timeout: 10),
                              status == "OK running" || status == "OK paused" else { continue }
                        _ = DaemonClient.send(.shutdown(instance: name), timeout: 120)
                    }
                },
                bootout: { label in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                },
                forgetSSH: { SSHSetup.forget(instance: $0) },
                forgetDefaults: { domain in
                    // Goes through `cfprefsd`, which is the only thing that
                    // actually forgets. The file removal that follows is a
                    // backstop for a domain this process cannot reach.
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                    UserDefaults.standard.synchronize()
                },
                forgetLaunchServices: { path in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath:
                        "/System/Library/Frameworks/CoreServices.framework/Frameworks"
                        + "/LaunchServices.framework/Support/lsregister")
                    process.arguments = ["-u", path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                },
                closePublicTunnels: {
                    // Asks the daemon to unpublish each one, which also
                    // puts the guest's SSH server back. Then kills whatever
                    // is still running, because the daemon may already be
                    // gone - this runs during an uninstall - and a tunnel
                    // outlives the thing that started it.
                    let support = MSLPaths.appSupport.appendingPathComponent("public")
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
                    for file in names where file.hasSuffix(".json") {
                        _ = DaemonClient.send(.publicRevoke(instance: String(file.dropLast(5))), timeout: 60)
                    }
                    for file in names where file.hasSuffix(".tunnel.pid") {
                        guard let text = try? String(contentsOf: support.appendingPathComponent(file),
                                                     encoding: .utf8),
                              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        else { continue }
                        // Checks the pid is still an ssh tunnel before
                        // signalling it. Pids are reused, and these come off
                        // disk - possibly written by a daemon that died
                        // weeks ago.
                        ProcessIdentity.terminateSSHTunnel(pid: pid)
                    }
                })
        }

        /// Does nothing. For `--dry-run` and for tests.
        public static var none: Actions {
            Actions(unmountGuestVolumes: {}, shutdownInstances: { _ in }, bootout: { _ in },
                    forgetSSH: { _ in }, closePublicTunnels: {})
        }
    }

    public struct Failure: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    public struct Report: Sendable {
        /// What happened, in order, in words meant for a person.
        public var steps: [String] = []
        public var removed: [String] = []
        public var failed: [Failure] = []
        /// Paths only an administrator can remove - `/usr/local/bin/msl` and
        /// `/Applications/MSL.app`, which the installer package writes as root. Not a failure: the
        /// uninstall worked, and one `sudo rm` finishes it.
        public var needsSudo: [String] = []
        /// Set when a policy refused the uninstall, and nothing was done.
        ///
        /// Its own field rather than a thrown error, because a caller has
        /// to be able to tell "refused" from "failed" - one is an
        /// administrator's decision to explain, the other is a bug.
        public var refusedByPolicy: String?
        public var succeeded: Bool { failed.isEmpty }
    }

    /// Carries out a plan.
    ///
    /// The order is the point:
    ///  1. unmount Finder volumes, so nothing pokes a dying daemon;
    ///  2. power off running instances, while `mslhd` is still there to do it;
    ///  3. bootout and delete the LaunchAgents, so nothing restarts;
    ///  4. the replaceable Mac-side files;
    ///  5. in `.everything`, the SSH entries and then Application Support;
    ///  6. MSL.app;
    ///  7. **MSL's own programs last.** `msl uninstall` is running from
    ///     `bin/msl`; macOS keeps a running binary alive after its file is
    ///     gone, so deleting it here is safe - but if an earlier step fails,
    ///     the user still has a working `msl` and a working app to retry with.
    @discardableResult
    /// **`locations` is deliberately required.** It used to default to
    /// `.live`, and a test that called `perform(plan, dryRun: false, actions:)`
    /// without it ran the real uninstall against this Mac on every
    /// `swift test` - deleting `/Users/Shared/MSL`, and with it the signing
    /// key, the pinned signers and the vault secret. Every instance then
    /// read as "identity does not verify", which looked like an identity bug
    /// and was really the test suite. Making it explicit removes the whole
    /// class of mistake: there is no way to call this and quietly mean the
    /// machine it is running on.
    public static func perform(_ plan: Plan, locations: Locations,
                               dryRun: Bool = false, actions: Actions = .live,
                               log: ((String) -> Void)? = nil) -> Report {
        var report = Report()
        let fm = FileManager.default
        // A dry run must not stop instances or unload anything either.
        let effects = dryRun ? Actions.none : actions

        func step(_ text: String) {
            report.steps.append(text)
            log?(text)
        }
        func remove(_ url: URL, _ label: String) {
            guard fm.fileExists(atPath: url.path) else { return }
            step("\(dryRun ? "would remove" : "removing") \(label)")
            guard !dryRun else { return }
            do {
                try fm.removeItem(at: url)
                report.removed.append(url.path)
            } catch {
                report.failed.append(Failure(path: url.path, reason: "\(error)"))
                log?("  couldn't remove \(url.path): \(error)")
            }
        }

        // **MSLAP, here rather than only in the CLI.**
        //
        // It was checked in `msl uninstall` alone, which is the shape of
        // mistake the per-app launch commands already made: the menu is
        // not the only way in, and hiding a control is not refusing an
        // action. A GUI uninstaller added later would have walked straight
        // past it. This is the one place the work actually happens, so a
        // refusal here binds every caller by construction.
        //
        // A dry run is allowed: reading what WOULD be removed tells a
        // managed user why they cannot, which is the opposite of
        // dangerous.
        if !dryRun, !MSLAPGate.allows("system.uninstall", instance: nil) {
            report.refusedByPolicy = MSLAPGate.reason("system.uninstall", instance: nil)
                ?? "Not allowed by the MSL Admin Portal"
            step("refused: \(report.refusedByPolicy!)")
            return report
        }

        step(dryRun ? "dry run - nothing will be changed" : "uninstalling MSL")

        // **First of all.** Anything published is reachable from the
        // internet by an ordinary `ssh` process that nothing here would
        // otherwise stop, and which outlives both the daemon and this
        // program. Leaving one running would mean an uninstall that reports
        // success while a listening address somebody else holds is still
        // pointed at this Mac.
        if !dryRun {
            step("closing anything published to the internet")
            effects.closePublicTunnels()
        } else {
            step("would close anything published to the internet")
        }

        // The keys MSL made for reaching published instances from this Mac.
        // They live outside the home directory - deliberately, so no guest
        // can read them - which also means the sweep of Application Support
        // below would never find them.
        let publicKeys = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSL-public", isDirectory: true)
        if plan.mode == .everything { remove(publicKeys, "public SSH keys") }
        step(dryRun ? "would unmount any instance showing in Finder" : "checking for mounted instances")
        effects.unmountGuestVolumes()
        if !plan.instances.isEmpty {
            step("\(dryRun ? "would shut down" : "shutting down") \(plan.instances.joined(separator: ", "))")
            effects.shutdownInstances(plan.instances)
        }

        for agent in locations.launchAgents where fm.fileExists(atPath: agent.path) {
            let label = agent.deletingPathExtension().lastPathComponent
            step("\(dryRun ? "would stop" : "stopping") \(label)")
            effects.bootout(label)
            remove(agent, label)
        }

        remove(locations.generatedApps, "the Linux apps added to your Mac")
        remove(locations.caches, "caches")
        remove(locations.appCaches, "app caches")
        remove(locations.httpStorage, "web storage")
        remove(locations.logs, "logs")
        remove(locations.savedState, "saved window state")
        remove(locations.filesSavedState, "MSL Files window state")

        if plan.mode == .everything {
            for instance in plan.instances {
                step("\(dryRun ? "would forget" : "forgetting") the SSH entry for \(instance)")
                effects.forgetSSH(instance)
            }
            // The domain first, then the file. The other way round, or the
            // file alone, leaves `cfprefsd` holding every setting and
            // rewriting the plist moments later - see `forgetDefaults`.
            if !dryRun {
                effects.forgetDefaults("com.msl.app")
                effects.forgetDefaults("com.msl.files")
            }
            remove(locations.preferences, "your MSL settings")
            remove(locations.filesPreferences, "your MSL Files settings")
            remove(locations.appSupport, "every image, instance and setting")
        }

        // **Protected instances come out of their containers first, and
        // only when the Linux is being kept.**
        //
        // The key that opens a container is derived from a secret in
        // /Users/Shared/MSL, which is about to go. Removing that while an
        // instance's disk is still inside leaves the person with an
        // encrypted blob nothing can ever open again - the one outcome
        // worse than deleting it, because it looks like their data is
        // still there. In `.everything` the containers go with the rest.
        if plan.mode == .keepLinux, !dryRun {
            for name in plan.instances {
                guard case .valid(let identity) = InstanceIdentityStore.verdict(for: name),
                      InstanceVault.exists(serial: identity.serial) else { continue }
                step("taking \(name)'s disk back out of its encrypted container")
                do {
                    try InstanceVault.moveOut(instance: name, identity: identity,
                                              diskPath: InstanceDisk.url(instance: name).path)
                } catch {
                    // Said loudly rather than swallowed: the person is
                    // about to lose the key, and this is their one warning.
                    report.failed.append(Failure(
                        path: InstanceVault.url(serial: identity.serial).path,
                        reason: "couldn't take \(name) out of its container (\(error)). Its disk "
                              + "stays encrypted and the key is about to be removed - copy "
                              + "/Users/Shared/MSL somewhere safe before continuing."))
                    log?("  WARNING: \(name) is still encrypted and its key is about to go")
                }
            }
        }

        // The administrator's own records: the MSLAP password, the signing
        // keys, the pinned signers, the vault secret, and any containers
        // left. Outside the home folder on purpose - it has to be outside
        // the guest's /mnt/mac view - which is exactly why a sweep of the
        // home folder never found it.
        //
        // **And it honours the mode, which `plan` alone could not.** Listing
        // the identity keys as kept was worth nothing while this removed the
        // directory they are in whatever the plan said - so "keep my Linux"
        // still left every kept instance unverifiable. The two must agree,
        // and this is the half that actually does it.
        if let shared = locations.sharedSupport {
            if plan.mode == .everything {
                remove(shared, "the admin portal's keys and any encrypted disks")
            } else {
                for name in adminOnlyEntries(in: shared) {
                    remove(shared.appendingPathComponent(name),
                           name == "vaults" ? "the encrypted disks"
                                            : "the admin portal's \(name)")
                }
            }
        }

        // The enrolled policy and lineage certificates. Root-owned, so this
        // is expected to be refused for an ordinary user and reported as
        // one authorised command rather than as a failure.
        if let system = locations.systemSupport, fm.fileExists(atPath: system.path) {
            step("\(dryRun ? "would remove" : "removing") the managed policy")
            if !dryRun {
                do {
                    try fm.removeItem(at: system)
                    report.removed.append(system.path)
                } catch {
                    report.needsSudo.append(system.path)
                    log?("  \(system.path) is owned by the system and needs administrator rights")
                }
            }
        }

        // The installer package puts MSL.app in /Applications owned by root,
        // so a user's own uninstall can't delete it. That isn't a failure:
        // it goes on the list the closing `sudo` command finishes.
        for bundle in locations.appBundles where fm.fileExists(atPath: bundle.path) {
            step("\(dryRun ? "would remove" : "removing") \(bundle.lastPathComponent) (\(bundle.path))")
            guard !dryRun else { continue }
            do {
                try fm.removeItem(at: bundle)
                report.removed.append(bundle.path)
            } catch where fm.fileExists(atPath: bundle.path) && !fm.isWritableFile(atPath: bundle.path) {
                report.needsSudo.append(bundle.path)
                log?("  \(bundle.path) was installed by the package and needs administrator rights")
            } catch {
                report.failed.append(Failure(path: bundle.path, reason: "\(error)"))
                log?("  couldn't remove \(bundle.path): \(error)")
            }
        }

        // The PATH symlink, once the bundle it points into is gone. Owned by
        // root, because only the installer package could create it, so a
        // user's own `msl uninstall` is expected to be refused here - which
        // is reported as one `sudo rm`, not as a failed uninstall.
        if let link = locations.commandSymlink, linkExists(link) {
            step("\(dryRun ? "would remove" : "removing") the msl command on PATH")
            if !dryRun {
                do {
                    try fm.removeItem(at: link)
                    report.removed.append(link.path)
                } catch {
                    report.needsSudo.append(link.path)
                    log?("  \(link.path) needs administrator rights")
                }
            }
        }

        // The PATH lines in the shell profiles, and the link they point at.
        if plan.removing.contains(where: { $0.label == "msl on your shell's PATH" }) || fm.fileExists(atPath: ShellPathSetup.commandDirectory(appSupport: locations.appSupport).path) {
            step("\(dryRun ? "would remove" : "removing") msl from your shell profiles")
            let edited = ShellPathSetup.uninstall(home: locations.home, appSupport: locations.appSupport, dryRun: dryRun)
            if !dryRun { report.removed.append(contentsOf: edited.map(\.path)) }
        }

        // **Traces that are not files**, and so were invisible to every
        // version of this before. Each one is something a person would
        // still see after an "uninstall" and reasonably call a bug.
        if !dryRun {
            // Dock tiles for generated Linux apps. A pin is a PATH, so
            // once the bundles are gone the Dock draws a "?" the person
            // has to drag off by hand. One batched write, so one Dock
            // restart - each restart blinks the wallpaper too.
            let pinned = DockPinner.unpinAll(under: locations.generatedApps)
            if pinned > 0 { step("removed \(pinned) Linux app\(pinned == 1 ? "" : "s") from the Dock") }

            // LaunchServices keeps a removed bundle registered, and
            // Spotlight indexes by NAME - so "MSL" keeps appearing in
            // search and Launchpad until this runs.
            for bundle in locations.appBundles where !fm.fileExists(atPath: bundle.path) {
                effects.forgetLaunchServices(bundle.path)
            }
            step("told macOS to forget the app bundles")
        }

        // Last, deliberately - see the doc comment.
        for tool in hostTools(in: locations.binDirectory) {
            remove(tool, tool.lastPathComponent)
        }
        if plan.mode == .keepLinux, let left = try? fm.contentsOfDirectory(atPath: locations.binDirectory.path), left.isEmpty {
            remove(locations.binDirectory, "the empty bin folder")
        }

        if plan.mode == .keepLinux {
            step(dryRun
                 ? "would keep \(format(plan.keepingBytes)) of Linux in \(locations.appSupport.path)"
                 : "kept \(format(plan.keepingBytes)) of Linux in \(locations.appSupport.path)")
        }
        return report
    }

    // MARK: - Helpers

    /// Unmounts every instance Finder still has mounted.
    ///
    /// MSL mounts each guest over WebDAV on a loopback address, so its
    /// mounts are the `webdav` ones whose remote is a localhost URL - see
    /// `VMManager`'s mount handling.
    /// Public because the update path has to do this **before** it
    /// hibernates: webdavfs polling a mounted instance resumes the guest and
    /// deletes its saved state, which is how a stop during a mount once left
    /// a hibernated instance with nothing to come back to.
    public static func unmountEveryGuestVolume() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for line in output.split(separator: "\n") where line.contains("webdav") {
            // "http://127.0.0.1:PORT/ on /Volumes/NAME (webdav, ...)"
            guard line.contains("127.0.0.1") || line.contains("localhost"),
                  let range = line.range(of: " on "),
                  let end = line.range(of: " (", range: range.upperBound..<line.endIndex)
            else { continue }
            let path = String(line[range.upperBound..<end.lowerBound])
            for arguments in [["umount", path], ["umount", "-f", path]] {
                let umount = Process()
                umount.executableURL = URL(fileURLWithPath: "/sbin/\(arguments[0])")
                umount.arguments = Array(arguments.dropFirst())
                umount.standardOutput = FileHandle.nullDevice
                umount.standardError = FileHandle.nullDevice
                guard (try? umount.run()) != nil else { break }
                umount.waitUntilExit()
                if umount.terminationStatus == 0 { break }
            }
        }
    }

    /// Whether a symlink is there at all, dangling or not.
    ///
    /// `fileExists` follows the link, so it answers `false` for
    /// `/usr/local/bin/msl` the moment MSL.app has been deleted - which,
    /// in an uninstall, is a second earlier.
    static func linkExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Bytes on disk, following the whole tree. Allocated size, not
    /// apparent size: MSL's disk images are sparse, and reporting a 50 GB
    /// image that occupies 4 GB as "50 GB" would be a lie in the one place
    /// a user is deciding what to delete.
    /// Finishes the parts only an administrator can remove.
    ///
    /// **Why this exists rather than printing a command.** Until now an
    /// uninstall ended by telling the person to paste a `sudo rm -rf` into
    /// a terminal. That is not an uninstaller finishing; it is an
    /// uninstaller stopping and handing someone a loaded command. People
    /// who will not paste it are left with MSL half-removed and no idea
    /// which half, and people who will paste it are being trained to run
    /// `sudo rm -rf` from something they read on a screen.
    ///
    /// `osascript ... with administrator privileges` shows macOS's own
    /// authorisation dialog, naming the app asking. The command is built
    /// here from paths MSL itself collected - never from anything typed -
    /// and every path is quoted.
    ///
    /// Returns nil on success, or why it did not happen. A refusal is not
    /// a failure: somebody may simply have clicked Cancel, and they are
    /// told what is still there.
    public static func finishPrivileged(_ report: Report,
                                        run: ((String) throws -> Void)? = nil) -> String? {
        var commands: [String] = []
        for path in report.needsSudo {
            // Belt and braces on a command that runs as root: refuse
            // anything that is not an absolute path MSL could have put
            // there, and anything with a quote in it.
            guard path.hasPrefix("/"), !path.contains("'"), !path.contains("\n"),
                  privilegedPathIsOurs(path) else {
                return "refused to remove \(path) as administrator - it is not a path MSL installs"
            }
            commands.append("rm -rf '\(path)'")
        }
        // The package receipt, so a reinstall does not think MSL is
        // already there and skip its own work.
        commands.append("pkgutil --forget com.msl.app >/dev/null 2>&1 || true")
        let script = commands.joined(separator: " && ")

        do {
            if let run {
                try run(script)
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript(forShellCommand: script)]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                      as: UTF8.self)
                    return text.contains("-128")
                        ? "you cancelled, so these are still on this Mac: "
                          + report.needsSudo.joined(separator: ", ")
                        : text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            return "\(error)"
        }
        return nil
    }

    /// Wraps a shell command as an AppleScript that asks for authorisation.
    ///
    /// Its own function because the quoting is two layers deep - Swift,
    /// then AppleScript - and inlining it produced a literal that would
    /// not even parse. A backslash has to be doubled before a quote is
    /// escaped, or escaping the quote inserts a backslash that the first
    /// pass would have doubled.
    static func appleScript(forShellCommand command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"" + escaped + "\" with administrator privileges"
    }

    /// Whether a path is one MSL itself installs.
    ///
    /// The allowlist is deliberately short and literal. This guards a
    /// command that runs as root, so "looks like ours" is not good enough -
    /// it has to BE one of the handful of places MSL puts things.
    static func privilegedPathIsOurs(_ path: String) -> Bool {
        let allowed = [
            "/Applications/MSL.app",
            "/Applications/MSL Files.app",
            "/usr/local/bin/msl",
            "/Library/Application Support/MSL",
        ]
        return allowed.contains(path)
    }

    public static func size(of url: URL) -> UInt64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func allocated(_ item: URL) -> UInt64 {
            guard let values = try? item.resourceValues(forKeys: keys) else { return 0 }
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return allocated(url) }
        var total: UInt64 = 0
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                         options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let child as URL in walker {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            total += allocated(child)
        }
        return total
    }

    public static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
