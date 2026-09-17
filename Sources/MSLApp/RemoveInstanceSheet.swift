import MSLCore
import SwiftUI

/// Confirms removing an instance by having the user type "Meow".
///
/// A sheet rather than `confirmationDialog`, which can't hold a text field.
/// Owned by the sidebar and driven by `AppModel.pendingRemoval`, so the
/// sidebar's context menu and the instance page's button share one gate.
struct RemoveInstanceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let instance: Instance

    @State private var typed = ""
    @State private var keepDisk = false
    @FocusState private var fieldFocused: Bool

    private var confirmed: Bool { RemovalConfirmation.matches(typed) }

    private var distroName: String { instance.distro.displayName }

    /// Nothing else shares the disk, so removing this instance deletes it -
    /// otherwise the space never came back (2026-09-16: 63 GB stranded).
    private var isLastOfDistro: Bool {
        !instance.distro.isCustom && instance.isInstalled && model.instances(of: instance.distro).count == 1
    }

    private var diskSize: String {
        DiskStorage.format(DistroInstallation.allocatedBytes(for: instance.distro))
    }

    private var distroSummary: String {
        let count = model.instances(of: instance.distro).count
        let size = DiskStorage.format(DistroInstallation.allocatedBytes(for: instance.distro))
        let instancesText = count == 1 ? "its only instance" : "all \(count) of its instances"
        return "Deleting the \(distroName) installation removes \(instancesText) and the \(size) disk they share, so the space comes back to your Mac. You can reinstall \(distroName) any time."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(alignment: .top, spacing: Design.Spacing.medium) {
                Image(systemName: "trash")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("Remove \(instance.name)?")
                        .font(.headline)
                    Text("Its saved session, snapshots, the Mac apps made for it and its SSH entry are deleted. This can't be undone.")
                        .fixedSize(horizontal: false, vertical: true)
                    if isLastOfDistro {
                        Text(keepDisk
                             ? "The \(distroName) disk stays, with everything on it, for the next \(distroName) instance you create."
                             : "It's the last \(distroName) instance, so its disk and everything on it are deleted too, giving \(diskSize) back to your Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Keep the \(distroName) disk", isOn: $keepDisk)
                    } else {
                        Text("The \(distroName) disk itself stays - other \(distroName) instances use it too.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Type **\(RemovalConfirmation.word)** to confirm.")
                TextField(RemovalConfirmation.word, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { if confirmed { remove() } }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { remove() }
                    .disabled(!confirmed)
            }

            // Not tucked away: removing instances one by one never frees the
            // disk they share, and hunting for the image in Finder is the
            // alternative. Its own, stronger confirmation follows. Not shown
            // for the last instance, whose removal already frees it.
            if !isLastOfDistro {
            Divider()
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Free up space instead")
                    .font(.subheadline.weight(.semibold))
                Text(distroSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    let distro = instance.distro
                    dismiss()
                    // After this sheet has gone, so the next can present.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        model.requestDistroRemoval(distro)
                    }
                } label: {
                    Text("Delete \(distroName) installation — DELETES ALL \(distroName.uppercased()) INSTANCES")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }

    private func remove() {
        guard confirmed else { return }
        dismiss()
        model.remove(instance, keepDisk: isLastOfDistro && keepDisk)
    }
}
