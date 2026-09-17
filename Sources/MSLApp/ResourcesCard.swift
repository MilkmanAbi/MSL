import MSLCore
import SwiftUI

/// CPU and memory allocation for one instance.
///
/// The distinction this has to draw clearly is between the two memory
/// modes, because they behave differently in a way that is invisible
/// otherwise: **Manual** books a fixed amount of the Mac's RAM for as long
/// as the instance runs, and **Dynamic** books the maximum but hands most
/// of it back whenever the guest is not using it.
///
/// Both take effect at the instance's next start. The framework fixes a
/// VM's memory size when the VM object is built and offers no way to change
/// it afterwards - the balloon moves *within* that size, it cannot exceed
/// it - so there is no honest way to apply this to a running guest.
struct ResourcesCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var policy = ResourcePolicy.inherited
    @State private var mode: Mode = .manual
    @State private var manualMB: Double = 2048
    @State private var floorMB: Double = 1024
    @State private var ceilingMB: Double = 4096
    @State private var cpuCount: Double = 4
    @State private var loaded = false
    @State private var saved = false
    @State private var live: LiveMemory?

    private enum Mode: String, CaseIterable, Identifiable {
        case manual = "Manual"
        case dynamic = "Dynamic"
        var id: String { rawValue }
    }

    private var hostMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    private var hostMemoryMB: UInt64 { hostMemory / (1024 * 1024) }

    private var draftMode: MemoryMode {
        mode == .manual
            ? .manual(megabytes: UInt64(manualMB))
            : .dynamic(floorMegabytes: UInt64(floorMB), ceilingMegabytes: UInt64(ceilingMB))
    }

    private var advice: MemoryAdvice {
        MemoryAdvisor.advise(mode: draftMode, hostMemory: hostMemory)
    }

    private var dirty: Bool {
        policy.resolvedMemory() != draftMode || policy.resolvedCPUCount() != Int(cpuCount)
    }

    var body: some View {
        Card(title: "Processor & memory", footnote: footnote) {
            processorRow
            Divider()
            modePicker
            if mode == .manual { manualControls } else { dynamicControls }
            if let message = advice.message { adviceBanner(message) }
            Divider()
            actions
            if mode == .dynamic, instance.state == .running { liveReadout }
        }
        .task(id: instance.name) { loadPolicy() }
        .task(id: pollKey) { await pollLive() }
    }

    // MARK: - Processor

    private var processorRow: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Text("Virtual CPUs").foregroundStyle(.secondary)
                Spacer()
                // Stepper rather than a free field: the useful range is small
                // and bounded, and the framework's own maximum (64 on this
                // Mac, whatever its core count) is not a useful upper bound
                // to offer someone.
                // The count is its own Text rather than the Stepper's label:
                // `.labelsHidden()` hides the label, so a Stepper whose label
                // *is* the value renders as two bare arrows with no number.
                Text("\(Int(cpuCount))")
                    .monospacedDigit()
                    .frame(minWidth: 24, alignment: .trailing)
                Stepper("", value: $cpuCount, in: 1...Double(maximumUsefulCPUs), step: 1)
                    .labelsHidden()
            }
            Text("This Mac has \(ProcessInfo.processInfo.processorCount) logical cores. vCPUs are time-shared, not reserved, so instances can each have several.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Beyond the host's own core count a guest mostly contends with itself,
    /// so that is the offered ceiling even though the framework permits far
    /// more.
    private var maximumUsefulCPUs: Int {
        max(1, ProcessInfo.processInfo.processorCount)
    }

    // MARK: - Memory

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Picker("Memory", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(mode == .manual
                 ? "A fixed amount, reserved on your Mac the whole time this instance is running."
                 : "The instance starts with the maximum and gives back what it isn't using. MSL watches how much the guest actually needs and adjusts continuously.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualControls: some View {
        megabyteRow(label: "Memory", value: $manualMB,
                    range: 512...Double(hostMemoryMB))
    }

    private var dynamicControls: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            megabyteRow(label: "Minimum", value: $floorMB, range: 512...ceilingMB)
            megabyteRow(label: "Maximum", value: $ceilingMB, range: max(512, floorMB)...Double(hostMemoryMB))
            Text("The maximum is what your Mac sets aside at start; the minimum is as far down as MSL will ever squeeze the guest.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func megabyteRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: Design.Spacing.small) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .monospacedDigit()
                .onSubmit { value.wrappedValue = value.wrappedValue.clamped(to: range) }
            Text("MB").foregroundStyle(.secondary)
        }
    }

    private func adviceBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: advice.severity == .blocking
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(advice.severity == .blocking ? .red : .orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((advice.severity == .blocking ? Color.red : Color.orange).opacity(0.10)))
    }

    private var actions: some View {
        HStack(spacing: Design.Spacing.small) {
            Button("Apply") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!dirty || !advice.allowsStart)
            if dirty {
                Button("Revert") { loadPolicy(force: true) }
            }
            Spacer()
            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    // MARK: - Live

    /// The decoded state plus the human-readable reason text, which is
    /// prose and deliberately does not round-trip into an enum case.
    private struct LiveMemory {
        var state: BalloonGovernor.State
        var reasonText: String?
    }

    private var pollKey: String { "\(instance.name)-\(instance.state.label)-\(mode.rawValue)" }

    private var liveReadout: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Divider()
            if let live {
                switch live.state.availability {
                case .guestAgentMissing:
                    Text("This instance's image was built before MSL could measure guest memory, so it keeps its full maximum. Rebuilding the image enables dynamic sizing.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .notStarted:
                    Text("Not running yet.").font(.caption).foregroundStyle(.tertiary)
                case .active:
                    if let target = live.state.target {
                        DetailRow(label: "Allocated right now", value: format(target))
                    }
                    if let inUse = live.state.guestInUseBytes, let total = live.state.guestTotalBytes {
                        DetailRow(label: "Guest is using", value: "\(format(inUse)) of \(format(total))")
                    }
                    if let stall = live.state.stallPercent, stall > 0 {
                        DetailRow(label: "Guest stalling on memory",
                                  value: String(format: "%.1f%%", stall))
                    }
                    if let reason = live.reasonText {
                        DetailRow(label: "Last change", value: reason)
                    }
                    DetailRow(label: "Adjustments this session", value: "\(live.state.adjustments)")
                    if live.state.guestHasSwap {
                        Text("This guest has swap enabled. MSL still sizes it conservatively, but swap changes what running out of memory feels like.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Reading…").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func format(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / (1024 * 1024))
    }

    private var footnote: String {
        "Takes effect the next time this instance starts. A VM's memory size is fixed when it boots, so changing it can't apply to a running guest — and a suspended session saved for this instance will be discarded rather than resumed into a differently sized machine."
    }

    // MARK: - Plumbing

    private func loadPolicy(force: Bool = false) {
        guard !loaded || force else { return }
        let stored = ResourcePolicyStore.load(instance: instance.name)
        policy = stored
        cpuCount = Double(stored.resolvedCPUCount())
        switch stored.resolvedMemory() {
        case .manual(let megabytes):
            mode = .manual
            manualMB = Double(megabytes)
            if case .dynamic(let floor, let ceiling) = MemoryAdvisor.defaultDynamicRange(hostMemory: hostMemory) {
                floorMB = Double(floor)
                ceilingMB = Double(max(ceiling, megabytes))
            }
        case .dynamic(let floor, let ceiling):
            mode = .dynamic
            floorMB = Double(floor)
            ceilingMB = Double(ceiling)
            manualMB = Double(ceiling)
        }
        loaded = true
        saved = false
    }

    private func save() {
        var updated = policy
        updated.memory = draftMode
        updated.cpuCount = Int(cpuCount)
        guard ResourcePolicyStore.save(updated, instance: instance.name) else { return }
        policy = updated
        saved = true
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            saved = false
        }
    }

    private func pollLive() async {
        guard mode == .dynamic else { return }
        let name = instance.name
        while !Task.isCancelled {
            let response = await Task.detached(priority: .utility) {
                DaemonClient.send(.memoryStatus(instance: name), timeout: 10)
            }.value
            if let response, response.hasPrefix("OK") {
                let decoded = BalloonGovernor.State.fromWireLine(
                    String(response.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                live = LiveMemory(state: decoded.state, reasonText: decoded.reasonText)
            } else {
                live = LiveMemory(state: BalloonGovernor.State(), reasonText: nil)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
