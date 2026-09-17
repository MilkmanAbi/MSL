import MSLCore
import SwiftUI

/// The detail pane: a header that is always the same shape regardless of
/// state, and three tabs under it.
struct InstanceView: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Applications"
        case terminal = "Terminal"
        case overview = "Overview"
        case tools = "Tools"
        case sandbox = "Sandbox"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .apps

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, Design.Spacing.small + 2)

            Divider()

            // The terminal is deliberately outside the ScrollView and gets
            // no padding: it manages its own scrollback and has to fill the
            // pane exactly, or its character grid is sized to a box that
            // keeps changing.
            switch tab {
            case .terminal:
                TerminalTab(instance: instance)
            case .apps, .overview, .tools, .sandbox:
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            switch tab {
                            case .apps: AppsTab(instance: instance)
                            case .overview: OverviewTab(instance: instance)
                            case .tools: ToolsTab(instance: instance)
                            case .sandbox: SandboxTab(instance: instance)
                            case .terminal: EmptyView()
                            }
                        }
                        .padding(Design.Spacing.large)
                    }
                    .onChange(of: scrollToStorage) { _, requested in
                        guard requested else { return }
                        scrollToStorage = false
                        // After the tab switch has laid the Overview out -
                        // scrolling to a card that doesn't exist yet does nothing.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeInOut(duration: 0.45)) {
                                proxy.scrollTo(StorageCard.anchorID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { followFirstRunGuide() }
        .onChange(of: model.firstRunGuide) { _, _ in followFirstRunGuide() }
        .onChange(of: instance.isInstalled) { _, _ in followFirstRunGuide() }
    }

    @State private var scrollToStorage = false

    /// Moves to whatever the first-run guide is on for this instance - see
    /// `AppModel.FirstRunGuide`.
    private func followFirstRunGuide() {
        guard let guide = model.firstRunGuide, guide.instance == instance.name else { return }
        switch guide.step {
        case .storage:
            // Nothing to size until the distro's disk exists; the guide
            // waits and this runs again when `isInstalled` flips.
            guard instance.isInstalled else { return }
            tab = .overview
            scrollToStorage = true
        case .account:
            // The Terminal tab runs `msl`, which asks for the Linux account
            // itself when the distro has none. Its job is done once there.
            tab = .terminal
            model.endFirstRunGuide()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Spacing.medium) {
            DistroBadge(distro: instance.distro, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(instance.name)
                    .font(.title2).bold()
                HStack(spacing: Design.Spacing.small) {
                    Text(instance.distro.displayName)
                    Text("·").foregroundStyle(.tertiary)
                    StateIndicator(state: instance.state)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Spacing.medium)
            actions
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.vertical, Design.Spacing.medium + 2)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Design.Spacing.small) {
            if model.isBusy(instance.name) {
                ProgressView().controlSize(.small)
            }
            Button {
                tab = .terminal
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Open a Linux shell in \(instance.name)")

            if instance.state == .running || instance.state == .paused {
                Menu {
                    InstanceMenu(instance: instance)
                } label: {
                    Label(instance.state == .paused ? "Resume" : "Suspend",
                          systemImage: instance.state == .paused ? "play.fill" : "pause.fill")
                } primaryAction: {
                    if instance.state == .paused {
                        model.start(instance)
                    } else {
                        model.suspend(instance)
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.isBusy(instance.name))
            } else if !instance.isInstalled, instance.distro.isCustom {
                // Nothing to download for a custom image - its files are
                // missing from its folder, so go there.
                Button {
                    model.openCustomImagesFolder()
                } label: {
                    Label("Show Image Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .help("This custom image's files are missing from Custom Images")
            } else if !instance.isInstalled {
                // An instance can be registered without its image ever
                // having been downloaded, and offering "Start" for one of
                // those just produces a confusing failure. Offer the thing
                // that would actually help instead.
                Button {
                    model.installDistro(instance.distro)
                } label: {
                    if model.isInstalling(instance.distro) {
                        Label("Downloading\u{2026}", systemImage: "arrow.down.circle")
                    } else {
                        Label("Install \(instance.distro.displayName)", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstalling(instance.distro))
                .help(model.installing[instance.distro]
                      ?? "Downloads \(instance.distro.displayName) - shared by every instance using it")
            } else {
                Button {
                    model.start(instance)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.atCap || model.isBusy(instance.name))
                .help(model.atCap
                      ? "\(model.runningCap) instances are already running"
                      : "Start this instance")
            }
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            Card(title: "Instance") {
                DetailRow(label: "Name", value: instance.name)
                Divider()
                DetailRow(label: "Distribution", value: instance.distro.displayName)
                Divider()
                DetailRow(label: "State", value: instance.state.label)

            }

            SSHCard(instance: instance)

            ResourcesCard(instance: instance)

            StorageCard(instance: instance)
                .id(StorageCard.anchorID)

            Card(title: "Shared with macOS",
                 footnote: "Your home folder is mounted inside the instance, so the same files are reachable from both sides.") {
                DetailRow(label: "Home folder", value: "/mnt/mac", monospaced: true)
                Divider()
                DetailRow(label: "Host path", value: NSHomeDirectory(), monospaced: true)
            }

            Card(title: "Concurrency",
                 footnote: "Every running or suspended instance keeps its guest memory on your Mac, so MSL limits how many run at once.") {
                DetailRow(label: "Running now", value: "\(model.runningCount) of \(model.runningCap)")
            }
        }
    }

}

// MARK: - Tools

private struct ToolsTab: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var launchAgentInstalled = DaemonClient.launchAgentInstalled()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            Card(title: "Background service",
                 footnote: "mslhd hosts every instance. Without it running, nothing can start - including apps launched from your Applications folder or Dock.") {
                Toggle("Start MSL's service automatically", isOn: Binding(
                    get: { launchAgentInstalled },
                    set: { wanted in
                        // The opt-out is persisted, not just applied:
                        // `AppModel.start()` reinstalls the login item on
                        // every launch, so without remembering the choice
                        // this switch would quietly flip itself back on.
                        AppModel.launchAgentOptedOut = !wanted
                        if wanted {
                            DaemonClient.installLaunchAgent()
                        } else {
                            DaemonClient.removeLaunchAgent()
                        }
                        launchAgentInstalled = DaemonClient.launchAgentInstalled()
                    }))
                Divider()
                DetailRow(label: "Status", value: model.daemonReachable ? "Running" : "Not running")
                Divider()
                DetailRow(label: "Log", value: "~/Library/Logs/MSL/mslhd.log", monospaced: true)
            }

            Card(title: "Generated applications",
                 footnote: "Apps you add from the Applications tab are ordinary macOS apps stored here. Deleting one in Finder is the same as removing it.") {
                DetailRow(
                    label: "Location",
                    value: MSLPaths.generatedAppsDirectory(instance: instance.name).path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    monospaced: true)
                Divider()
                HStack {
                    Button("Show in Finder") { model.revealInFinder(instance) }
                    Button("Open Logs") {
                        MSLPaths.ensureDirectory(MSLPaths.logsDirectory)
                        NSWorkspace.shared.open(MSLPaths.logsDirectory)
                    }
                }
            }

            SnapshotsCard(instance: instance)

            MaintenanceCard(instance: instance)

            Card(title: "Instance") {
                HStack {
                    Button("Suspend") { model.suspend(instance) }
                        .disabled(instance.state != .running)
                    Button("Hibernate") { model.hibernate(instance) }
                        .disabled(!instance.isLive)
                    Button("Shut Down") { model.shutDown(instance) }
                        .disabled(!instance.isLive)
                    Spacer()
                    Button("Remove…", role: .destructive) { model.requestRemove(instance) }
                }
            }
        }
    }
}


/// Saved machine states: take one before something risky, go back to it if
/// that turns out badly.
///
/// `snapshotSave`/`snapshotRestore`/`snapshotList` have been in the daemon
/// for a long time with no way to reach them except by typing `msl snapshot`
/// - this is the same feature, made visible.
private struct SnapshotsCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var newName = ""

    private var snapshots: [String] { model.snapshots(for: instance) }

    var body: some View {
        Card(title: "Snapshots",
             footnote: "A snapshot saves the whole machine - memory and disk - as it is right now. Restoring one discards everything since.") {
            if snapshots.isEmpty {
                Text("No snapshots yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(snapshots.enumerated()), id: \.element) { index, name in
                    if index > 0 { Divider() }
                    HStack {
                        Label(name, systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Button("Restore") { model.restoreSnapshot(named: name, of: instance) }
                            .disabled(model.isBusy(instance.name))
                    }
                    .font(.callout)
                }
                Divider()
            }

            HStack {
                TextField("New snapshot name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(!canSave)
            }
            // Saving needs a machine to save: a stopped instance has no
            // memory state to capture.
            if !instance.isLive {
                Text("Start \(instance.name) to take a snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshSnapshots(instance) }
    }

    private var canSave: Bool {
        instance.isLive
            && !model.isBusy(instance.name)
            && InstanceRegistry.isValidName(newName)
            && !snapshots.contains(newName)
    }

    private func save() {
        guard canSave else { return }
        model.saveSnapshot(named: newName, of: instance)
        newName = ""
    }
}

// MARK: - SSH

/// Connect-over-SSH, reduced to one button and one line you can copy.
///
/// The honesty requirement here is `reachable`. MSL sets the guest up and
/// then *probes* the address before saying it works, because a Connect
/// button that hands over an unreachable address is worse than no button -
/// it turns a clear failure into a terminal that hangs.
private struct SSHCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance
    @State private var copied: String?

    var body: some View {
        Card(title: "Connect over SSH", footnote: footnote) {
            switch model.sshState(for: instance) {
            case .unknown:      notSetUp
            case .working:      working
            case .ready(let r): ready(r)
            case .failed(let m): failure(m)
            }
            Divider()
            Toggle("Set this up automatically when an instance starts", isOn: Binding(
                get: { model.sshAutoSetupEnabled },
                set: { model.sshAutoSetupEnabled = $0 }))
                .font(.caption)
                .help("Installs MSL's key in the guest, starts its SSH server, and adds a "
                      + "shortcut to ~/.ssh/config. Nothing else on your Mac is touched.")
        }
        .task(id: instance.name) { model.verifySSH(instance) }
    }

    private var notSetUp: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.state == .running ? "Setting up shortly…" : "Not set up yet")
                Text("MSL makes its own key, installs it, starts the SSH server and adds a "
                     + "shortcut - so connecting is one command with nothing to configure.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Spacing.small)
            Button("Set up now") { model.setUpSSH(instance) }
                .disabled(instance.state != .running)
        }
    }

    private var working: some View {
        HStack(spacing: Design.Spacing.medium) {
            ProgressView().controlSize(.small)
            Text("Setting up…").foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func ready(_ result: SSHSetup.Result) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            // The headline: the thing to type, and whether it works.
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: statusSymbol(result))
                    .foregroundStyle(statusTint(result))
                Text(result.command)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: Design.Spacing.small)
                Button(copied == "command" ? "Copied" : "Copy") { copy(result.command, as: "command") }
                Button("Open Terminal") { model.openSSHTerminal(instance) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!result.reachable)
            }

            Text(statusLine(result))
                .font(.caption)
                // Same three-way split as the icon. "Last known details" is
                // information, not a warning - colouring it orange makes a
                // stopped instance look broken.
                .foregroundStyle(statusTint(result) == .orange ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Everything an admin needs, without going hunting for it.
            DetailRow(label: "Address", value: "\(result.user)@\(result.host)", monospaced: true)
            Divider()
            DetailRow(label: "Key", value: SSHSetup.privateKeyPath, monospaced: true)
            if let fingerprint = result.fingerprint {
                Divider()
                DetailRow(label: "Host key", value: fingerprint, monospaced: true)
            }

            HStack(spacing: Design.Spacing.medium) {
                Button(copied == "all" ? "Copied" : "Copy all details") {
                    copy(result.shareableSummary, as: "all")
                }
                .buttonStyle(.link).font(.caption)
                Button("Set up again") { model.setUpSSH(instance) }
                    .buttonStyle(.link).font(.caption)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.setUpSSH(instance) }
        }
    }

    // MARK: - Status, stated honestly

    private func statusSymbol(_ result: SSHSetup.Result) -> String {
        if !result.verifiedThisSession { return "clock.arrow.circlepath" }
        return result.reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusTint(_ result: SSHSetup.Result) -> Color {
        if !result.verifiedThisSession { return .secondary }
        return result.reachable ? .green : .orange
    }

    /// Three genuinely different states, and conflating them is how this
    /// becomes a panel that lies. A cached address is *last known*, not
    /// current - the guest's DHCP lease can move while it is switched off.
    private func statusLine(_ result: SSHSetup.Result) -> String {
        if !result.verifiedThisSession {
            return instance.state == .running
                ? "Last known details - checking they still work…"
                : "Last known details, from when \(instance.name) was last running."
        }
        if result.reachable {
            return "Ready. The same shortcut works anywhere ssh does - a terminal, scp, "
                 + "or VS Code's Remote-SSH."
        }
        return "Set up, but \(result.host) isn't answering on port 22. If the Sandbox tab's "
             + "Network gate is closed, that is why: it detaches the network card, and vsock "
             + "is unaffected - which is why `msl \(instance.name)` still works."
    }

    private func copy(_ text: String, as token: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = token
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if copied == token { copied = nil } }
    }

    private var footnote: String {
        instance.state == .running
            ? "The shortcut survives a reboot - MSL rechecks the address and rewrites the ~/.ssh/config entry in place."
            : "Start the instance and MSL sets this up on its own."
    }
}
