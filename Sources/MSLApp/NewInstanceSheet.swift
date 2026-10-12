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
    /// Held so the disclosure below can scroll what it opens into view.
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingShipmentInfo = false

    /// What the "start from a distro" disclosure scrolls to when it opens.
    private static let startFromDistroAnchor = "start-from-distro"

    /// `CLICommands`, not `InstanceRegistry.isValidName`: the characters
    /// *and* the words a command already owns. An instance called `run`
    /// could never be opened with `msl run` again.
    private var nameIsValid: Bool { CLICommands.isAvailableName(name) }
    private var nameRefusal: String? { name.isEmpty ? nil : CLICommands.nameRefusal(name) }
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
                // Instances used to share their distro's disk, so this said
                // only one of them could run at a time. Each has its own
                // disk now (`InstanceDisk`), so a second instance of a
                // distro really is a second machine - and they run together.
                Text("An instance is one Linux machine with its own name. Each gets its own copy of the distribution, so several can run at once without touching each other's files.")
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

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.large) {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Distribution").font(.subheadline).bold().foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Design.Spacing.small)],
                                  spacing: Design.Spacing.small) {
                            ForEach(GuestDistro.allCases, id: \.self) { candidate in
                                DistroChoice(
                                    distro: candidate,
                                    isSelected: candidate == distro,
                                    isDownloaded: DistroInstallation.isInstalled(candidate),
                                    instanceCount: model.instances.filter { $0.distro == candidate }.count)
                                    .onTapGesture { distro = candidate }
                            }
                        }
                    }

                    customImagesSection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 460)
            .onAppear { scrollProxy = proxy }
            }

            // **Always something here, never a hole.** This used to appear
            // only for a distro that still needed downloading, so selecting
            // one you already had emptied the space and the whole sheet
            // jumped - which reads as a glitch rather than as good news.
            if !distro.isCustom {
                Label(distroStatus.text, systemImage: distroStatus.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Room for the longest of the three, so moving between
                    // them does not resize the sheet under the pointer.
                    .frame(minHeight: 36, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                // A shipment arrives with its own disk, so it installs even
                // on a Mac that has never downloaded that distribution -
                // which is why this sits beside "Create" rather than inside
                // the distro picker above.
                if model.shipping.contains("") {
                    HStack(spacing: Design.Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text(model.shipmentStatus[""] ?? "installing…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Install MSL Shipment…") {
                        model.installShipment()
                        dismiss()
                    }
                    .help("Install an instance someone packaged with MSL, from a .mslship file")
                    // A button with a popover, not `.help()`: that is a hover
                    // tooltip, and an ⓘ that does nothing when clicked reads
                    // as broken.
                    Button {
                        showingShipmentInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("What is a shipment?")
                    .popover(isPresented: $showingShipmentInfo, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: Design.Spacing.small) {
                            Text("MSL Shipments").font(.headline)
                            Text("A shipment is a whole instance in one file: the applications, the files, your Linux account and the settings it was running.")
                            Text("Someone packages their instance, sends you the .mslship, and it installs here as a working machine - even if you have never downloaded that distribution.")
                            Text("Its experimental settings apply to that one instance, never to the rest of MSL.")
                                .foregroundStyle(.secondary)
                            Divider()
                            Text("A shipment is a complete Linux system someone else assembled. Install ones you trust.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(Design.Spacing.large)
                        .frame(width: 330)
                    }
                }
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
                    .id(Self.startFromDistroAnchor)
            }
            .font(.callout)
            // What it opens is below the fold, so without this the sheet
            // looked unchanged and the disclosure looked broken. After the
            // layout pass, or there is nothing to scroll to yet.
            .onChange(of: showingStartFromDistro) { _, expanded in
                guard expanded else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy?.scrollTo(Self.startFromDistroAnchor, anchor: .bottom)
                    }
                }
            }
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
        // The refusal itself, so "run is an msl command" doesn't come back as
        // "use letters, digits, hyphens and underscores only" - which is both
        // wrong and impossible to act on.
        if let refusal = nameRefusal { return refusal + "." }
        return "Letters, digits, hyphens and underscores."
    }

    /// What to say about the selected distribution.
    ///
    /// Three genuinely different situations, and conflating them is what made
    /// this confusing: a distro MSL has never downloaded, one it has, and one
    /// it has *and already runs instances of*. The last is the one worth
    /// spelling out, because "I already have Arch" invites the assumption
    /// that a second Arch instance is somehow the same machine - and it is
    /// not. Each instance is its own complete system (`InstanceDisk`).
    private var distroStatus: (text: String, symbol: String) {
        let siblings = model.instances
            .filter { $0.distro == distro }
            .map(\.name)
            .sorted()

        guard isInstalled else {
            // Non-breaking spaces inside the code span: left to wrap, it
            // broke between "install" and the distro name and read as a
            // stray gap in the sentence.
            return ("\(distro.displayName) isn't downloaded yet. Creating the instance is instant, but it can't start until MSL has the image - run `msl\u{00A0}install\u{00A0}\(distro.rawValue)`, or use Install \(distro.displayName) from the instance's menu.",
                    "arrow.down.circle")
        }
        guard !siblings.isEmpty else {
            return ("\(distro.displayName) is already downloaded, so this is instant - MSL keeps the image and gives every instance its own copy of it.",
                    "checkmark.circle")
        }
        let named = siblings.count <= 3
            ? siblings.joined(separator: ", ")
            : "\(siblings.prefix(2).joined(separator: ", ")) and \(siblings.count - 2) more"
        return ("\(distro.displayName) is already downloaded, so this is instant. It will be a brand-new \(distro.displayName) system - nothing is shared with \(named), and they can all run at the same time.",
                "checkmark.circle")
    }

    private func create() {
        guard canCreate else { return }
        model.create(name: name, distro: distro)
        dismiss()
    }
}

/// Internal rather than private so `CardRenderingTests` can measure one:
/// "CentOS Stream" wrapping made its card taller than the rest of the grid,
/// and nothing but a real render catches that.
struct DistroChoice: View {
    let distro: GuestDistro
    let isSelected: Bool
    /// Whether MSL already has this distribution's image.
    let isDownloaded: Bool
    /// How many instances of it already exist.
    let instanceCount: Int

    var body: some View {
        // One line: badge, name, and what MSL already has. No blurb.
        //
        // It used to carry `distro.blurb` underneath, which at this width
        // was always truncated - "Enterprise Lin…", "Debian, with m…" - so
        // it cost every card a second line and told nobody anything. The
        // names are the information here.
        //
        // One line also makes every card the same height for free, which is
        // what the grid needs: `LazyVGrid` sizes a whole row to its tallest
        // item, so a card that wrapped put a visible step in the layout.
        HStack(spacing: Design.Spacing.small) {
            DistroBadge(distro: distro, size: 26)
            Text(distro.displayName)
                .lineLimit(1)
                // A safety net only: every name fits at full size now that
                // the count is gone (the longest, "CentOS Stream", is 94pt
                // in a 100pt column). The floor is here so a longer name in
                // a future distro shrinks rather than losing its tail.
                .minimumScaleFactor(0.8)
            Spacer(minLength: Design.Spacing.tight)
            // Only the tick. The instance count used to sit here too, and
            // the few points it took were the difference between "CentOS
            // Stream" fitting and being cut to "CentOS Str…". It is already
            // said in full in the line under the grid ("nothing is shared
            // with Milk, Test1"), where there is room for it.
            Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(isDownloaded ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .help(isDownloaded ? "Downloaded - a new instance is instant" : "Not downloaded yet")
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
