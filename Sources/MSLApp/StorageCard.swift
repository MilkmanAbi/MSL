import MSLCore
import SwiftUI

/// Disk sizing for an instance: how much it may use, whether that space is
/// reserved on the Mac, and how full the guest actually is.
///
/// The distinction this draws is the one that matters and is easy to get
/// backwards: **capacity** is what the guest believes its disk is, while
/// **on your Mac** is what the file actually costs right now. For a dynamic
/// disk those are wildly different, and showing only one of them is how a
/// user ends up either afraid to raise the limit or surprised by a full
/// disk.
struct StorageCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var policy = StoragePolicy()
    @State private var draftMode: StorageMode = .dynamic
    @State private var draftSize: Double = 15
    @State private var error: String?
    @State private var applying = false
    @State private var reservation: DiskStorage.ReservationProgress?

    private var imageName: String { instance.distro.diskImageFilename }
    private var imagePath: String {
        MSLPaths.appSupport.appendingPathComponent(imageName).path
    }

    private var capacity: UInt64 { DiskStorage.capacity(of: imagePath) }
    private var onDisk: UInt64 { DiskStorage.allocatedSize(of: imagePath) }
    private var usage: DiskStorage.Usage? { DiskStorage.usage(forImageNamed: imageName) }

    /// What the Overview scrolls to when a new instance's first-run guide
    /// brings it here - see `AppModel.FirstRunGuide`.
    static let anchorID = "storage-card"

    private var isGuided: Bool {
        model.firstRunGuide == AppModel.FirstRunGuide(instance: instance.name, step: .storage) && instance.isInstalled
    }

    @State private var pulse = false

    var body: some View {
        card
            .overlay {
                if isGuided {
                    RoundedRectangle(cornerRadius: Design.cornerRadius + 4, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .padding(-6)
                        .opacity(pulse ? 1 : 0.2)
                        .allowsHitTesting(false)
                        .onAppear {
                            pulse = false
                            withAnimation(.easeInOut(duration: 0.7).repeatCount(5, autoreverses: true)) { pulse = true }
                        }
                }
            }
    }

    /// Shown only while the first-run guide is on this card: what the choice
    /// is, why now, and the way on.
    private var firstRunCallout: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Label("First, how much space should \(instance.name) have?", systemImage: "internaldrive")
                .font(.headline)
            Text("Everything you install and every file you make in Linux lives on this disk. It starts at 15 GB. Pick Dynamic or Fixed, drag to the size you want, then press Provision - or keep 15 GB and go on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    model.continueFirstRunGuideToAccount()
                } label: {
                    Label("Next: create your Linux account", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(applying)
                Button("Not now") { model.endFirstRunGuide() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var card: some View {
        Card(title: "Storage", footnote: footnote) {
            if isGuided {
                firstRunCallout
                Divider()
            }
            if !instance.isInstalled {
                Text("This distro isn't installed yet, so it has no disk.")
                    .foregroundStyle(.secondary)
            } else {
                usageBar
                Divider()
                DetailRow(label: "Disk size now", value: DiskStorage.format(capacity))
                Divider()
                DetailRow(
                    label: "Actually used on your Mac",
                    value: DiskStorage.format(onDisk)
                        + (DiskStorage.isSparse(imagePath) ? "" : " (reserved)"))
                Divider()
                modeControls
                    .disabled(applying)
                provisionRow
                if applying { applyingProgress }
                if DiskStorage.filesystemResizeIsPending(forImageNamed: imageName) {
                    Divider()
                    Label("Linux grows its filesystem to the new size the next time \(instance.name) starts.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: instance.isInstalled) { _, _ in reload() }
    }

    @ViewBuilder private var applyingProgress: some View {
        if let reservation {
            VStack(alignment: .leading, spacing: Design.Spacing.tight + 2) {
                HStack {
                    Text("Reserving space on your Mac")
                    Spacer()
                    Text("\(Int(reservation.fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: reservation.fraction)
                Text(reservation.description + ". Your Mac stays awake until it's done; you can keep using MSL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        } else {
            HStack(spacing: Design.Spacing.small) {
                ProgressView().controlSize(.small)
                Text(draftMode == .fixed ? "Getting ready to reserve space…" : "Resizing…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var usageBar: some View {
        if let usage, usage.total > 0 {
            VStack(alignment: .leading, spacing: Design.Spacing.tight + 2) {
                HStack {
                    Text("\(DiskStorage.format(usage.used)) used inside \(instance.name)")
                    Spacer()
                    Text("\(Int(usage.fraction * 100))% of \(DiskStorage.format(usage.total))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                ProgressView(value: min(usage.fraction, 1))
                    .tint(usage.fraction >= StoragePolicy.growThreshold ? .orange : .accentColor)
                Text("Measured \(usage.sampled.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("Start this instance once and MSL will measure how full it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Nothing here touches the disk. Mode and size are a draft until
    /// Provision is pressed: switching to Fixed used to start writing 64 GB
    /// the instant the segment was clicked, before the size could even be
    /// chosen (2026-09-16).
    private var modeControls: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small + 2) {
            Picker("", selection: $draftMode) {
                Text("Dynamic").tag(StorageMode.dynamic)
                Text("Fixed").tag(StorageMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(draftMode == .dynamic
                 ? "Linux sees the full size, but your Mac only gives up space as files are actually written."
                 : "Reserves the whole size on your Mac up front, so nothing else can take it. Reserving writes the whole disk once, so it takes a while.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.Spacing.medium) {
                Text("Size")
                    .foregroundStyle(.secondary)
                Slider(value: $draftSize, in: sliderRange, step: 1)
                Text("\(Int(draftSize)) GB")
                    .font(.callout.monospacedDigit())
                    .frame(width: 62, alignment: .trailing)
            }
            .font(.callout)
        }
    }

    /// The only control that changes the disk.
    private var provisionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            if let blocker = provisionBlocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasChanges {
                Text(changeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if hasChanges && !applying {
                Button("Revert") { reload() }
                    .buttonStyle(.borderless)
            }
            Button(applying ? "Provisioning…" : "Provision") { apply() }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || applying || provisionBlocker != nil)
        }
    }

    private var draftBytes: UInt64 { UInt64(draftSize) << 30 }

    /// A disk only grows, so the slider starts at what it already is.
    private var sliderRange: ClosedRange<Double> {
        let floor = max(4, (Double(capacity) / Double(1 << 30)).rounded(.up))
        return floor...max(floor, 512)
    }

    /// Something to provision: a new mode, a bigger size, or a fixed disk that
    /// isn't actually reserved yet (a reservation that was interrupted).
    ///
    /// Compared in whole GB, the slider's own unit: a disk that isn't an exact
    /// number of GB (auto-grown, or published at an odd size) would otherwise
    /// never match the slider and Provision would never grey out.
    private var hasChanges: Bool {
        draftMode != policy.mode
            || Int(draftSize) != restingGB
            || (draftMode == .fixed && DiskStorage.isSparse(imagePath))
    }

    /// What the slider shows when nothing has been changed.
    private var restingGB: Int {
        Int((Double(max(policy.size, capacity)) / Double(1 << 30)).rounded(.up))
    }

    private var changeSummary: String {
        let extra = draftBytes > onDisk ? draftBytes - onDisk : 0
        switch draftMode {
        case .fixed:
            return "Reserves \(DiskStorage.format(extra)) more on your Mac."
        case .dynamic:
            return draftBytes > capacity
                ? "Grows the disk to \(DiskStorage.format(draftBytes)) - costs nothing on your Mac until it's used."
                : "Stops reserving space; files already written stay."
        }
    }

    private var provisionBlocker: String? {
        if instance.isLive {
            return "Stop \(instance.name) to change its disk - a running instance keeps the size it started with."
        }
        if draftMode == .fixed {
            let extra = draftBytes > onDisk ? draftBytes - onDisk : 0
            let free = DiskStorage.hostFreeSpace(forImageAt: imagePath)
            if extra > free {
                return "Not enough free space: needs \(DiskStorage.format(extra)), your Mac has \(DiskStorage.format(free))."
            }
        }
        return nil
    }

    private var footnote: String {
        var lines = ["A disk can be made bigger but never smaller."]
        if instance.isInstalled {
            lines.append("\(DiskStorage.format(DiskStorage.hostFreeSpace(forImageAt: imagePath))) free on your Mac.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Actions

    private func reload() {
        policy = DiskStorage.policy(forImageNamed: imageName, path: imagePath)
        draftMode = policy.mode
        // The slider shows the size the disk will be: the larger of what it
        // is and what the policy asks for - never a number it isn't.
        draftSize = Double(restingGB)
        error = nil
    }

    private func apply() {
        guard !instance.isLive, !applying, provisionBlocker == nil else { return }
        error = nil
        let newPolicy = StoragePolicy(mode: draftMode, size: max(draftBytes, capacity), autoGrow: draftMode == .dynamic)

        // Off the main thread, always. Reserving space for a fixed disk
        // writes zeroes over every unallocated block - for a 512 GB disk
        // that is 512 GB of real writes, and doing it inline froze the
        // whole window until it finished.
        applying = true
        reservation = nil
        let path = imagePath
        let name = imageName

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                let before = DiskStorage.capacity(of: path)
                // Writing tens of GB outlasts the display-sleep timer, and a
                // sleeping Mac pauses the write.
                let awake = newPolicy.mode == .fixed ? KeepAwake() : nil
                defer { awake?.release() }
                do {
                    try DiskStorage.setCapacity(of: path, to: newPolicy.size, reserveSpace: newPolicy.mode == .fixed) { update in
                        Task { @MainActor in reservation = update }
                    }
                } catch {
                    return "\(error)"
                }
                // Saved only once the disk really is what it says, so an
                // interrupted reservation still shows Provision.
                DiskStorage.setPolicy(newPolicy, forImageNamed: name)
                // Only when the disk actually grew: scheduling a guest-side
                // `resize2fs` after a change that resized nothing means a
                // pointless command on the next boot and a "pending" notice
                // that never clears.
                if DiskStorage.capacity(of: path) > before {
                    DiskStorage.markFilesystemResizePending(forImageNamed: name)
                }
                return nil
            }.value
            applying = false
            reservation = nil
            if outcome == nil {
                reload()
            } else {
                // Keep the user's choice on screen so they can retry it.
                policy = DiskStorage.policy(forImageNamed: name, path: path)
                error = outcome
            }
        }
    }
}
