import MSLCore
import SwiftUI

/// Creating an instance is two decisions - what to call it and which
/// Linux - so it is one sheet, not a wizard. The Linux is one of MSL's
/// distros or one of the user's own custom images.
struct NewInstanceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var distro: GuestDistro = .alpine

    @State private var showingStartFromDistro = false
    @State private var newImageID = ""
    @State private var newImageSource: GuestDistro = .alpine
    @State private var creatingImage = false

    private var nameIsValid: Bool { InstanceRegistry.isValidName(name) }
    private var nameIsTaken: Bool { model.instances.contains { $0.name.lowercased() == name.lowercased() } }
    private var selectedCustomImage: CustomImage? {
        distro.customSlug.flatMap { slug in model.customImages.first { $0.slug == slug } }
    }
    private var canCreate: Bool {
        nameIsValid && !nameIsTaken && (!distro.isCustom || selectedCustomImage?.isUsable == true)
    }

    private var isInstalled: Bool { DistroInstallation.isInstalled(distro) }

    private var installedDistros: [GuestDistro] {
        GuestDistro.allCases.filter { DistroInstallation.isInstalled($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                Text("New Instance").font(.title2).bold()
                Text("An instance is one Linux machine with its own name. Instances of the same distro or image share one disk, so only one of them can run at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Name").font(.subheadline).bold().foregroundStyle(.secondary)
                TextField("work", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canCreate { create() } }
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(name.isEmpty || (nameIsValid && !nameIsTaken) ? .secondary : Color.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.large) {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Distribution").font(.subheadline).bold().foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Design.Spacing.small)],
                                  spacing: Design.Spacing.small) {
                            ForEach(GuestDistro.allCases, id: \.self) { candidate in
                                DistroChoice(distro: candidate, isSelected: candidate == distro)
                                    .onTapGesture { distro = candidate }
                            }
                        }
                    }

                    customImagesSection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 460)

            if !distro.isCustom, !isInstalled {
                Label(
                    "\(distro.displayName) isn't downloaded yet. Creating the instance is instant; run `msl install \(distro.rawValue)` in Terminal to fetch it before starting.",
                    systemImage: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(Design.Spacing.section - 4)
        .frame(width: 560)
        .onAppear {
            model.refreshCustomImages()
            if let first = installedDistros.first { newImageSource = first }
        }
    }

    // MARK: Custom images

    private var customImagesSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("Custom images").font(.subheadline).bold().foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshCustomImages()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Look in Custom Images again")
                Button {
                    model.openCustomImagesFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .controlSize(.small)
                .help("Custom Images in Finder, with a README on making one")
            }

            if model.customImages.isEmpty {
                Text("Your own Linux images: a folder with a kernel, an initramfs and a disk. Open the folder for how to make one, or start from a distro you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Design.Spacing.small) {
                    ForEach(model.customImages) { image in
                        CustomImageChoice(image: image, isSelected: image.distro == distro,
                                          reveal: { model.openCustomImagesFolder(selecting: image) })
                            .onTapGesture { distro = image.distro }
                    }
                }
            }

            DisclosureGroup("Start a custom image from a distro", isExpanded: $showingStartFromDistro) {
                startFromDistro
                    .padding(.top, Design.Spacing.small)
            }
            .font(.callout)
        }
    }

    private var newImageIDIsValid: Bool {
        CustomImage.isValidSlug(newImageID) && !model.customImages.contains { $0.slug.lowercased() == newImageID.lowercased() }
    }

    @ViewBuilder
    private var startFromDistro: some View {
        if installedDistros.isEmpty {
            Text("Install a distro first - its files are what the new image starts from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Copies an installed distro into Custom Images as your own image. The copy is instant and takes no extra space until it changes, and it already has everything MSL needs inside.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("From", selection: $newImageSource) {
                        ForEach(installedDistros, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(maxWidth: 180)
                    TextField("my-image", text: $newImageID)
                        .textFieldStyle(.roundedBorder)
                    Button(creatingImage ? "Copying…" : "Create Image") {
                        creatingImage = true
                        model.startCustomImage(id: newImageID, name: newImageID, from: newImageSource) { image in
                            creatingImage = false
                            if let image {
                                distro = image.distro
                                newImageID = ""
                                showingStartFromDistro = false
                            }
                        }
                    }
                    .disabled(!newImageIDIsValid || creatingImage)
                }
                if !newImageID.isEmpty, !newImageIDIsValid {
                    Text(CustomImage.isValidSlug(newImageID)
                         ? "There's already an image called \(newImageID)."
                         : "Letters, digits, - and _ - it becomes the folder name.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var validationMessage: String {
        if name.isEmpty { return "Letters, digits, hyphens and underscores." }
        if nameIsTaken { return "There's already an instance called \(name)." }
        if !nameIsValid { return "Use letters, digits, hyphens and underscores only." }
        return "Letters, digits, hyphens and underscores."
    }

    private func create() {
        guard canCreate else { return }
        model.create(name: name, distro: distro)
        dismiss()
    }
}

private struct DistroChoice: View {
    let distro: GuestDistro
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            DistroBadge(distro: distro, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(distro.displayName)
                Text(distro.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .choiceBackground(isSelected: isSelected)
    }
}

/// One custom image, with what's wrong with it when something is. An image
/// with problems stays visible - hiding it would leave someone wondering
/// why the folder they just made does nothing.
private struct CustomImageChoice: View {
    let image: CustomImage
    let isSelected: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            DistroBadge(distro: image.distro, size: 30)
                .opacity(image.isUsable ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(image.name)
                    Text(image.distro.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if let summary = image.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(image.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(image.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: reveal) {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(Design.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .choiceBackground(isSelected: isSelected)
    }
}

private extension View {
    func choiceBackground(isSelected: Bool) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    }
}
