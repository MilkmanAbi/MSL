import MSLCore
import SwiftUI

/// The instance's Linux applications: the feature the whole app is built
/// around. Each one can be opened, added to the Applications folder as a
/// real macOS app, or pinned to the Dock.
struct AppsTab: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var search = ""
    @State private var sourceFilter: AppSource?

    /// Which packaging systems this instance actually has apps from. Only
    /// shown as filter chips when there is more than one - on a plain
    /// distro with no Flatpak or Snap there is nothing to choose between.
    private var availableSources: [AppSource] {
        let present = Set(model.apps(for: instance).map(\.source))
        return [.system, .user, .flatpak, .snap].filter { present.contains($0) }
    }

    private var apps: [LinuxApp] {
        var all = model.apps(for: instance)
        if let sourceFilter { all = all.filter { $0.source == sourceFilter } }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.comment?.localizedCaseInsensitiveContains(search) ?? false)
                // So typing "flatpak" or "snap" narrows to that packaging.
                || $0.source.label.localizedCaseInsensitiveContains(search)
        }
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

                if availableSources.count > 1 {
                    Picker("", selection: $sourceFilter) {
                        Text("All").tag(AppSource?.none)
                        ForEach(availableSources, id: \.self) { source in
                            Text(source.label).tag(AppSource?.some(source))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .help("Same app, packaged twice? This is how to tell them apart.")
                }
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

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132, maximum: 168), spacing: Design.Spacing.medium)],
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
                // The download is minutes of multi-gigabyte transfer, so
                // the live line from the installer is the whole feedback.
                VStack(spacing: Design.Spacing.small) {
                    ProgressView()
                    Text(progress).monospacedDigit()
                }
            } else {
                Text(instance.isInstalled
                     ? "MSL reads the apps installed inside \(instance.name). This starts the instance if it isn't already running."
                     : instance.distro.isCustom
                     ? "The \(instance.distro.displayName) image's disk is missing from Custom Images, so \(instance.name) can't start."
                     : "\(instance.distro.displayName) hasn't been downloaded yet. MSL can fetch it now - it's a one-time download of a few hundred megabytes, shared by every instance using \(instance.distro.displayName).")
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
private struct AppTile: View {
    @EnvironmentObject private var model: AppModel
    let app: LinuxApp
    let instance: Instance

    @State private var hovering = false
    /// Scales with the user's text size so the reserved badge row cannot
    /// clip its own label at larger Dynamic Type settings.
    @ScaledMetric(relativeTo: .caption2) private var badgeHeight: CGFloat = 14

    private var isInstalled: Bool { model.isBundleInstalled(app, in: instance) }

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

            Text(app.name)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)

            // Only non-system sources are labelled: on most instances every
            // app is a system one, and a badge on all of them is noise. It
            // earns its place exactly when the same app appears twice.
            //
            // The row always reserves its height, badge or no badge -
            // otherwise badged tiles are taller than their neighbours and
            // the icons in a row sit at visibly different heights.
            Group {
                if app.source != .system {
                    Text(app.source.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: badgeHeight)

            actions
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, Design.Spacing.small)
        .padding(.horizontal, Design.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.launch(app, in: instance) }
        .help(app.comment ?? app.command)
        .accessibilityLabel(app.qualifiedName)
        .contextMenu {
            Button("Open") { model.launch(app, in: instance) }
            Divider()
            if isInstalled {
                Button("Remove from Applications") { model.removeFromApplications(app, in: instance) }
            } else {
                Button("Add to Applications") { model.addToApplications(app, in: instance) }
            }
            Button(model.isPinned(app, in: instance) ? "Unpin from Dock" : "Pin to Dock") {
                model.togglePin(app, in: instance)
            }
            Divider()
            Text(app.command)
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
