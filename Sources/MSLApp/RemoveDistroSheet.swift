import MSLCore
import SwiftUI

/// Confirms deleting a whole distro installation: every instance of it and
/// the disk they share.
///
/// Its own sheet with its own, longer phrase - "Delete all my Debian
/// instances" - rather than a second step of the Meow sheet, because it
/// destroys far more: not one instance's saved state but every instance and
/// everything installed inside the distro. Presented from the sidebar's list,
/// a different view from the one presenting `RemoveInstanceSheet`.
struct RemoveDistroSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let distro: GuestDistro

    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var name: String { distro.displayName }
    private var phrase: String { DistroRemovalConfirmation.phrase(distroName: name) }
    private var confirmed: Bool { DistroRemovalConfirmation.matches(typed, distroName: name) }
    private var affected: [Instance] { model.instances(of: distro) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(alignment: .top, spacing: Design.Spacing.medium) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text(distro.isCustom ? "Remove the \(name) image from MSL?" : "Delete the \(name) installation?")
                        .font(.headline)
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                    if distro.isCustom {
                        Text("The image's folder in Custom Images, and everything in it, stays exactly as it is - it's yours. Put it back in MSL any time by creating an instance from it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Everything installed or saved inside \(name) goes with it. This can't be undone.")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !affected.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(affected) { instance in
                        Label(instance.name, systemImage: "square.stack.3d.up")
                            .font(.callout)
                    }
                }
                .padding(Design.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Type **\(phrase)** to confirm.")
                    .fixedSize(horizontal: false, vertical: true)
                TextField(phrase, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { if confirmed { delete() } }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(distro.isCustom ? "Remove \(name) Image" : "Delete \(name) Installation", role: .destructive) { delete() }
                    .disabled(!confirmed)
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private var detail: String {
        if distro.isCustom {
            switch affected.count {
            case 0: return "No instances use it any more."
            case 1: return "Its instance below is removed."
            default: return "All \(affected.count) instances below are removed."
            }
        }
        let size = DiskStorage.format(DistroInstallation.allocatedBytes(for: distro))
        switch affected.count {
        case 0: return "No instances use it any more. Its \(size) disk is deleted."
        case 1: return "Its instance below is removed, and its \(size) disk is deleted."
        default: return "All \(affected.count) instances below are removed, and the \(size) disk they share is deleted."
        }
    }

    private func delete() {
        guard confirmed else { return }
        dismiss()
        model.removeDistroInstallation(distro)
    }
}
