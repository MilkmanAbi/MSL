import AppKit
import Combine
import MSLCore
import SwiftUI

/// One registered instance, as the UI sees it.
struct Instance: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let distro: GuestDistro
    var state: InstanceState
    /// Whether the distro's disk image has actually been downloaded. An
    /// instance can be registered without ever having been installed, and
    /// offering "Start" for one of those just produces a confusing failure.
    var isInstalled: Bool
    /// Where this instance's Linux filesystem is mounted on the Mac, when
    /// it is running. `nil` otherwise.
    var sandboxMountPath: String?

    var isLive: Bool { state == .running || state == .paused || state == .transitioning }
}

/// Everything the UI reads and every action it can take.
///
/// Deliberately one object rather than a store per screen: the interesting
/// state here is all cross-cutting (which instances are live, how many
/// slots are left, whether a long operation is in flight), and splitting it
/// up mostly produces objects that have to ask each other questions.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var instances: [Instance] = []
    @Published private(set) var runningCount = 0
    @Published private(set) var runningCap = InstanceRegistry.maxConcurrentRunning
    @Published private(set) var daemonReachable = true

    @Published var selection: String?
    /// Instance names with an operation in flight, so their row can show a
    /// spinner and their buttons can disable without freezing the app.
    @Published private(set) var busy: Set<String> = []
    @Published var banner: Banner?
    /// Instances whose shipment is being written, plus `""` while one is
    /// being installed. Drives the spinners in the Tools card and the
    /// New Instance sheet.
    @Published var shipping: Set<String> = []
    /// The current line from `Shipment`, by the same key.
    @Published var shipmentStatus: [String: String] = [:]
    @Published var showingNewInstance = false

    /// Cached app lists, per instance.
    @Published private(set) var apps: [String: [LinuxApp]] = [:]
    @Published private(set) var scanning: Set<String> = []
    /// Distro -> latest progress line while its image is downloading.
    /// Keyed by distro, not instance, because the image is shared: two
    /// instances of the same distro are one download.
    @Published private(set) var installing: [GuestDistro: String] = [:]
    /// Distro -> how far its download has got, while bytes are arriving.
    /// Separate from `installing` because it is absent for the parts of an
    /// install that are not a transfer (verifying, unpacking), and the view
    /// should fall back to an indeterminate spinner for those.
    @Published private(set) var installTransfer: [GuestDistro: DistroInstaller.TransferProgress] = [:]
    /// Handles for stopping a download in progress, one per distro being
    /// installed. Not `@Published`: the view asks `isInstalling` whether to
    /// offer the button, and this is only ever read when it is pressed.
    private var installCancels: [GuestDistro: DistroInstaller.InstallCancellation] = [:]
    /// Apps whose high-resolution icon is being fetched from the guest, by
    /// `iconKey`. Drives the per-tile spinner.
    @Published private(set) var preparingIcons: Set<String> = []
    @Published private(set) var scanStatus: [String: String] = [:]
    @Published private(set) var installedBundles: [String: Set<String>] = [:]

    struct Banner: Identifiable {
        enum Kind { case error, info, success }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String?
    }

    private var refreshTask: Task<Void, Never>?

    /// Whether the user has explicitly turned the login item off, so it
    /// stays off across launches.
    nonisolated private static let launchAgentOptOutKey = "MSLLaunchAgentOptOut"
    /// `nonisolated` because the launch-time installer reads it from a
    /// detached task - it is a `UserDefaults` flag, which is safe to touch
    /// from anywhere.
    nonisolated static var launchAgentOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: launchAgentOptOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchAgentOptOutKey) }
    }

    /// Pinned Dock paths, read once and refreshed on change.
    ///
    /// `DockPinner.isPinned` parses `com.apple.dock`'s whole
    /// `persistent-apps` array; calling it from a view's `body` meant one
    /// parse per tile per render (twice, for the symbol and the tooltip).
    /// Fine for one app, absurd for sixty.
    @Published private(set) var pinnedPaths: Set<String> = []
    /// Per-app GPU/CPU choices (`AppGraphicsStore`), mirrored here so the
    /// tiles redraw when one changes.
    @Published var graphicsModes: [String: AppGraphicsMode] = AppGraphicsStore.load()
    /// Per-app launch overrides, for apps that need different arguments or
    /// a different binary than their `.desktop` entry names.
    @Published var customCommands: [String: String] = AppCustomCommandStore.load()
    /// Apps pinned to the top of each instance's Applications tab, by
    /// desktop-file path.
    @Published var topPins: [String: Set<String>] = AppModel.loadTopPins()

    /// Icons, loaded once per scan rather than per render - the same
    /// problem: `LinuxAppCatalog.icon` either reads a file off disk or
    /// draws a monogram, and it was doing so on every redraw of every tile.
    @Published private(set) var iconCache: [String: NSImage] = [:]

    /// The badge each instance wears, when its owner picked one
    /// (`InstanceAppearance`). Held here, not read per row: the sidebar
    /// redraws constantly and this would be a file read every time - the
    /// same lesson as `iconCache` and `graphicsModes` above.
    @Published var appearances: [String: InstanceAppearance] = InstanceAppearanceStore.load()

    /// Pictures someone chose, decoded once. Keyed on the stored file name,
    /// which changes on every import, so a replaced logo can never be served
    /// from this.
    ///
    /// Deliberately **not** `@Published`: `logo(of:)` fills it while a badge
    /// is drawing, and publishing a change from inside a view update is
    /// undefined behaviour in SwiftUI ("Publishing changes from within view
    /// updates"). Nothing is lost - `appearances` changing is what redraws
    /// the badge, and this only ever caches what that already decided.
    private var logoCache: [String: NSImage] = [:]

    /// The instance whose logo is being picked (`InstanceLogoSheet`).
    @Published var editingLogo: Instance?

    func appearance(of instance: String) -> InstanceAppearance {
        appearances[instance] ?? InstanceAppearance()
    }

    /// `instance`'s chosen picture, decoded on first use.
    func logo(of instance: String) -> NSImage? {
        guard let file = appearances[instance]?.image else { return nil }
        if let cached = logoCache[file] { return cached }
        guard let image = NSImage(contentsOf: InstanceAppearanceStore.imageURL(file)) else { return nil }
        logoCache[file] = image
        return image
    }

    /// Stores `appearance` for `instance` and redraws every badge of it.
    func setAppearance(_ appearance: InstanceAppearance, for instance: String) {
        guard InstanceAppearanceStore.set(appearance, for: instance) else {
            banner = Banner(kind: .error, title: "Couldn't save that logo",
                            detail: "MSL couldn't write to its Application Support folder.")
            return
        }
        if appearance.isDefault { appearances[instance] = nil } else { appearances[instance] = appearance }
    }

    /// Copies a picture in as `instance`'s logo. Reports rather than throws:
    /// the caller is a button.
    func chooseLogoImage(_ source: URL, for instance: String) {
        do {
            let file = try InstanceAppearanceStore.importImage(from: source, for: instance)
            var appearance = self.appearance(of: instance)
            appearance.image = file
            setAppearance(appearance, for: instance)
        } catch {
            banner = Banner(kind: .error, title: "Couldn't use that picture",
                            detail: error.localizedDescription)
        }
    }

    var atCap: Bool { runningCount >= runningCap }

    var selectedInstance: Instance? {
        instances.first { $0.name == selection }
    }

    // MARK: - Lifecycle

    /// `installsTools: false` is MSL Files: a separate app built from the
    /// same code that only needs the live instance list. Installing and
    /// re-signing the host tools, rewriting shell profiles and the LaunchAgent
    /// stay MSL's job - two apps doing it at once would race over the same
    /// files (and re-signing mslhd mid-flight is exactly what strips its
    /// entitlement).
    func start(installsTools: Bool = true) {
        if installsTools { installHostTools() }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func installHostTools() {
        // Installing the tools is what makes generated `.app` bundles and
        // the LaunchAgent work at all, and it has to happen from a build
        // the user actually ran - so it happens here, every launch, rather
        // than being a setup step somebody has to remember.
        Task.detached(priority: .utility) {
            HostToolInstaller.install(from: HostToolInstaller.runningBinaryDirectory)
            // Apps already added keep a copy of the launcher from the day they
            // were made; bring them up to date with the one just installed.
            LinuxAppBundle.refreshLaunchers()
            // `msl` in Terminal, no password: a PATH block in the shell
            // profiles. The first time it's written, every Terminal tab
            // already sitting at a prompt re-reads its profile too, so the
            // command works there without opening a new window.
            if !ShellPathSetup.install().isEmpty {
                await MainActor.run {
                    var error: NSDictionary?
                    NSAppleScript(source: ShellPathSetup.refreshOpenTerminalsScript())?.executeAndReturnError(&error)
                }
            }
            // Only if the user hasn't turned it off. Reinstalling
            // unconditionally made the Tools tab's toggle a lie: switching
            // it off deleted the plist, and the next launch wrote it
            // straight back, so the setting silently undid itself.
            if !AppModel.launchAgentOptedOut {
                DaemonClient.installLaunchAgent()
            }
            // "Open a Terminal at login" used to point straight at the `msl`
            // tool. Plain `msl` prints an overview now rather than opening a
            // shell (`CLIOverview`), so an item enabled before this version
            // would greet its owner at login with a help page. Rewriting it
            // is what installs the little script that supplies the `run`;
            // it is idempotent, so it also repairs a deleted one.
            if LoginItem.terminal.isEnabled {
                LoginItem.terminal.setEnabled(true)
            }
            // **And then make sure it is actually running.** The toggle above
            // is about *login* - whether mslhd comes back by itself after a
            // restart. It is not about whether the app works: opening MSL
            // with no daemon means a window that can list nothing and start
            // nothing, which is not a state worth showing anybody. So the app
            // starts it either way, including for someone who deliberately
            // turned the login agent off.
            //
            // `ensureRunning` returns at once when it is already up, so this
            // costs a connect on every launch and nothing else.
            do {
                try DaemonClient.ensureRunning()
            } catch {
                await MainActor.run { [weak self] in
                    self?.banner = Banner(
                        kind: .error, title: "MSL's background service didn't start",
                        detail: "\(error) - instances can't start without it.")
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Reading state

    func refresh() async {
        let snapshot = await Task.detached(priority: .utility) { () -> (String?, Bool) in
            (DaemonClient.send(.instanceDetails, timeout: 10), DaemonClient.isRunning())
        }.value

        // Every assignment below is guarded: @Published fires on assignment,
        // not on change, so this 3-second poll used to redraw every view in
        // the app each time - and an open context menu on an app tile was
        // torn down and rebuilt, flickering in and out while being read.
        if daemonReachable != snapshot.1 { daemonReachable = snapshot.1 }
        guard let response = snapshot.0, response.hasPrefix("OK") else {
            if !snapshot.1, !instances.isEmpty { instances = [] }
            return
        }

        var parsed: [Instance] = []
        var used = 0
        var cap = runningCap
        // The daemon's replies are "OK <body>", and a multi-line body's
        // first line therefore shares the "OK" line rather than following
        // it - so strip the prefix and parse every line the same way.
        // Dropping the first line instead silently discarded the
        // `#<used><cap>` header, which is why the sidebar read "0/4" with
        // an instance visibly running.
        let body = response.hasPrefix("OK")
            ? String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            : response
        for line in body.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "#", fields.count >= 3 {
                used = Int(fields[1]) ?? used
                cap = Int(fields[2]) ?? cap
                continue
            }
            guard fields.count >= 4, let distro = GuestDistro(rawValue: fields[1]) else { continue }
            parsed.append(Instance(
                name: fields[0], distro: distro,
                state: InstanceState(rawValue: fields[2]) ?? .stopped,
                isInstalled: fields[3] == "1",
                // Field 5 arrives only from a daemon new enough to send it,
                // and is empty for an instance that isn't running - the
                // mount exists only while the VM does.
                sandboxMountPath: fields.count >= 5 && !fields[4].isEmpty ? fields[4] : nil))
        }

        if instances != parsed { instances = parsed }
        // An instance that is gone takes its badge with it. The daemon
        // already forgets the stored one (`removeInstanceState`), but this
        // in-memory copy was only loaded at launch: within one session, a
        // new instance reusing a deleted one's name wore the old badge -
        // and the next change to it wrote that badge back to disk.
        let live = Set(parsed.map(\.name))
        let stale = appearances.keys.filter { !live.contains($0) }
        if !stale.isEmpty { for name in stale { appearances[name] = nil } }
        if runningCount != used { runningCount = used }
        if runningCap != cap { runningCap = cap }
        autoConfigureSSHIfNeeded(parsed)

        if selection == nil || !parsed.contains(where: { $0.name == selection }),
           selection != parsed.first?.name {
            selection = parsed.first?.name
        }
        for instance in parsed where apps[instance.name] == nil {
            let cached = LinuxAppCatalog.cached(instance: instance.name)
            if !cached.isEmpty {
                apps[instance.name] = cached
                cacheIcons(cached, instance: instance.name)
            }
            installedBundles[instance.name] = LinuxAppBundle.installedApps(instance: instance.name)
        }
        if pinnedPaths.isEmpty { refreshPinnedPaths() }
    }

    // MARK: - Instance actions

    func start(_ instance: Instance) {
        guard !atCap || instance.isLive else {
            banner = Banner(
                kind: .error, title: "\(runningCap) instances are already running",
                detail: "MSL runs at most \(runningCap) at once so they don't all hold memory at the same time. Suspend or shut one down first.")
            return
        }
        if deferForUserSetup(instance, then: { [weak self] in self?.start(instance) }) { return }
        perform(instance.name, title: "Couldn't start \(instance.name)") {
            DaemonClient.send(.resume(instance: instance.name), timeout: 180)
        }
    }

    func suspend(_ instance: Instance) {
        perform(instance.name, title: "Couldn't suspend \(instance.name)") {
            DaemonClient.send(.suspend(instance: instance.name), timeout: 120)
        }
    }

    /// Whether the welcome guide is on screen.
    ///
    /// Shown once per Mac on the first launch, and from the Help menu after
    /// that. Lives here rather than in a `@State` because the menu command
    /// is built in `MSLApp` and has no other way to reach the window.
    @Published var showingWelcome = false

    /// Opens it if this Mac has never been through it.
    func showWelcomeIfNeeded() {
        guard !WelcomeGuide.hasBeenSeen else { return }
        showingWelcome = true
    }

    /// Finish, Skip and close all land here: whichever it was, the guide is
    /// done and does not come back on its own.
    func finishWelcome() {
        showingWelcome = false
        WelcomeGuide.hasBeenSeen = true
    }

    /// Whether the "hibernate is not how you save your work" explanation has
    /// been dismissed for good.
    static var hibernateWarningSilenced: Bool {
        get { UserDefaults.standard.bool(forKey: "msl.hibernate.warned") }
        set { UserDefaults.standard.set(newValue, forKey: "msl.hibernate.warned") }
    }

    func hibernate(_ instance: Instance) {
        // Said before it happens, once, because this is the thing people are
        // surprised by - and being surprised by it costs them whatever was
        // open. Hibernate stops the VM, and a stopped VM takes mslgd with
        // it: the apps' X server is on the Mac, so their windows cannot come
        // back. The shell can, and does.
        HibernateNotice.confirm(instance: instance) { [weak self] goAhead in
            guard goAhead, let self else { return }
            self.perform(instance.name, title: "Couldn't hibernate \(instance.name)") {
                DaemonClient.send(.hibernate(instance: instance.name), timeout: 300)
            }
        }
    }

    func shutDown(_ instance: Instance) {
        perform(instance.name, title: "Couldn't shut down \(instance.name)") {
            DaemonClient.send(.shutdown(instance: instance.name), timeout: 300)
        }
    }

    func create(name: String, distro: GuestDistro) {
        perform(name, title: "Couldn't create \(name)", success: "Created \(name)",
                onSuccess: { [weak self] in self?.beginFirstRunGuide(for: name) }) {
            DaemonClient.send(.createInstance(instance: name, distro: distro), timeout: 30)
        }
    }

    // MARK: - First run

    /// Walks a new instance through what it needs before it is any use: how
    /// big its disk is (Overview, the Storage card, highlighted), then its
    /// Linux account (the Terminal tab, where `msl` asks for one).
    ///
    /// That order is forced, not chosen: a disk's size can only change while
    /// the instance is off, and opening its terminal starts it. Before this,
    /// a new instance landed on the Applications tab with the default disk
    /// and nothing to say either choice existed - so people found out their
    /// disk size by running out of it.
    struct FirstRunGuide: Equatable {
        enum Step: Equatable { case storage, account }
        let instance: String
        var step: Step
    }

    @Published var firstRunGuide: FirstRunGuide?

    /// Selects `name` and starts its guide. An instance whose distro is
    /// still downloading keeps the guide waiting; the Storage card has no
    /// disk to size until the download lands.
    func beginFirstRunGuide(for name: String) {
        selection = name
        firstRunGuide = FirstRunGuide(instance: name, step: .storage)
    }

    func continueFirstRunGuideToAccount() {
        guard var guide = firstRunGuide else { return }
        guide.step = .account
        firstRunGuide = guide
    }

    func endFirstRunGuide() {
        firstRunGuide = nil
    }

    /// The instance whose removal is waiting on the typed confirmation - see
    /// `RemoveInstanceSheet`. Every Remove button goes through here, never
    /// straight to `remove(_:)`.
    @Published var pendingRemoval: Instance?

    func requestRemove(_ instance: Instance) {
        pendingRemoval = instance
    }

    /// A whole distro installation waiting on its typed confirmation - see
    /// `RemoveDistroSheet`. A wrapper because a sheet needs something
    /// `Identifiable`, and `GuestDistro` is shared with the daemon.
    struct DistroRemovalRequest: Identifiable {
        let distro: GuestDistro
        var id: String { distro.rawValue }
    }

    @Published var pendingDistroRemoval: DistroRemovalRequest?

    func requestDistroRemoval(_ distro: GuestDistro) {
        pendingDistroRemoval = DistroRemovalRequest(distro: distro)
    }

    func instances(of distro: GuestDistro) -> [Instance] {
        instances.filter { $0.distro == distro }
    }

    /// Every instance of `distro`, and the disk they share. The only way the
    /// app frees a distro's disk space - removing instances one at a time
    /// leaves the disk, since other instances could still be using it.
    func removeDistroInstallation(_ distro: GuestDistro) {
        let names = instances(of: distro).map(\.name)
        let displayName = distro.displayName
        perform("distro-\(distro.rawValue)",
                title: "Couldn't delete the \(displayName) installation",
                success: "Deleted the \(displayName) installation") {
            let response = DaemonClient.send(.removeDistro(distro: distro), timeout: 900)
            if response?.hasPrefix("OK") == true {
                for name in names {
                    try? LinuxAppBundle.removeAll(instance: name)
                    LinuxAppCatalog.clearCache(instance: name)
                }
            }
            return response
        }
    }

    /// Removing an instance also removes every `.app` generated for it -
    /// a bundle left pointing at a deleted instance would sit in the
    /// user's Applications folder forever, and double-clicking it would do
    /// nothing but write a line to a log.
    func remove(_ instance: Instance, keepDisk: Bool = false) {
        perform(instance.name, title: "Couldn't remove \(instance.name)", success: "Removed \(instance.name)") {
            let response = DaemonClient.send(.remove(instance: instance.name, keepDisk: keepDisk), timeout: 300)
            if response?.hasPrefix("OK") == true {
                try? LinuxAppBundle.removeAll(instance: instance.name)
                LinuxAppCatalog.clearCache(instance: instance.name)
            }
            return response
        }
    }

    /// Opens a real Terminal window on the instance. `msl` is an
    /// interactive terminal program - it needs a tty, so it has to be
    /// handed to Terminal rather than run as a subprocess here.
    // MARK: - First-start account

    /// Something that was about to start an instance, waiting for the
    /// distro's Linux account to be created first.
    struct UserSetupRequest: Identifiable {
        let id = UUID()
        let instance: Instance
        let then: @MainActor () -> Void
    }

    /// Drives `LinuxUserSetupSheet`.
    @Published var userSetup: UserSetupRequest?

    /// Whether this instance still has no everyday account - the WSL-style
    /// question every instance gets asked on its first start.
    ///
    /// Per instance, not per distro: each one has its own disk and so its own
    /// `/etc/passwd`, so a second instance of a distro you already use is a
    /// fresh machine that needs its own account (`InstanceDisk`).
    func needsUserSetup(_ instance: Instance) -> Bool {
        instance.isInstalled && LinuxUserSetup.defaultUser(forInstance: instance.name) == nil
    }

    /// Asks for the account first when the distro has none, and runs
    /// `action` once it exists. Returns whether it deferred.
    ///
    /// The Terminal tab doesn't come through here: it runs `msl`, which asks
    /// in the terminal itself, exactly as it would in Terminal.app.
    private func deferForUserSetup(_ instance: Instance, then action: @escaping @MainActor () -> Void) -> Bool {
        guard needsUserSetup(instance) else { return false }
        userSetup = UserSetupRequest(instance: instance, then: action)
        return true
    }

    func finishUserSetup(_ request: UserSetupRequest, username: String, warning: String?) {
        userSetup = nil
        banner = Banner(
            kind: warning == nil ? .success : .info,
            title: "Linux account “\(username)” created",
            detail: warning ?? "It's the login for \(request.instance.distro.displayName) from now on, and sudo asks for its password.")
        request.then()
        Task { await refresh() }
    }

    // MARK: - Snapshots

    @Published private(set) var snapshots: [String: [String]] = [:]

    func snapshots(for instance: Instance) -> [String] { snapshots[instance.name] ?? [] }

    func refreshSnapshots(_ instance: Instance) {
        let name = instance.name
        Task { [weak self] in
            let response = await Task.detached(priority: .utility) {
                DaemonClient.send(.snapshotList(instance: name), timeout: 30)
            }.value
            guard let self, let response, response.hasPrefix("OK") else { return }
            let body = String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            self.snapshots[name] = body == "(none)" || body.isEmpty
                ? []
                : body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    func saveSnapshot(named snapshotName: String, of instance: Instance) {
        perform(instance.name, title: "Couldn't save the snapshot", success: "Saved '\(snapshotName)'") {
            DaemonClient.send(.snapshotSave(instance: instance.name, name: snapshotName), timeout: 600)
        }
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); refreshSnapshots(instance) }
    }

    func restoreSnapshot(named snapshotName: String, of instance: Instance) {
        perform(instance.name, title: "Couldn't restore '\(snapshotName)'", success: "Restored '\(snapshotName)'") {
            DaemonClient.send(.snapshotRestore(instance: instance.name, name: snapshotName), timeout: 600)
        }
    }

    // MARK: - Sandbox

    /// Last known gates per instance. Populated by `refreshSandbox`, which
    /// asks the daemon rather than remembering what was last requested -
    /// the two can differ (a network attachment can drop on its own), and
    /// that difference is exactly what the tab exists to show.
    @Published private(set) var sandbox: [String: SandboxPolicy] = [:]

    /// Instances with a change in flight, so the toggles can be disabled
    /// rather than bouncing back when the answer arrives.
    @Published private(set) var sandboxBusy: Set<String> = []

    func sandboxPolicy(for instance: Instance) -> SandboxPolicy {
        sandbox[instance.name] ?? .open
    }

    func refreshSandbox(_ instance: Instance) {
        let name = instance.name
        Task { [weak self] in
            let response = await Task.detached(priority: .utility) {
                DaemonClient.send(.sandboxGet(instance: name), timeout: 15)
            }.value
            guard let self, let response, response.hasPrefix("OK") else { return }
            let token = String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard let policy = SandboxPolicy.fromWireToken(token) else { return }
            self.sandbox[name] = policy
        }
    }

    /// Sends the whole policy, not the one gate that changed.
    ///
    /// The daemon answers with what the devices report afterwards, and that
    /// answer - not the request - is what gets stored. So a gate that
    /// refuses to close shows as open instead of showing the lie the user
    /// asked for.
    func setSandbox(_ policy: SandboxPolicy, for instance: Instance) {
        let name = instance.name
        guard !sandboxBusy.contains(name) else { return }
        sandboxBusy.insert(name)

        // Optimistic, so a toggle feels immediate on a daemon round trip -
        // corrected below by whatever actually happened.
        let previous = sandbox[name]
        sandbox[name] = policy

        Task { [weak self] in
            let response = await Task.detached(priority: .utility) {
                DaemonClient.send(.sandboxSet(instance: name, token: policy.wireToken), timeout: 30)
            }.value
            guard let self else { return }
            self.sandboxBusy.remove(name)
            guard let response, response.hasPrefix("OK"),
                  let applied = SandboxPolicy.fromWireToken(
                      String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            else {
                self.sandbox[name] = previous
                self.banner = Banner(kind: .error, title: "Couldn't change the sandbox",
                                     detail: "MSL's background service didn't accept the change.")
                return
            }
            self.sandbox[name] = applied
            if applied != policy {
                // Not an error - the devices are allowed to disagree - but
                // silently showing something other than what was asked for
                // would be worse than saying so.
                self.banner = Banner(kind: .info, title: "The sandbox settled differently",
                                     detail: "One of the gates didn't end up where it was put. "
                                           + "The switches show what the VM actually reports.")
            }
        }
    }

    func setSandboxGate(_ gate: SandboxPolicy.Gate, closed: Bool, for instance: Instance) {
        var policy = sandboxPolicy(for: instance)
        policy.set(gate, closed: closed)
        setSandbox(policy, for: instance)
    }

    // MARK: - Guest traffic

    /// What the guest's own kernel says its sockets are.
    ///
    /// Distinct from `ActivityLog`, which is MSL's own traffic seen from the
    /// host. This is the other half - and the only half that can answer
    /// "what is this Linux box talking to on the internet".
    enum GuestTraffic {
        case idle
        case unavailable          // an image built before `trafficd`
        case notRunning
        case loaded([TrafficProtocol.Connection])
        case failed(String)
    }

    @Published private(set) var guestTraffic: [String: GuestTraffic] = [:]

    func guestTraffic(for instance: Instance) -> GuestTraffic {
        guestTraffic[instance.name] ?? .idle
    }

    func refreshGuestTraffic(_ instance: Instance, attributeProcesses: Bool) {
        let name = instance.name
        Task { [weak self] in
            let response = await Task.detached(priority: .utility) {
                DaemonClient.send(.trafficSnapshot(instance: name,
                                                   attributeProcesses: attributeProcesses),
                                  timeout: 20)
            }.value
            guard let self else { return }
            guard let response else {
                self.guestTraffic[name] = .failed("MSL's background service didn't answer.")
                return
            }
            if response.hasPrefix("OK") {
                let body = String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard let data = Data(base64Encoded: body),
                      let connections = try? TrafficProtocol.parseSockets([UInt8](data)) else {
                    self.guestTraffic[name] = .failed("The guest sent a reply this version can't read.")
                    return
                }
                self.guestTraffic[name] = .loaded(connections)
            } else if response.contains(DaemonServerMarkers.trafficUnavailable) {
                self.guestTraffic[name] = .unavailable
            } else if response.contains("not running") {
                self.guestTraffic[name] = .notRunning
            } else {
                self.guestTraffic[name] = .failed(String(response.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - SSH

    enum SSHState {
        case unknown
        case working
        case ready(SSHSetup.Result)
        case failed(String)
    }

    @Published private(set) var ssh: [String: SSHState] = [:]

    /// On by default, because the whole point is that connecting needs no
    /// setup step. Surfaced in the SSH card itself, not buried in Tools:
    /// this installs a key in the guest and edits ~/.ssh/config on the Mac,
    /// and anything doing that on its own should say so where it happens.
    static let sshAutoSetupKey = "MSLSSHAutoSetup"
    var sshAutoSetupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.sshAutoSetupKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.sshAutoSetupKey); objectWillChange.send() }
    }

    /// Instance states as of the previous poll, for transition detection.
    private var previousStates: [String: InstanceState] = [:]
    private var sshInFlight: Set<String> = []

    func sshState(for instance: Instance) -> SSHState {
        if let known = ssh[instance.name] { return known }
        // Show what MSL already knows the instant the card appears, marked
        // unverified - a spinner over real details beats an empty card, and
        // an unverified label beats a confident stale address.
        if let cached = SSHSetup.cachedResult(instance: instance.name) { return .ready(cached) }
        return .unknown
    }

    /// Called from `refresh()` once the new instance list is in place.
    ///
    /// Cheap in the common case: for an instance MSL already knows, this
    /// costs one TCP connect (`verifyExisting`) and no guest round trip at
    /// all. The expensive path only runs for something genuinely new.
    private func autoConfigureSSHIfNeeded(_ parsed: [Instance]) {
        for instance in parsed {
            let name = instance.name
            let previous = previousStates[name]
            guard SSHAutoSetup.shouldConfigure(
                previous: previous,
                current: instance.state,
                enabled: sshAutoSetupEnabled,
                inFlight: sshInFlight.contains(name),
                hasRecord: SSHSetup.RecordStore.load(instance: name) != nil)
            else { continue }
            setUpSSH(instance, automatic: true)
        }
        previousStates = Dictionary(uniqueKeysWithValues: parsed.map { ($0.name, $0.state) })
    }

    /// Confirms a cached record still points somewhere real, without a guest
    /// round trip. Used when the card appears.
    func verifySSH(_ instance: Instance) {
        let name = instance.name
        guard !sshInFlight.contains(name),
              let record = SSHSetup.RecordStore.load(instance: name) else { return }
        Task { [weak self] in
            let confirmed = await Task.detached(priority: .utility) { () -> SSHSetup.Result? in
                // The quick answer first: an instance that has been up for a
                // while answers immediately and this costs one TCP connect.
                if let now = SSHSetup.verifyExisting(instance: name) { return now }

                // **Then keep watching, because one probe is a sample and
                // what is being sampled is a guest that may still be coming
                // up.** A guest resumed from hibernate rebuilds its network
                // card and has to take a DHCP lease again, which routinely
                // outlasts the setup path's own ten-second wait - so the
                // card was left saying "isn't answering on port 22", and
                // blaming the Sandbox's network gate, about a guest that
                // `nc` and `ssh` both reached perfectly well from the same
                // Mac moments later (2026-10-04, after a resume).
                //
                // Nothing re-checked, either: this runs once when the card
                // appears, so the stale error stayed on screen for as long
                // as that instance was selected.
                //
                // Every two seconds rather than three times a second: this
                // is a background watch, not a countdown anybody is staring
                // at, and a minute of it should cost thirty connects.
                guard SSHSetup.waitUntilReachable(host: record.host, within: 60, every: 2) else {
                    return nil
                }
                return SSHSetup.verifyExisting(instance: name)
            }.value
            guard let self, let confirmed else { return }
            self.ssh[name] = .ready(confirmed)
        }
    }

    func setUpSSH(_ instance: Instance, automatic: Bool = false) {
        let name = instance.name
        let distro = instance.distro
        guard !sshInFlight.contains(name) else { return }
        sshInFlight.insert(name)
        ssh[name] = .working
        Task { [weak self] in
            let outcome: SSHState = await Task.detached(priority: automatic ? .utility : .userInitiated) {
                // The cheap path first: if MSL already set this up and the
                // address still answers, there is nothing to do. Only an
                // instance that fails this costs a guest shell session.
                if automatic, let confirmed = SSHSetup.verifyExisting(
                    instance: name, expectedUser: LinuxUserSetup.defaultUser(forInstance: name) ?? "msl") {
                    return .ready(confirmed)
                }
                // Asked again at the last moment, because the poll that
                // triggered this can be seconds old. The guest session below
                // starts - and registers - whatever it names: an automatic
                // setup that reached the daemon just after `msl remove` brought
                // the removed instance back and booted it (2026-09-14). Status
                // never registers, and a removed instance reads as stopped.
                if automatic, DaemonClient.send(.status(instance: name), timeout: 10) != "OK running" {
                    return .failed("no longer running")
                }
                do {
                    // As the instance's own account, the way WSL would; the
                    // image's built-in `msl` account only until there is one.
                    let user = LinuxUserSetup.defaultUser(forInstance: name) ?? "msl"
                    return .ready(try SSHSetup.configure(instance: name, distro: distro, user: user))
                } catch {
                    return .failed("\(error)")
                }
            }.value
            guard let self else { return }
            self.sshInFlight.remove(name)
            // An automatic attempt that fails must stay quiet. The user did
            // not ask for it, the instance works fine without it, and a
            // banner every time an old image is started would be noise.
            if automatic, case .failed = outcome {
                self.ssh[name] = SSHSetup.cachedResult(instance: name).map { .ready($0) } ?? .unknown
                return
            }
            self.ssh[name] = outcome
        }
    }

    /// Opens Terminal already connected. The alias comes from the block MSL
    /// wrote into `~/.ssh/config`, so this is the same thing the user could
    /// type themselves - not a hidden path only the app can walk.
    func openSSHTerminal(_ instance: Instance) {
        guard case .ready(let result) = sshState(for: instance) else { return }
        // Quoted word by word: the app only allows plain instance names, but
        // `msl <name>` from the command line doesn't.
        let script = TerminalLaunch.appleScript(["ssh", result.alias])
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    func openTerminal(_ instance: Instance) {
        let script = TerminalLaunch.appleScript(tool: MSLPaths.tool("msl").path, instance: instance.name)
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    // MARK: - Applications

    func apps(for instance: Instance) -> [LinuxApp] { apps[instance.name] ?? [] }
    func isScanning(_ instance: Instance) -> Bool { scanning.contains(instance.name) }
    func isBusy(_ name: String) -> Bool { busy.contains(name) }

    /// `qualifiedName`, matching `descriptor(for:)`. Checking the plain
    /// name meant a Flatpak app installed as "Calculator (Flatpak).app" was
    /// then looked up as "Calculator": the tile never showed its checkmark,
    /// the menu kept offering "Add to Applications" for something already
    /// added, and "Remove" had nothing to remove.
    func isBundleInstalled(_ app: LinuxApp, in instance: Instance) -> Bool {
        installedBundles[instance.name]?.contains(LinuxAppBundle.fileSafeName(app.qualifiedName)) ?? false
    }

    /// Re-reads the instance's `.desktop` entries and icons. Needs the VM
    /// running, so it starts it - which is exactly the flow the user asked
    /// for ("click a distro, boot MSL, see all the apps").
    /// Downloads and installs `distro`'s image, plus the shared kernel and
    /// initramfs if this is the first distro on the machine.
    ///
    /// Previously the app could only tell the user to go and run `msl
    /// install <distro>` in a terminal, which is a strange thing for a
    /// graphical app to say about its own core setup. The work itself is
    /// `DistroInstaller.install` either way - this only moves it off the
    /// main thread and turns its progress lines into something on screen.
    func installDistro(_ distro: GuestDistro) {
        guard installing[distro] == nil else { return }
        installing[distro] = "Fetching manifest…"
        let cancellation = DistroInstaller.InstallCancellation()
        installCancels[distro] = cancellation

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try DistroInstaller.install(
                        distro: distro,
                        // The whole chain, same as `msl install`: Hugging
                        // Face first, SourceForge if it will not serve.
                        // No override, so nothing to refuse: `distro.source`
                        // governs pointing MSL at someone else's manifest,
                        // and the app never does. Installing at all is
                        // `distro.install`, refused inside `install`.
                        sources: DistroInstaller.defaultSources,
                        appSupportDir: MSLPaths.appSupport,
                        cancellation: cancellation
                    ) { message in
                        Task { @MainActor [weak self] in
                            self?.installing[distro] = message
                            // Each new stage ends the previous transfer, so
                            // the bar does not linger at 100% through
                            // verifying and unpacking.
                            self?.installTransfer[distro] = nil
                        }
                    } transfer: { update in
                        Task { @MainActor [weak self] in
                            self?.installTransfer[distro] = update
                        }
                    }
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value

            guard let self else { return }
            self.installing[distro] = nil
            self.installTransfer[distro] = nil
            let wasCancelled = cancellation.isCancelled
            self.installCancels[distro] = nil
            if wasCancelled {
                // Not an error: they asked for this. The half-downloaded file
                // is already gone - the installer deletes it on its way out.
                self.banner = Banner(
                    kind: .info, title: "Download stopped",
                    detail: "\(distro.displayName) wasn't installed, and the part that had downloaded has been deleted.")
            } else if let result {
                self.banner = Banner(
                    kind: .error, title: "Couldn't install \(distro.displayName)", detail: result)
            } else {
                self.banner = Banner(
                    kind: .success, title: "\(distro.displayName) installed",
                    detail: "Instances using it can start now.")
            }
            // Either way the on-disk picture changed - `isInstalled` is
            // derived from whether the image exists.
            await self.refresh()
            // A fresh download is exactly when the disk size should be
            // chosen. An instance created before the download already has a
            // guide waiting; otherwise start one for the instance in view,
            // or the first of this distro.
            if result == nil, self.firstRunGuide == nil {
                let target = self.selectedInstance.flatMap { $0.distro == distro ? $0 : nil }
                    ?? self.instances(of: distro).first
                if let target { self.beginFirstRunGuide(for: target.name) }
            }
        }
    }

    func isInstalling(_ distro: GuestDistro) -> Bool { installing[distro] != nil }

    /// Stops a download in progress and deletes what it had fetched.
    ///
    /// Safe at any point: before the transfer starts, mid-transfer, or after
    /// it has already finished (in which case nothing is waiting to be
    /// killed and the install completes as normal).
    func cancelInstall(_ distro: GuestDistro) {
        installCancels[distro]?.cancel()
        installing[distro] = "Stopping…"
        installTransfer[distro] = nil
    }

    // MARK: - Custom images

    /// Every folder in Custom Images, validated. Rescanned when New Instance
    /// opens and on demand - the folder is edited in Finder, so nothing
    /// tells MSL it changed.
    @Published private(set) var customImages: [CustomImage] = []

    func refreshCustomImages() {
        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) { CustomImage.scan() }.value
            self?.customImages = scanned
        }
    }

    /// Opens Custom Images in Finder, creating it - with its README and the
    /// guest kit - the first time.
    func openCustomImagesFolder(selecting image: CustomImage? = nil) {
        do {
            let folder = try CustomImage.prepareFolder()
            if let image {
                NSWorkspace.shared.activateFileViewerSelecting([image.folder])
            } else {
                NSWorkspace.shared.open(folder)
            }
        } catch {
            banner = Banner(kind: .error, title: "Couldn't open Custom Images", detail: "\(error)")
        }
    }

    /// Copies an installed distro into Custom Images as a new image - the
    /// quickest way to a custom image that is certain to work.
    func startCustomImage(id: String, name: String, from distro: GuestDistro, completion: @escaping (CustomImage?) -> Void) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CustomImage, Error> in
                do {
                    try CustomImage.prepareFolder()
                    return .success(try CustomImage.create(slug: id, from: distro, name: name))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let image):
                self.banner = Banner(kind: .success, title: "Created the \(image.name) image",
                                     detail: "A copy of \(distro.displayName) in Custom Images/\(image.slug). Instances made from it change only it.")
                self.customImages = await Task.detached { CustomImage.scan() }.value
                completion(image)
            case .failure(let error):
                self.banner = Banner(kind: .error, title: "Couldn't create the image", detail: "\(error)")
                completion(nil)
            }
        }
    }

    func scanApps(_ instance: Instance) {
        guard allows("apps.discovery", in: instance) else { return }
        guard !scanning.contains(instance.name) else { return }
        guard !atCap || instance.isLive else {
            banner = Banner(
                kind: .error, title: "\(runningCap) instances are already running",
                detail: "Scanning \(instance.name) has to start it, and every slot is taken. Suspend or shut one down first.")
            return
        }
        if deferForUserSetup(instance, then: { [weak self] in self?.scanApps(instance) }) { return }
        scanning.insert(instance.name)
        scanStatus[instance.name] = "Starting \(instance.name)…"
        let name = instance.name
        let distro = instance.distro

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[LinuxApp], Error> in
                do {
                    let found = try LinuxAppCatalog.scan(instance: name, distro: distro) { message in
                        Task { @MainActor [weak self] in self?.scanStatus[name] = message }
                    }
                    return .success(found)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.scanning.remove(name)
            self.scanStatus[name] = nil
            switch result {
            case .success(let found):
                self.apps[name] = found
                self.cacheIcons(found, instance: name)
                self.installedBundles[name] = LinuxAppBundle.installedApps(instance: name)
                if found.isEmpty {
                    self.banner = Banner(
                        kind: .info, title: "No GUI applications found in \(name)",
                        detail: "Install some in the instance first - anything with a .desktop file will show up here.")
                }
            case .failure(let error):
                self.banner = Banner(kind: .error, title: "Couldn't read \(name)'s applications", detail: "\(error)")
            }
        }
    }

    func launch(_ app: LinuxApp, in instance: Instance) {
        if deferForUserSetup(instance, then: { [weak self] in self?.launch(app, in: instance) }) { return }
        // Launched through the generated bundle when there is one, so the
        // path the user gets from Finder and the path they get from here
        // are the same path - if one works, both do.
        let descriptor = descriptor(for: app, in: instance)
        if LinuxAppBundle.exists(descriptor) {
            // A new instance every time, rather than activating the one
            // already running. Clicking an app twice should open a second
            // window, the way it would on a Linux desktop; an app that
            // allows only one instance will still say so itself and raise
            // the window it has. MSL does not decide that for it.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: LinuxAppBundle.bundleURL(for: descriptor),
                configuration: configuration)
            return
        }
        let name = instance.name
        let distro = instance.distro
        let command = app.command
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                let (code, output) = try LinuxAppLauncher.runCapturingOutput(instance: name, distro: distro, command: command)
                if let message = LinuxAppLauncher.failureMessage(
                    appName: app.name, instance: name, command: command,
                    exitCode: code, output: output, runTime: Date().timeIntervalSince(started)) {
                    await MainActor.run { [weak self] in
                        self?.banner = AppModel.Banner(kind: .error, title: "Couldn't start \(app.name)", detail: message)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.banner = AppModel.Banner(kind: .error, title: "Couldn't start \(app.name)", detail: "\(error)")
                }
            }
        }
    }

    func addToApplications(_ app: LinuxApp, in instance: Instance) {
        guard allows("apps.launchpad", in: instance) else { return }
        withBestIcon(app, in: instance) { [weak self] resolved in
            guard let self else { return }
            do {
                let url = try LinuxAppBundle.generate(self.descriptor(for: resolved, in: instance))
                self.installedBundles[instance.name] = LinuxAppBundle.installedApps(instance: instance.name)
                self.banner = Banner(
                    kind: .success, title: "\(resolved.name) added to your Applications",
                    detail: "It's in \(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) and searchable from Spotlight.")
            } catch {
                self.banner = Banner(kind: .error, title: "Couldn't add \(resolved.name)", detail: "\(error)")
            }
        }
    }

    /// Whether MSL is currently fetching better art for `app`.
    func isPreparingIcon(_ app: LinuxApp, in instance: Instance) -> Bool {
        preparingIcons.contains(iconKey(app, instance: instance))
    }

    /// Runs `finish` with the best icon this app can have, fetching a
    /// higher-resolution one from the guest first when the scan only got a
    /// small bitmap.
    ///
    /// A scan pulls a modest icon for every app at once, which is right for
    /// filling a grid and wrong for a 1024pt `.icns`. Turning an app into a
    /// real macOS bundle is the moment that difference becomes visible, so
    /// that is where the better file is fetched - and it is fetched only
    /// when it would actually be an improvement, so an app whose icon is
    /// already a vector never starts a VM just to be pinned.
    private func withBestIcon(
        _ app: LinuxApp, in instance: Instance, then finish: @escaping (LinuxApp) -> Void
    ) {
        guard let name = app.iconName, !name.isEmpty, !app.iconIsHighResolution else {
            finish(app)
            return
        }
        // Booting to fetch an icon is subject to the same concurrency cap as
        // every other start - but unlike a scan, the upgrade is not what the
        // user asked for. They asked to pin or add an app. So the cap
        // downgrades the icon rather than cancelling the action: the bundle
        // is still made, using the art the scan already fetched.
        guard !atCap || instance.isLive else {
            banner = Banner(
                kind: .info, title: "Using \(app.name)'s existing icon",
                detail: "A sharper one would mean starting \(instance.name), and all \(runningCap) slots are in use. Add it again later for the full-resolution icon.")
            finish(app)
            return
        }

        let key = iconKey(app, instance: instance)
        guard !preparingIcons.contains(key) else { return }
        preparingIcons.insert(key)

        let instanceName = instance.name
        let distro = instance.distro
        Task { [weak self] in
            let upgraded = await Task.detached(priority: .userInitiated) {
                LinuxAppCatalog.upgradeIcon(for: app, instance: instanceName, distro: distro)
            }.value

            guard let self else { return }
            self.preparingIcons.remove(key)
            // Drop the cached image so the grid picks up the new art.
            self.iconCache[key] = nil
            if let index = self.apps[instanceName]?.firstIndex(where: { $0.desktopPath == app.desktopPath }) {
                self.apps[instanceName]?[index] = upgraded
            }
            finish(upgraded)
        }
    }

    func removeFromApplications(_ app: LinuxApp, in instance: Instance) {
        let descriptor = descriptor(for: app, in: instance)
        let url = LinuxAppBundle.bundleURL(for: descriptor)
        DockPinner.unpin(url)
        do {
            try LinuxAppBundle.remove(descriptor)
            installedBundles[instance.name] = LinuxAppBundle.installedApps(instance: instance.name)
        } catch {
            banner = Banner(kind: .error, title: "Couldn't remove \(app.name)", detail: "\(error)")
        }
    }

    func isPinned(_ app: LinuxApp, in instance: Instance) -> Bool {
        pinnedPaths.contains(bundlePath(for: app, in: instance))
    }

    /// The icon for `app`, from the cache. Populated at scan time and on
    /// load, so drawing a grid of tiles touches neither the disk nor
    /// Core Graphics.
    func icon(for app: LinuxApp, in instance: Instance) -> NSImage {
        // MSL Files' tile wears the real app's icon, not anything from the
        // guest - it is a Mac app, and the guest has only the small SVG the
        // kit installs for the Linux menu.
        if app.isMSLFiles {
            if let cached = iconCache[LinuxApp.mslFilesPath] { return cached }
            let image = MSLAsset.url("MSL_Files_Logo", extension: "png")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                ?? NSImage()
            iconCache[LinuxApp.mslFilesPath] = image
            return image
        }
        if let cached = iconCache[iconKey(app, instance: instance)] { return cached }
        let image = LinuxAppCatalog.icon(for: app, instance: instance.name)
        iconCache[iconKey(app, instance: instance)] = image
        return image
    }

    private func iconKey(_ app: LinuxApp, instance: Instance) -> String {
        instance.name + "\u{0}" + app.desktopPath
    }

    private func cacheIcons(_ apps: [LinuxApp], instance: String) {
        for app in apps {
            let key = instance + "\u{0}" + app.desktopPath
            if iconCache[key] == nil {
                iconCache[key] = LinuxAppCatalog.icon(for: app, instance: instance)
            }
        }
    }

    private func bundlePath(for app: LinuxApp, in instance: Instance) -> String {
        LinuxAppBundle.bundleURL(for: descriptor(for: app, in: instance)).standardizedFileURL.path
    }

    private func refreshPinnedPaths() {
        pinnedPaths = DockPinner.pinnedPaths()
    }

    /// Pinning needs a bundle to point at, so this generates one first if
    /// the app hasn't been added yet - "pin to Dock" implying "add to
    /// Applications" is far less surprising than refusing.
    func togglePin(_ app: LinuxApp, in instance: Instance) {
        // Unpinning is always allowed - removing a tile takes nothing away
        // from the policy, and trapping one in the Dock helps nobody.
        guard isPinned(app, in: instance) || allows("apps.dock", in: instance) else { return }
        // Unpinning must never boot anything, so the icon upgrade is only
        // worth doing on the path that will actually generate a bundle.
        if LinuxAppBundle.exists(descriptor(for: app, in: instance)) {
            applyPin(app, in: instance)
        } else {
            withBestIcon(app, in: instance) { [weak self] resolved in
                self?.applyPin(resolved, in: instance)
            }
        }
    }

    private func applyPin(_ app: LinuxApp, in instance: Instance) {
        let descriptor = descriptor(for: app, in: instance)
        if !LinuxAppBundle.exists(descriptor) {
            do {
                _ = try LinuxAppBundle.generate(descriptor)
                installedBundles[instance.name] = LinuxAppBundle.installedApps(instance: instance.name)
            } catch {
                banner = Banner(kind: .error, title: "Couldn't add \(app.name)", detail: "\(error)")
                return
            }
        }
        let url = LinuxAppBundle.bundleURL(for: descriptor)
        if pinnedPaths.contains(url.standardizedFileURL.path) {
            DockPinner.unpin(url)
        } else {
            DockPinner.pin(url)
        }
        // Read back from the Dock rather than assuming the write landed -
        // and force a fresh read, because CFPreferences caches per process
        // and would otherwise keep reporting the pre-change value, leaving
        // the button's label wrong until the app was relaunched.
        DockPinner.invalidateCache()
        refreshPinnedPaths()
    }

    func revealInFinder(_ instance: Instance) {
        let directory = MSLPaths.generatedAppsDirectory(instance: instance.name)
        MSLPaths.ensureDirectory(directory)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    private func descriptor(for app: LinuxApp, in instance: Instance) -> LinuxAppBundle.Descriptor {
        // `qualifiedName`, not `name`: the bundle path is derived from this,
        // and once Flatpak and Snap are scanned the system GIMP and the
        // Flatpak GIMP both want `GIMP.app`. Adding the second would
        // overwrite the first, and `installedApps` would report one name
        // for two tiles - so both would show as installed and removing
        // either would remove the other. System apps are unaffected:
        // `qualifiedName` is just `name` for them.
        LinuxAppBundle.Descriptor(
            instance: instance.name, distro: instance.distro, displayName: app.qualifiedName,
            menuName: app.name,
            command: app.command, icon: LinuxAppCatalog.icon(for: app, instance: instance.name))
    }

    // MARK: - Plumbing

    /// Runs a daemon call off the main actor, marks the instance busy while
    /// it's in flight, and turns a non-`OK` reply into a banner. Every
    /// daemon response already carries a human-readable reason - including
    /// the concurrency cap's - so it is passed through rather than
    /// replaced with something vaguer.
    /// `onSuccess` runs after the refresh, so anything it selects or shows is
    /// already in `instances` - a just-created instance can't be selected
    /// in the sidebar before the sidebar has it.
    private func perform(
        _ name: String, title: String, success: String? = nil,
        onSuccess: (@MainActor () -> Void)? = nil,
        _ work: @escaping @Sendable () -> String?
    ) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        Task { [weak self] in
            let response = await Task.detached(priority: .userInitiated, operation: work).value
            guard let self else { return }
            self.busy.remove(name)
            let succeeded = response?.hasPrefix("OK") == true
            if succeeded {
                if let success { self.banner = Banner(kind: .success, title: success, detail: nil) }
            } else {
                let detail = response.map { $0.hasPrefix("ERR") ? String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) : $0 }
                self.banner = Banner(kind: .error, title: title, detail: detail ?? "MSL's background service isn't running.")
            }
            await self.refresh()
            if succeeded { onSuccess?() }
        }
    }
}
