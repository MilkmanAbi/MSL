import MSLCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            Group {
                if let instance = model.selectedInstance {
                    InstanceView(instance: instance)
                        // Rebuild the detail pane when the selection
                        // changes rather than animating one instance's
                        // state into another's - the tab selection and
                        // scroll position belong to the instance.
                        .id(instance.name)
                } else {
                    EmptyDetail()
                }
            }
            .frame(minWidth: 560)
            // On the detail pane rather than beside New Instance's sheet:
            // two `.sheet` modifiers on one view is a SwiftUI coin toss.
            .sheet(item: $model.userSetup) { LinuxUserSetupSheet(request: $0) }
        }
        .overlay(alignment: .top) { BannerView() }
        .sheet(isPresented: $model.showingNewInstance) { NewInstanceSheet() }    }
}

private struct EmptyDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.daemonReachable {
            ContentUnavailableView {
                Label("No instance selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Create a Linux instance to get started.")
            } actions: {
                Button("New Instance…") { model.showingNewInstance = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("MSL's background service isn't running", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("mslhd hosts every instance. MSL installs it as a login item and starts it automatically - if this persists, check ~/Library/Logs/MSL/mslhd.log.")
            } actions: {
                Button("Start it") {
                    Task.detached { try? DaemonClient.ensureRunning() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    /// Owned here, not inside `ContributorsStrip`, because the strip draws
    /// nothing until the fetch succeeds - and a `.task` attached to a view
    /// that renders no content never runs, so the fetch would never start
    /// and the strip could never appear. The sidebar is always on screen.
    @StateObject private var contributors = ContributorsLoader()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section {
                    ForEach(model.instances) { instance in
                        InstanceRow(instance: instance)
                            .tag(instance.name)
                            .contextMenu { InstanceMenu(instance: instance) }
                    }
                } header: {
                    HStack {
                        Text("Instances")
                        Spacer()
                        CapacityPill()
                    }
                }
            }
            .listStyle(.sidebar)
            // On the list, not beside the instance sheet below: two `.sheet`s
            // on one view is a SwiftUI coin toss.
            .sheet(item: $model.pendingDistroRemoval) { RemoveDistroSheet(distro: $0.distro) }

            Divider()
            Button {
                model.showingNewInstance = true
            } label: {
                Label("New Instance", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Design.Spacing.medium)
            .padding(.vertical, Design.Spacing.small + 2)

            Divider()
            OpenFilesButton()
            PermissionsAndStartupButton()
            ExperimentalFeaturesButton()

            ContributorsStrip(state: contributors.state)
        }
        .task { await contributors.load() }
        // Here because the sidebar has no other sheet - see the note on
        // RootView's detail pane about two `.sheet`s on one view.
        .sheet(item: $model.pendingRemoval) { RemoveInstanceSheet(instance: $0) }
    }
}

/// The people who have landed a commit, along the bottom of the sidebar.
///
/// A homage rather than a feature: MSL is one person's project today, and
/// the strip exists so that the day it stops being one, the second name
/// shows up somewhere you actually look - not only in a panel behind a menu
/// item. The About window's Contributors pane is still the full version.
///
/// Deliberately silent when it cannot help: no spinner, no error row, no
/// empty state. This is decoration in a sidebar people keep open all day,
/// and a sidebar that periodically announces it could not reach GitHub is
/// worse than one that just shows nothing.
private struct ContributorsStrip: View {
    let state: ContributorsLoader.State
    @Environment(\.openURL) private var openURL

    private var people: [Contributor] {
        if case .loaded(let people) = state { return people }
        return []
    }

    var body: some View {
        Group {
            if !people.isEmpty {
                Divider()
                Button {
                    openURL(URL(string: "https://github.com/MilkmanAbi/MSL/graphs/contributors")!)
                } label: {
                    HStack(spacing: Design.Spacing.small) {
                        Text("Built by")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Overlapped, so a growing list stays the same
                        // width instead of pushing the sidebar around.
                        HStack(spacing: -6) {
                            ForEach(people.prefix(6)) { person in
                                Avatar(person: person)
                            }
                        }
                        if people.count > 6 {
                            Text("+\(people.count - 6)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(people.map(\.login).joined(separator: ", "))
                .padding(.horizontal, Design.Spacing.medium)
                .padding(.vertical, Design.Spacing.small)
            }
        }
    }

    private struct Avatar: View {
        let person: Contributor

        var body: some View {
            AsyncImage(url: URL(string: person.avatarURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.primary.opacity(0.12))
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
            // A ring in the window's own background colour, so overlapped
            // avatars read as separate faces rather than one smear.
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        }
    }
}

/// "2 / 4 running" - the concurrency cap made visible before it is hit,
/// rather than only as an error afterwards.
private struct CapacityPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text("\(model.runningCount)/\(model.runningCap)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(model.atCap ? Color.orange : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(model.atCap ? Color.orange.opacity(0.14) : Color.primary.opacity(0.06))
            )
            .help(model.atCap
                  ? "Every slot is in use. MSL runs at most \(model.runningCap) instances at once."
                  : "\(model.runningCount) of \(model.runningCap) instances running")
    }
}

private struct InstanceRow: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    var body: some View {
        HStack(spacing: Design.Spacing.small + 2) {
            DistroBadge(distro: instance.distro)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.name)
                    .lineLimit(1)
                Text(instance.distro.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Spacing.small)
            if model.isBusy(instance.name) {
                ProgressView().controlSize(.small)
            } else {
                StateIndicator(state: instance.state, showsLabel: false)
            }
        }
        .padding(.vertical, 3)
    }
}

struct InstanceMenu: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    var body: some View {
        if instance.state == .running {
            Button("Suspend") { model.suspend(instance) }
            Button("Shut Down") { model.shutDown(instance) }
        } else {
            Button("Start") { model.start(instance) }
                .disabled(model.atCap && !instance.isLive)
        }
        Divider()
        Button("Open in Terminal.app") { model.openTerminal(instance) }
        Button("Show Apps in Finder") { model.revealInFinder(instance) }
        Divider()
        Button("Remove…", role: .destructive) { model.requestRemove(instance) }
        Button(instance.distro.isCustom
               ? "Remove \(instance.distro.displayName) Image…"
               : "Delete \(instance.distro.displayName) Installation…", role: .destructive) {
            model.requestDistroRemoval(instance.distro)
        }
    }
}

// MARK: - Banner

/// Errors and confirmations as a transient banner rather than a modal
/// alert: nothing here is a question, and an alert per failed background
/// refresh would make the app unusable.
private struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: Design.Spacing.small + 2) {
                Image(systemName: symbol(banner.kind))
                    .foregroundStyle(tint(banner.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).bold()
                    if let detail = banner.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Design.Spacing.medium)
                Button {
                    withAnimation { model.banner = nil }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(Design.Spacing.medium)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            )
            .padding(.top, Design.Spacing.medium)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(banner.id)
            .task(id: banner.id) {
                // Successes and notices clear themselves; errors stay until
                // dismissed, because an error the user missed is an error
                // they will hit again.
                guard banner.kind != .error else { return }
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                withAnimation { model.banner = nil }
            }
        }
    }

    private func symbol(_ kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func tint(_ kind: AppModel.Banner.Kind) -> Color {
        switch kind {
        case .error: return .orange
        case .info: return .accentColor
        case .success: return .green
        }
    }
}
