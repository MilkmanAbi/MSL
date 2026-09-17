import MSLCore
import SwiftUI

/// Four switches that decide what one instance can reach.
///
/// The design point worth keeping: every switch here is a **host-side**
/// mechanism. Nothing asks the guest to behave - the network card is
/// detached, the share is revoked, the display server stops listening,
/// input is dropped before it is encoded. A guest that wanted to ignore all
/// of this has no way to; none of it is implemented anywhere it can reach.
///
/// The switches are driven by what the daemon reports the VM's devices are
/// doing, not by what was last asked for. Those can differ - `VZNetworkDevice`
/// documents that its attachment "may change at any time based on the state
/// of the host network" - and showing the request instead of the truth would
/// make this exactly the kind of security UI that lies.
struct SandboxTab: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var showingMonitor = false

    private var policy: SandboxPolicy { model.sandboxPolicy(for: instance) }
    private var busy: Bool { model.sandboxBusy.contains(instance.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            postureHeader

            Card(title: "Gates",
                 footnote: "Kept across restarts. Re-applied every time this instance "
                         + "starts or resumes, so hibernating won't quietly hand anything back.") {
                ForEach(Array(SandboxPolicy.Gate.allCases.enumerated()), id: \.element.id) { index, gate in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    GateRow(gate: gate,
                            closed: policy.isClosed(gate),
                            disabled: busy) { closed in
                        model.setSandboxGate(gate, closed: closed, for: instance)
                    }
                }
            }

            Card(title: "Watch",
                 footnote: "Shows MSL's own traffic — what the host and this guest are "
                         + "actually saying to each other.") {
                HStack(spacing: Design.Spacing.medium) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Traffic Monitor").font(.body)
                        Text("A live log of shell sessions, file operations, X11 connections "
                             + "and VM lifecycle events.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Design.Spacing.medium)
                    Button("Open") { showingMonitor = true }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }

            if !policy.isOpen { sealedNote }
        }
        .task(id: instance.name) { model.refreshSandbox(instance) }
        .sheet(isPresented: $showingMonitor) {
            TrafficMonitorView(instance: instance)
        }
    }

    // MARK: - Header

    private var postureHeader: some View {
        HStack(spacing: Design.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(postureTint.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: postureSymbol)
                    .font(.title2)
                    .foregroundStyle(postureTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(policy.posture.rawValue)
                    .font(.title3).bold()
                Text(postureDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Spacing.medium)
            Button(policy.isSealed ? "Open everything" : "Seal it") {
                model.setSandbox(policy.isSealed ? .open : .sealed, for: instance)
            }
            .disabled(busy)
        }
    }

    private var postureTint: Color {
        switch policy.posture {
        case .open:    return .secondary
        case .partial: return .orange
        case .sealed:  return .red
        }
    }

    private var postureSymbol: String {
        switch policy.posture {
        case .open:    return "lock.open"
        case .partial: return "lock.badge.clock"
        case .sealed:  return "lock.fill"
        }
    }

    /// Present tense only when the instance is actually up.
    ///
    /// A stopped instance genuinely has no network either way, so claiming
    /// "is running with no route out" over a stopped VM is both wrong and
    /// the kind of wrong that makes someone distrust the rest of the panel.
    /// The gates are still real for a stopped instance - they are what its
    /// next start gets - so the copy says that instead.
    private var isUp: Bool { instance.state == .running || instance.state == .paused }

    private var postureDetail: String {
        switch policy.posture {
        case .open:
            return isUp
                ? "\(instance.name) can reach the network, your Mac home folder, and the "
                + "display server, and takes keyboard and mouse input."
                : "Nothing is restricted. When \(instance.name) starts it will have the "
                + "network, your Mac home folder, the display server and input."
        case .partial:
            let count = policy.closedGateCount
            let total = SandboxPolicy.Gate.allCases.count
            return isUp
                ? "\(count) of \(total) gates are closed."
                : "\(count) of \(total) gates are closed, and will be from the moment "
                + "\(instance.name) starts."
        case .sealed:
            return isUp
                ? "Every gate is closed. \(instance.name) has no route out: no network, "
                + "no share, no new windows, no input."
                : "Every gate is closed. \(instance.name) will start with no route out: "
                + "no network, no share, no new windows, no input."
        }
    }

    private var sealedNote: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("These are switches on top of the VM, not the boundary itself — the "
                 + "virtual machine is that. They're host-side, so the guest can't undo "
                 + "them, but they don't harden the VM against escape.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One gate. Closed reads as the notable state, so the explanation only
/// appears when it is closed - an open gate needs no defence.
private struct GateRow: View {
    let gate: SandboxPolicy.Gate
    let closed: Bool
    let disabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack(spacing: Design.Spacing.medium) {
                Image(systemName: gate.symbol)
                    .font(.body)
                    .foregroundStyle(closed ? Color.red : Color.secondary)
                    .frame(width: 22)
                Text(gate.title)
                Spacer(minLength: Design.Spacing.medium)
                Text(closed ? "Cut" : "Open")
                    .font(.caption)
                    .foregroundStyle(closed ? Color.red : .secondary)
                Toggle("", isOn: Binding(get: { closed }, set: onChange))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(disabled)
            }
            if closed {
                Text(gate.closedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22 + Design.Spacing.medium)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: closed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gate.title), \(closed ? "cut" : "open")")
    }
}
