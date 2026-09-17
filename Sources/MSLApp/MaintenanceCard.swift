import AppKit
import MSLCore
import SwiftUI

/// Disk repair and the other fix-it tools, on an instance's Tools tab.
///
/// Laid out by *when* each tool can run, because that is what decides
/// whether a button can work at all: the disk tools need the instance shut
/// down, the utilities need it running. A disabled button always says why,
/// rather than just going grey.
struct MaintenanceCard: View {
    let instance: Instance

    @State private var status: MaintenanceStatus?
    @State private var serviceProblem: ServiceProblem?

    /// `DaemonClient.send` returns `nil` when it can't connect at all, and an
    /// empty string when it connected but got nothing back - which is what a
    /// daemon from before these tools answers to a command it doesn't know.
    private enum ServiceProblem { case unreachable, outdated }
    @State private var running: MaintenanceCommand?
    @State private var outcome: MaintenanceOutcome?
    @State private var showingLog = false
    @State private var confirming: MaintenanceCommand?

    var body: some View {
        Card(title: "Maintenance", footnote: footnote) {
            // Every image can be absent - a distro that was never installed,
            // or one deleted to reclaim space. Offering "Check Disk" there
            // would send e2fsck at a missing file and come back with an
            // honest but baffling "operational error".
            if !instance.isInstalled {
                Text("This distro isn't installed yet, so there's no disk to check or repair.")
                    .foregroundStyle(.secondary)
            } else if let status {
                diskSection(status)
                Divider()
                bootSection(status)
                Divider()
                utilitiesSection
            } else if let serviceProblem {
                // Reopening the app does *not* fix an outdated daemon: it
                // replaces the binary on disk, but only starts the service if
                // it isn't already running. The running one carries on until
                // it's next launched - at login.
                Text(serviceProblem == .outdated
                     ? "MSL's background service answered, but not in a way this version understands — most likely it's an older version from before these tools existed. The new one takes over the next time you log in."
                     : "MSL's background service isn't answering, so maintenance tools aren't available right now.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Design.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Checking what's available…").foregroundStyle(.secondary)
                }
            }
            if let running { progress(for: running) }
            if let outcome { banner(outcome) }
        }
        .task(id: "\(instance.name)-\(instance.state.label)") { await pollStatus() }
        .confirmationDialog(
            confirmTitle, isPresented: confirmingBinding, titleVisibility: .visible
        ) {
            if let command = confirming {
                Button(confirmButton(command), role: command == .backupRestore ? .destructive : nil) {
                    confirming = nil
                    perform(command)
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var footnote: String {
        "Nothing here changes a disk without asking first, and every repair keeps a copy of the disk from before it — an instant clone that costs no space on your Mac until the disk changes."
    }

    // MARK: - Disk (host side)

    @ViewBuilder
    private func diskSection(_ status: MaintenanceStatus) -> some View {
        sectionHeading("Disk", symbol: "internaldrive")
        Text("Checks the Linux filesystem from the Mac, with the instance shut down — the only state in which a repair is safe.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let reason = diskUnavailableReason(status) {
            unavailable(reason)
            if !status.e2fsckAvailable {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install e2fsprogs", forType: .string)
                }
                .controlSize(.small)
            }
        }

        HStack(spacing: Design.Spacing.small) {
            Button("Check Disk") { perform(.fsckCheck) }
            Button("Repair Disk…") { confirming = .fsckRepair }
        }
        .disabled(diskUnavailableReason(status) != nil || running != nil)

        if status.hasRepairBackup {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("A copy of the disk from before the last repair is kept.")
                    .font(.callout)
                Spacer()
                Button("Restore…") { confirming = .backupRestore }
                Button("Discard") { perform(.backupDiscard) }
            }
            .disabled(running != nil || instance.isLive || status.inProgress)
        }

        Toggle("Check the disk every time this instance starts", isOn: Binding(
            get: { status.checkAtStart },
            set: { perform($0 ? .checkAtStartOn : .checkAtStartOff) }))
            .disabled(!status.e2fsckAvailable || running != nil)
        Text(status.e2fsckAvailable
             ? "Off by default. Adds a full check to every start, and refuses to boot a damaged disk rather than risk it."
             : "Needs e2fsprogs on this Mac.")
            .font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func diskUnavailableReason(_ status: MaintenanceStatus) -> String? {
        if !status.e2fsckAvailable { return E2fsck.installHint }
        return sharedReason(status)
    }

    /// Reasons that block every disk tool, host-side or maintenance boot.
    private func sharedReason(_ status: MaintenanceStatus) -> String? {
        if status.inProgress { return "Maintenance is already running on this disk." }
        if instance.isLive { return "Shut the instance down first — a disk that's in use can't be checked safely." }
        if status.hasSavedSession {
            return "This instance has a hibernated session. Its saved memory and its disk are a pair, so resume it and shut it down before maintenance."
        }
        return nil
    }

    // MARK: - Maintenance boot

    @ViewBuilder
    private func bootSection(_ status: MaintenanceStatus) -> some View {
        sectionHeading("Maintenance Boot", symbol: "wrench.and.screwdriver")
        Text("Starts Linux in a minimal mode — disk read-only, nothing else running — and checks it with Linux's own tools. Works without e2fsprogs on the Mac.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let reason = bootUnavailableReason(status) {
            unavailable(reason)
        } else if status.scriptInImage == nil {
            Text("MSL can't tell whether this image includes the maintenance tools. If it doesn't, you'll be told — nothing is changed.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: Design.Spacing.small) {
            Button("Check from Linux") { perform(.bootFsckCheck) }
            Button("Repair from Linux…") { confirming = .bootFsckRepair }
        }
        .disabled(bootUnavailableReason(status) != nil || running != nil)
    }

    private func bootUnavailableReason(_ status: MaintenanceStatus) -> String? {
        if let shared = sharedReason(status) { return shared }
        if status.scriptInImage == false {
            return "Needs a rebuilt image — this one was made before MSL's maintenance tools existed."
        }
        return nil
    }

    // MARK: - Utilities (guest running)

    @ViewBuilder
    private var utilitiesSection: some View {
        sectionHeading("While It's Running", symbol: "play.circle")
        ForEach(GuestUtility.allCases, id: \.self) { utility in
            HStack(alignment: .top, spacing: Design.Spacing.small) {
                Image(systemName: utility.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(utility.title)
                    Text(utility.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.Spacing.small)
                Button("Run") { perform(.command(for: utility)) }
                    .disabled(instance.state != .running || running != nil)
            }
        }
        if instance.state != .running {
            Text("Start the instance to use these.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Shared pieces

    private func sectionHeading(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
    }

    private func unavailable(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.tight) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(reason)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(for command: MaintenanceCommand) -> some View {
        HStack(spacing: Design.Spacing.small) {
            ProgressView().controlSize(.small)
            Text(progressText(command))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Design.Spacing.tight)
    }

    private func progressText(_ command: MaintenanceCommand) -> String {
        switch command {
        case .fsckCheck: return "Checking the disk… a large disk can take a few minutes."
        case .fsckRepair: return "Backing up, then repairing the disk…"
        case .bootFsckCheck: return "Booting into maintenance mode to check the disk…"
        case .bootFsckRepair: return "Backing up, then booting into maintenance mode to repair the disk…"
        case .backupRestore: return "Restoring the disk…"
        default:
            if let utility = command.utility { return "\(utility.title)…" }
            return "Working…"
        }
    }

    private func banner(_ outcome: MaintenanceOutcome) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack(alignment: .top, spacing: Design.Spacing.small) {
                Image(systemName: symbol(for: outcome.tone))
                    .foregroundStyle(color(for: outcome.tone))
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.title).font(.callout.weight(.semibold))
                    if !outcome.detail.isEmpty {
                        Text(outcome.detail)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    self.outcome = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Dismiss")
            }
            if !outcome.log.isEmpty {
                DisclosureGroup("Show details", isExpanded: $showingLog) {
                    // A fixed height inside the tab's own scroll view - an
                    // unbounded ScrollView here sizes itself to the whole log
                    // and draws straight through everything below it.
                    ScrollView {
                        Text(outcome.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Design.Spacing.small)
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                }
                .font(.caption)
            }
        }
        .padding(Design.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color(for: outcome.tone).opacity(0.10)))
        .padding(.top, Design.Spacing.tight)
    }

    private func color(for tone: MaintenanceOutcome.Tone) -> Color {
        switch tone {
        case .good: return .green
        case .attention: return .orange
        case .bad: return .red
        case .info: return .blue
        }
    }

    private func symbol(for tone: MaintenanceOutcome.Tone) -> String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    // MARK: - Confirmation

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        switch confirming {
        case .fsckRepair: return "Repair this instance's disk?"
        case .bootFsckRepair: return "Repair the disk from inside Linux?"
        case .backupRestore: return "Put the old disk back?"
        default: return ""
        }
    }

    private var confirmMessage: String {
        switch confirming {
        case .fsckRepair:
            return "MSL takes an instant copy of the disk first, then lets e2fsck fix everything it can. The copy is kept until you discard it, so the repair can be undone."
        case .bootFsckRepair:
            return "Linux starts in maintenance mode with the disk read-only and repairs it with its own tools, then shuts down. An instant copy of the disk is taken first."
        case .backupRestore:
            return "This replaces the disk with the copy taken before the last repair. Anything written to the disk since that repair is lost."
        default:
            return ""
        }
    }

    private func confirmButton(_ command: MaintenanceCommand) -> String {
        switch command {
        case .fsckRepair, .bootFsckRepair: return "Repair"
        case .backupRestore: return "Restore Old Disk"
        default: return "Continue"
        }
    }

    // MARK: - Talking to the daemon

    private func perform(_ command: MaintenanceCommand) {
        guard running == nil else { return }
        running = command
        outcome = nil
        showingLog = false
        let name = instance.name
        Task {
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.maintenance(instance: name, command: command), timeout: command.clientTimeout)
            }.value
            running = nil
            outcome = Self.outcome(from: reply)
            await refreshStatus()
        }
    }

    /// Every reply becomes a sentence - including no reply at all.
    private static func outcome(from reply: String?) -> MaintenanceOutcome {
        guard let reply else {
            return .failure("MSL's background service didn't answer in time. It may still be working — check again in a moment.")
        }
        guard reply.hasPrefix("OK") else {
            let message = reply.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
            return .failure(message ?? reply)
        }
        let body = String(reply.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return MaintenanceOutcome.fromWireLine(body)
            ?? .failure("MSL's background service sent a reply this version of the app couldn't read.")
    }

    private func pollStatus() async {
        while !Task.isCancelled {
            await refreshStatus()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func refreshStatus() async {
        let name = instance.name
        let reply = await Task.detached(priority: .utility) {
            DaemonClient.send(.maintenance(instance: name, command: .status), timeout: 15)
        }.value
        if let reply, reply.hasPrefix("OK"),
           let decoded = MaintenanceStatus.fromWireLine(String(reply.dropFirst(2)).trimmingCharacters(in: .whitespaces)) {
            status = decoded
            serviceProblem = nil
        } else if status == nil {
            serviceProblem = reply == nil ? .unreachable : .outdated
        }
    }
}
