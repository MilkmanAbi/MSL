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
        /// Candidate locations for MSL.app itself. Every one that exists is
        /// removed: an upgrade people did by hand can leave two.
        public var appBundles: [URL]
        /// `/usr/local/bin/msl`, the symlink the installer package puts on
        /// PATH. `nil` outside the live locations, so a test never points
        /// this at the real one.
        public var commandSymlink: URL?

        public init(home: URL, appSupport: URL, appBundles: [URL], commandSymlink: URL? = nil) {
            self.home = home
            self.appSupport = appSupport
            self.appBundles = appBundles
            self.commandSymlink = commandSymlink
        }

        public static var live: Locations {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return Locations(
                home: home,
                appSupport: MSLPaths.appSupport,
                appBundles: [
                    URL(fileURLWithPath: "/Applications/MSL.app"),
                    home.appendingPathComponent("Applications/MSL.app"),
                ],
                commandSymlink: URL(fileURLWithPath: "/usr/local/bin/msl"))
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
        var binDirectory: URL { appSupport.appendingPathComponent("bin") }
    }

    /// The guest-side helpers that share `bin/` with MSL's own tools. They
    /// are Linux binaries the host copies *into* instances, so they belong
    /// to the Linux side of the split, not to MSL the Mac app.
    public static let guestHelpers: Set<String> = ["x11tunnel", "fileopsd", "shellinit", "trafficd", "memd"]

    // MARK: - Planning

    /// Reads the disk and says what each mode would do. Never changes
    /// anything.
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
            if let found = item("MSL.app", bundle) { removing.append(found) }
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
            if !names.isEmpty {
                warnings.append("\(names.count) instance\(names.count == 1 ? "" : "s") will be shut down, not deleted.")
            }
        case .everything:
            for entry in linuxItems(locations: locations, instanceCount: names.count) {
                removing.append(entry)
            }
            if let found = item("Your MSL settings", locations.preferences) { removing.append(found) }
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

        public init(unmountGuestVolumes: @escaping @Sendable () -> Void,
                    shutdownInstances: @escaping @Sendable ([String]) -> Void,
                    bootout: @escaping @Sendable (String) -> Void,
                    forgetSSH: @escaping @Sendable (String) -> Void) {
            self.unmountGuestVolumes = unmountGuestVolumes
            self.shutdownInstances = shutdownInstances
            self.bootout = bootout
            self.forgetSSH = forgetSSH
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
                forgetSSH: { SSHSetup.forget(instance: $0) })
        }

        /// Does nothing. For `--dry-run` and for tests.
        public static var none: Actions {
            Actions(unmountGuestVolumes: {}, shutdownInstances: { _ in }, bootout: { _ in }, forgetSSH: { _ in })
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
    public static func perform(_ plan: Plan, locations: Locations = .live,
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

        step(dryRun ? "dry run - nothing will be changed" : "uninstalling MSL")
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

        if plan.mode == .everything {
            for instance in plan.instances {
                step("\(dryRun ? "would forget" : "forgetting") the SSH entry for \(instance)")
                effects.forgetSSH(instance)
            }
            remove(locations.preferences, "your MSL settings")
            remove(locations.appSupport, "every image, instance and setting")
        }

        // The installer package puts MSL.app in /Applications owned by root,
        // so a user's own uninstall can't delete it. That isn't a failure:
        // it goes on the list the closing `sudo` command finishes.
        for bundle in locations.appBundles where fm.fileExists(atPath: bundle.path) {
            step("\(dryRun ? "would remove" : "removing") MSL.app (\(bundle.path))")
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
    static func unmountEveryGuestVolume() {
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
