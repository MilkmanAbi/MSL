import AppKit
import MSLCore
import SwiftUI

/// In the sidebar, under New Instance: opens the Permissions & Startup window.
struct PermissionsAndStartupButton: View {
    @Environment(\.openWindow) private var openWindow
    /// Only for the icon - the window keeps its own model.
    @StateObject private var permissions = PermissionsModel()

    var body: some View {
        Button {
            openWindow(id: "permissions")
        } label: {
            Label("Permissions & Startup",
                  systemImage: permissions.needsAttention ? "exclamationmark.shield" : "checkmark.shield")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, Design.Spacing.small + 2)
        .task { permissions.refresh() }
    }
}

/// In the sidebar: opens MSL Files, the Mac-side browser for every instance's
/// Linux filesystem. It was only in the Window menu, where nobody found it.
struct OpenFilesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "files")
        } label: {
            Label("Open MSL Files", systemImage: "folder")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, Design.Spacing.small + 2)
        .help("Browse your instances' files from the Mac (msl files)")
    }
}

/// The window: every macOS permission MSL uses, asked for in one go, and what
/// MSL starts when you log in.
struct PermissionsAndStartupWindow: View {
    @StateObject private var permissions = PermissionsModel()

    var body: some View {
        ScrollView {
            PermissionsAndStartupPanel(permissions: permissions)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 440, minHeight: 480)
    }
}

// MARK: - Model

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var terminal: MacPermissions.State = .notChecked
    @Published private(set) var folders: [String: MacPermissions.State] = [:]
    @Published private(set) var networkVolumes: MacPermissions.State = .notChecked
    @Published private(set) var localNetwork: MacPermissions.State = .notChecked
    @Published private(set) var fullDiskAccess = MacPermissions.hasFullDiskAccess
    @Published private(set) var asking = false

    /// Only what can be read without raising a prompt: a denial anywhere, or
    /// Terminal never having been asked.
    var needsAttention: Bool {
        terminal == .denied || terminal == .notDetermined
            || folders.values.contains(.denied)
            || networkVolumes == .denied || localNetwork == .denied
    }

    func refresh() {
        fullDiskAccess = MacPermissions.hasFullDiskAccess
        Task {
            let status = await Task.detached(priority: .utility) {
                MacPermissions.automationStatus(bundleIdentifier: MacPermissions.terminalBundleIdentifier, ask: false)
            }.value
            // Terminal not running just means it can't be asked yet - not a
            // problem worth flagging.
            let state = MacPermissions.automationState(osStatus: status)
            terminal = state == .unavailable("Terminal isn't running") ? .notChecked : state
        }
    }

    /// Raises every prompt MSL needs, one after another, so they're answered
    /// together instead of ambushing the user feature by feature.
    func askForEverything(mounts: [String], sshHosts: [String]) {
        guard !asking else { return }
        asking = true
        Task {
            await askTerminal()
            for folder in MacPermissions.protectedFolders {
                guard let url = FileManager.default.urls(for: folder.directory, in: .userDomainMask).first else { continue }
                folders[folder.name] = await Task.detached(priority: .userInitiated) {
                    MacPermissions.requestRead(path: url.path)
                }.value
            }
            if let mount = mounts.first {
                networkVolumes = await Task.detached(priority: .userInitiated) {
                    MacPermissions.requestRead(path: mount)
                }.value
            } else {
                networkVolumes = .unavailable("Start an instance to ask")
            }
            if let host = sshHosts.first {
                let reached = await Task.detached(priority: .userInitiated) {
                    SSHSetup.canReach(host: host)
                }.value
                localNetwork = reached ? .granted : .unavailable("Couldn't reach \(host) - denied, or SSH isn't running")
            } else {
                localNetwork = .unavailable("Set up SSH on an instance to ask")
            }
            fullDiskAccess = MacPermissions.hasFullDiskAccess
            asking = false
        }
    }

    private func askTerminal() async {
        // The prompt can only be raised while Terminal runs. Launched hidden
        // and in the background, so asking doesn't throw a window at the user.
        if NSRunningApplication.runningApplications(withBundleIdentifier: MacPermissions.terminalBundleIdentifier).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacPermissions.terminalBundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        let status = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var result = MacPermissions.automationStatus(bundleIdentifier: MacPermissions.terminalBundleIdentifier, ask: true)
            // Terminal can take a moment to register after launching.
            var tries = 0
            while result == -600, tries < 20 {
                usleep(250_000)
                result = MacPermissions.automationStatus(bundleIdentifier: MacPermissions.terminalBundleIdentifier, ask: true)
                tries += 1
            }
            return result
        }.value
        terminal = MacPermissions.automationState(osStatus: status)
    }

    func open(_ pane: MacPermissions.Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    func revealDaemon() {
        NSWorkspace.shared.activateFileViewerSelecting([MSLPaths.tool("mslhd")])
    }
}

// MARK: - Panel

struct PermissionsAndStartupPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var permissions: PermissionsModel

    @State private var daemonAtLogin = DaemonClient.launchAgentInstalled()
    @State private var appAtLogin = LoginItem.app.isEnabled
    @State private var terminalAtLogin = LoginItem.terminal.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            permissionsSection
            Divider()
            startupSection
            Divider()
            CommandLineSection()
            Divider()
            UninstallSection()
        }
        .padding(Design.Spacing.large)
        .onAppear { permissions.refresh() }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("Permissions").font(.headline)
                Spacer()
                Button {
                    permissions.askForEverything(mounts: liveMounts, sshHosts: sshHosts)
                } label: {
                    if permissions.asking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking…") }
                    } else {
                        Text("Allow All…")
                    }
                }
                .disabled(permissions.asking)
            }
            Text("macOS asks about each of these once. Allow All raises every question now, so they don't interrupt you later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row("Control Terminal", detail: "Open in Terminal", state: permissions.terminal, pane: .automation)
            ForEach(MacPermissions.protectedFolders, id: \.name) { folder in
                row(folder.name, detail: "Shown in MSL Files",
                    state: permissions.folders[folder.name] ?? .notChecked, pane: .filesAndFolders)
            }
            row("Network volumes", detail: "Your instances in MSL Files", state: permissions.networkVolumes, pane: .filesAndFolders)
            row("Local network", detail: "SSH to your instances", state: permissions.localNetwork, pane: .localNetwork)

            Divider().padding(.vertical, 2)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access (optional)")
                    Text("Covers every folder at once, for MSL and for its background service, mslhd - which is what Linux reaches your Mac's files through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                stateBadge(permissions.fullDiskAccess ? .granted : .notChecked)
            }
            HStack {
                Button("Open Settings") { permissions.open(.fullDiskAccess) }
                Button("Show mslhd in Finder") { permissions.revealDaemon() }
            }
            .controlSize(.small)
        }
    }

    private var liveMounts: [String] {
        model.instances.compactMap { $0.sandboxMountPath }
    }

    private var sshHosts: [String] {
        model.instances.compactMap { SSHSetup.RecordStore.load(instance: $0.name)?.host }
    }

    private func row(_ title: String, detail: String, state: MacPermissions.State, pane: MacPermissions.Pane) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stateBadge(state)
            if state == .denied {
                Button("Settings") { permissions.open(pane) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: MacPermissions.State) -> some View {
        switch state {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .labelStyle(.titleAndIcon).font(.caption)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                .labelStyle(.titleAndIcon).font(.caption)
        case .notDetermined:
            Label("Not asked", systemImage: "questionmark.circle").foregroundStyle(.orange)
                .labelStyle(.titleAndIcon).font(.caption)
        case .notChecked:
            Text("—").foregroundStyle(.secondary).font(.caption)
        case .unavailable(let reason):
            Image(systemName: "minus.circle").foregroundStyle(.secondary).help(reason)
        }
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("When you log in").font(.headline)
            Toggle("Start MSL's background service", isOn: Binding(
                get: { daemonAtLogin },
                set: { wanted in
                    // Same as the Tools tab's switch: the choice is remembered,
                    // because `AppModel.start()` reinstalls the agent otherwise.
                    AppModel.launchAgentOptedOut = !wanted
                    if wanted { DaemonClient.installLaunchAgent() } else { DaemonClient.removeLaunchAgent() }
                    daemonAtLogin = DaemonClient.launchAgentInstalled()
                }))
            Text("Every instance runs inside it. Turning it off stops it now, and your instances with it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open MSL", isOn: Binding(
                get: { appAtLogin },
                set: { wanted in
                    LoginItem.app.setEnabled(wanted)
                    appAtLogin = LoginItem.app.isEnabled
                }))
            Toggle("Open an MSL terminal", isOn: Binding(
                get: { terminalAtLogin },
                set: { wanted in
                    LoginItem.terminal.setEnabled(wanted)
                    terminalAtLogin = LoginItem.terminal.isEnabled
                }))
        }
    }
}
