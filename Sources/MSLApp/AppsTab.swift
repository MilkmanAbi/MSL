import MSLCore
import SwiftUI

/// The instance's Linux applications: the feature the whole app is built
/// around. Each one can be opened, added to the Applications folder as a
/// real macOS app, or pinned to the Dock.
struct AppsTab: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var search = ""
    @State private var filter = AppFilter()
    @State private var showingFilter = false

    /// Which packaging systems this instance actually has apps from. A
    /// plain distro with no Flatpak or Snap has nothing to choose between,
    /// so the popover simply does not offer the choice.
    private var availableSources: [AppSource] {
        let present = Set(model.apps(for: instance).map(\.source))
        return [.system, .user, .flatpak, .snap].filter { present.contains($0) }
    }

    private var sourceCounts: [AppSource: Int] {
        Dictionary(grouping: model.apps(for: instance), by: \.source).mapValues(\.count)
    }

    private var apps: [LinuxApp] {
        // MSL Files is offered in every instance, scanned or not: it is the
        // file browser for this side of the boundary, and an instance whose
        // catalog has never been built should still have a way to open it.
        // Added here rather than to the catalog so nothing synthetic is ever
        // written to the cache on disk.
        var all = [LinuxApp.mslFiles()] + model.apps(for: instance)
        if let source = filter.source { all = all.filter { $0.source == source } }
        if filter.installedOnly { all = all.filter { model.isBundleInstalled($0, in: instance) } }
        if filter.pinnedOnly { all = all.filter { model.isPinned($0, in: instance) } }
        if !search.isEmpty {
            all = all.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.comment?.localizedCaseInsensitiveContains(search) ?? false)
                    // So typing "flatpak" or "snap" narrows to that packaging.
                    || $0.source.label.localizedCaseInsensitiveContains(search)
            }
        }
        let sorted: [LinuxApp]
        switch filter.sort {
        case .name:
            sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .source:
            sorted = all.sorted {
                $0.source == $1.source
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.source.label < $1.source.label
            }
        }
        // Apps pinned to the top come first, in the same order among
        // themselves; everything else keeps the chosen sort.
        let pinned = sorted.filter { model.isPinnedToTop($0, in: instance) }
        return pinned + sorted.filter { !model.isPinnedToTop($0, in: instance) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            toolbar

            if model.isScanning(instance) {
                scanningState
            } else if model.apps(for: instance).isEmpty {
                emptyState
            } else if apps.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                grid
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Design.Spacing.medium) {
            if !model.apps(for: instance).isEmpty {
                TextField("Search \(model.apps(for: instance).count) apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                filterButton
            }
            Spacer()
            if let scanned = LinuxAppCatalog.lastScanned(instance: instance.name), !model.isScanning(instance) {
                Text("Updated \(scanned.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.scanApps(instance)
            } label: {
                Label(model.apps(for: instance).isEmpty ? "Find Apps" : "Refresh",
                      systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning(instance))
            .help("Reads the instance's installed applications. Starts it first if it isn't running.")
        }
    }

    /// One button instead of a row of chips that grew with every packaging
    /// system MSL learned to read. It carries a count when something is on,
    /// because a filter nobody can see looks like a missing app.
    private var filterButton: some View {
        Button {
            showingFilter = true
        } label: {
            HStack(spacing: Design.Spacing.tight) {
                Image(systemName: filter.isActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                Text("Filter")
                if filter.activeCount > 0 {
                    Text("\(filter.activeCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                }
            }
        }
        .help(filter.summary.map { "Showing: \($0)" } ?? "Narrow this list by where an app came from")
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            AppFilterPopover(filter: $filter,
                             availableSources: availableSources,
                             counts: sourceCounts,
                             total: model.apps(for: instance).count)
        }
    }

    private var grid: some View {
        LazyVGrid(
            // Fixed, not adaptive-with-a-range: a tile that stretches to
            // fill the row makes neighbouring tiles different widths, and
            // the icons stop lining up. Every tile is the same box now, and
            // the row just fits as many as it can.
            columns: [GridItem(.adaptive(minimum: AppTile.width, maximum: AppTile.width),
                               spacing: Design.Spacing.medium)],
            spacing: Design.Spacing.medium
        ) {
            ForEach(apps) { app in
                AppTile(app: app, instance: instance)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: Design.Spacing.medium) {
            ProgressView()
            Text(model.scanStatus[instance.name] ?? "Reading applications…")
                .foregroundStyle(.secondary)
            Text("Starting an instance for the first time can take a moment.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No applications yet", systemImage: "square.grid.2x2")
        } description: {
            if let progress = model.installing[instance.distro] {
                InstallProgressView(status: progress,
                                    transfer: model.installTransfer[instance.distro],
                                    onCancel: { model.cancelInstall(instance.distro) })
            } else {
                Text(instance.isInstalled
                     ? "MSL reads the apps installed inside \(instance.name). This starts the instance if it isn't already running."
                     : instance.distro.isCustom
                     ? "The \(instance.distro.displayName) image's disk is missing from Custom Images, so \(instance.name) can't start."
                     // "shared by every instance" was true when they all
                     // booted one image. They each get their own copy now;
                     // what is shared is the *download*, which is the part
                     // worth saying - it happens once, however many
                     // instances of it you end up making.
                     : "\(instance.distro.displayName) hasn't been downloaded yet. MSL can fetch it now - a one-time download of a few hundred megabytes. Every \(instance.distro.displayName) instance you make afterwards is created from it instantly, with its own separate copy.")
            }
        } actions: {
            if instance.isInstalled {
                Button("Find Apps") { model.scanApps(instance) }
                    .buttonStyle(.borderedProminent)
            } else if instance.distro.isCustom {
                Button("Show Image Folder") { model.openCustomImagesFolder() }
                    .buttonStyle(.borderedProminent)
            } else if !model.isInstalling(instance.distro) {
                Button("Install \(instance.distro.displayName)") {
                    model.installDistro(instance.distro)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

/// One app: icon, name, and the actions that turn it into a macOS app.
///
/// The actions appear on hover rather than permanently - a grid of 60 apps
/// each showing three buttons is unreadable, and the icon is what the user
/// is scanning for.
/// Internal rather than private so `CardRenderingTests` can draw one:
/// tile geometry is exactly the kind of thing that only breaks visually.
struct AppTile: View {
    /// The one size every tile is. Wide enough for a 56pt icon with room
    /// for a name either side of it, narrow enough that a full-screen
    /// window still shows a useful number of columns.
    static let width: CGFloat = 148
    static let height: CGFloat = 156

    @EnvironmentObject private var model: AppModel
    let app: LinuxApp
    let instance: Instance

    @State private var hovering = false
    @State private var editingCommand = false
    @State private var draftCommand = ""

    /// Scales with the user's text size so the reserved badge row cannot
    /// clip its own label at larger Dynamic Type settings.
    @ScaledMetric(relativeTo: .caption2) private var badgeHeight: CGFloat = 14

    private var isInstalled: Bool { model.isBundleInstalled(app, in: instance) }

    /// The source, plus the app's own graphics choice when it has one - a
    /// setting that changes how an app runs shouldn't be invisible.
    private var badgeText: String {
        let mode = model.graphicsMode(for: app, in: instance)
        return mode.shortLabel.map { "\(app.source.label) · \($0)" } ?? app.source.label
    }

    var body: some View {
        VStack(spacing: Design.Spacing.small) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: model.icon(for: app, in: instance))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .padding(Design.Spacing.small)

                if model.isPreparingIcon(app, in: instance) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Fetching a higher-resolution icon from \(instance.name)…")
                } else if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .help("In your Applications folder")
                }
            }
            .overlay(alignment: .topLeading) {
                if model.isPinnedToTop(app, in: instance) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(35))
                        .help("Pinned to the top of this list")
                }
            }

            MarqueeText(text: app.name, isActive: hovering)
                .frame(width: Self.width - 2 * Design.Spacing.small)

            // Every app is labelled, not just the Flatpaks and Snaps. A
            // tag on some tiles and not others made the grid read as
            // uneven - the eye follows the tags, not the names - and
            // "System" and "User" are worth knowing anyway.
            Text(badgeText)
                .font(.caption2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
                .frame(height: badgeHeight)

            actions
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, Design.Spacing.small)
        .padding(.horizontal, Design.Spacing.small)
        // Fixed on both axes. Before this, a two-line name or a source tag
        // made a tile taller than its neighbours, so rows of icons sat at
        // visibly different heights and the grid looked broken.
        .frame(width: Self.width, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.launch(app, in: instance) }
        .help(app.comment ?? app.command)
        .accessibilityLabel(app.qualifiedName)
        .sheet(isPresented: $editingCommand) {
            CustomCommandSheet(
                appName: app.qualifiedName,
                originalCommand: app.command,
                draft: $draftCommand,
                hasOverride: model.customCommand(for: app, in: instance) != nil,
                onSave: { model.setCustomCommand(draftCommand, for: app, in: instance) },
                onReset: { model.setCustomCommand(nil, for: app, in: instance) })
        }
        .contextMenu {
            Button("Open") { model.launch(app, in: instance) }
            // MSL Files gets "Open" and nothing else. "Add to Launchpad"
            // would generate a macOS bundle called MSL Files that shadows the
            // real app; a Dock pin would be a second tile for an app that
            // already has one; and the graphics options are for X11 clients,
            // which it is not.
            if !app.isMSLFiles {
            Divider()
            // "Launchpad", because that's where people look for it; what it
            // does is put a real app in ~/Applications, which is also what
            // makes Spotlight find it.
            if isInstalled {
                Button("Remove from Launchpad") { model.removeFromApplications(app, in: instance) }
            } else {
                Button("Add to Launchpad") { model.addToApplications(app, in: instance) }
            }
            Button(model.isPinned(app, in: instance) ? "Remove from Dock" : "Add to Dock") {
                model.togglePin(app, in: instance)
            }
            Button(model.isPinnedToTop(app, in: instance) ? "Unpin" : "Pin to Top") {
                model.togglePinToTop(app, in: instance)
            }
            Divider()
            graphicsMenu
            Button(model.customCommand(for: app, in: instance) == nil
                   ? "Custom Launch Command…" : "Edit Launch Command…") {
                draftCommand = model.customCommand(for: app, in: instance) ?? app.command
                editingCommand = true
            }
            // Disabled with its reason rather than hidden, so the person
            // learns the rule exists instead of wondering where the menu
            // item went.
            .disabled(!model.allows("apps.customCommand", in: instance))
            .help(model.adminReason("apps.customCommand", in: instance) ?? "")
            Divider()
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.command, forType: .string)
            }
            Button("Copy Launch Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("msl \(instance.name) \(app.command)", forType: .string)
            }
            Button("Refresh This List") { model.scanApps(instance) }
                .disabled(model.isScanning(instance))
            Divider()
            // What the .desktop entry actually runs, so a misbehaving app can
            // be tried by hand in a shell.
            Text(app.command)
            }
        }
    }

    /// Where this app's OpenGL runs - see `AppGraphicsMode` for why it's a
    /// per-app choice. Applies from the app's next launch.
    private var graphicsMenu: some View {
        let current = model.graphicsMode(for: app, in: instance)
        let defaultLabel = model.gpuIsDefault && model.gpuRendererInstalled ? "GPU" : "CPU"
        // Plain buttons with a checkmark, not an inline Picker: a Picker in
        // a context menu is rebuilt on every model refresh (every 3 s), and
        // the open menu flickered in and out while you looked at it.
        // No tooltip: on a menu item it opens right over the submenu.
        return Menu("Graphics") {
            Section("Applies the next time it opens") {
                graphicsItem("Default (\(defaultLabel))", .automatic, current)
                graphicsItem("GPU · faster, OpenGL 4.1", .gpu, current)
                    .disabled(!model.gpuRendererInstalled)
                graphicsItem("CPU · OpenGL 4.5, for Blender & co.", .cpu, current)
            }
        }
    }

    private func graphicsItem(_ title: String, _ mode: AppGraphicsMode, _ current: AppGraphicsMode) -> some View {
        Button {
            model.setGraphicsMode(mode, for: app, in: instance)
        } label: {
            if mode == current { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var actions: some View {
        HStack(spacing: Design.Spacing.tight) {
            TileButton(symbol: "play.fill", help: "Open \(app.name)") {
                model.launch(app, in: instance)
            }
            TileButton(
                symbol: isInstalled ? "folder.fill.badge.minus" : "folder.badge.plus",
                help: isInstalled ? "Remove from your Applications folder" : "Add to your Applications folder"
            ) {
                if isInstalled {
                    model.removeFromApplications(app, in: instance)
                } else {
                    model.addToApplications(app, in: instance)
                }
            }
            TileButton(
                symbol: model.isPinned(app, in: instance) ? "pin.slash.fill" : "pin.fill",
                help: model.isPinned(app, in: instance) ? "Unpin from the Dock" : "Pin to the Dock"
            ) {
                model.togglePin(app, in: instance)
            }
        }
    }
}

private struct TileButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
