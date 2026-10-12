import MSLCore
import SwiftUI

/// The MSL dashboard - the detail pane the "MSL" sidebar root shows instead of
/// a file listing. It turns MSL Files from a Finder work-alike into a window
/// onto the project: how big the Linux disks are, how much room is left, and
/// one click to every place MSL keeps its files. Everything here is read
/// host-side (`MSLStorageInfo`), so it works whether or not a VM is running.
struct MSLDashboardView: View {
    @ObservedObject var files: FilesModel
    let instances: [Instance]

    @State private var info: MSLStorageInfo?
    @State private var logBytes: Int64 = 0
    @State private var logCount = 0
    @State private var daemonUp = true

    /// `info` is normally loaded by the `.task`; it can be injected for
    /// previews and snapshot tests, where `.task` doesn't run.
    init(files: FilesModel, instances: [Instance], info: MSLStorageInfo? = nil) {
        self.files = files
        self.instances = instances
        _info = State(initialValue: info)
    }

    private var theme: FilesTheme { files.theme }

    var body: some View {
        ScrollView { content }
            .task(id: instances.map(\.id)) {
                info = await MSLStorageInfo.gather(instances: instances)
                await refreshLogs()
            }
    }

    /// The scrollable body on its own, so it can be drawn offscreen -
    /// `ImageRenderer` collapses a `ScrollView` to nothing (see
    /// `CardRenderingTests`).
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            header
            if let info {
                summary(info)
                if !info.images.isEmpty { disksSection(info) }
                if !runningGuests.isEmpty { instancesSection }
                locationsSection(info)
                maintenanceSection
                themeSection
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(Design.Spacing.large)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(theme.headerGradient, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text("MSL").font(.largeTitle.weight(.semibold))
                Text("Your Linux machines, and where they live on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // The theme lives here too, since the browser toolbar isn't on
            // screen while the dashboard is. `fixedSize` so the menu is a
            // button, not a bar that stretches and wraps the subtitle.
            ThemePicker(files: files)
                .fixedSize()
                .menuStyle(.borderlessButton)
        }
    }

    // MARK: Summary tiles

    private func summary(_ info: MSLStorageInfo) -> some View {
        HStack(spacing: Design.Spacing.medium) {
            tile("Linux disks", bytes: info.totalAllocated, symbol: "internaldrive",
                 tint: theme.companion,
                 caption: info.images.count == 1 ? "1 image" : "\(info.images.count) images")
            tile("Free on this Mac", bytes: info.hostFreeBytes.map(UInt64.init),
                 symbol: "externaldrive.badge.checkmark", tint: .green,
                 caption: "room to grow")
            tile("Running", count: runningGuests.count, symbol: "bolt.horizontal",
                 tint: theme.companion,
                 caption: runningGuests.count == 1 ? "instance" : "instances")
        }
    }

    private func tile(_ title: String, bytes: UInt64? = nil, count: Int? = nil,
                      symbol: String, tint: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(bytes.map { byteString($0) } ?? count.map(String.init) ?? "--")
                .font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Spacing.medium)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Disks

    private func disksSection(_ info: MSLStorageInfo) -> some View {
        section("Linux disks", "Instances of one distro share a disk image.") {
            VStack(spacing: 10) {
                ForEach(info.images) { image in diskRow(image) }
            }
        }
    }

    private func diskRow(_ image: MSLStorageInfo.DiskImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(image.id).fontWeight(.medium)
                // Dynamic (grows on demand) vs static (preallocated) - the
                // distinction the user asked to see.
                Text(image.isSparse ? "Dynamic" : "Static")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(theme.companion.opacity(0.18)))
                    .foregroundStyle(theme.companion)
                Spacer()
                Text("\(byteString(image.allocated)) used · \(byteString(freeOf(image))) free")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            // A usage bar: how full the Linux disk is.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(theme.companion)
                        .frame(width: max(4, geo.size.width * image.usedFraction))
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                ForEach(image.instances, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Text("of \(byteString(image.capacity))").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                // The authoritative guest view, in a real Terminal, one click.
                if let instance = image.instances.first {
                    Button("Analyze") { files.analyzeGuestDisk(instance: instance) }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(theme.companion)
                        .help("Open Terminal and run df / du inside \(instance)")
                }
                Button("Reveal") { revealInFinder(image.path) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(theme.companion)
            }
        }
        .padding(Design.Spacing.medium)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: Running instances

    private var runningGuests: [FileRoot] { files.roots(in: .linux) }

    private var instancesSection: some View {
        section("Open a Linux filesystem", "Jump straight into a running instance.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(runningGuests) { root in
                    Button { files.goToRoot(id: root.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.name).fontWeight(.medium).lineLimit(1)
                                Text(root.subtitle).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Locations

    private func locationsSection(_ info: MSLStorageInfo) -> some View {
        section("Where MSL keeps things", "Click to open it here; ⌥-click to reveal in Finder.") {
            VStack(spacing: 0) {
                ForEach(Array(info.locations.enumerated()), id: \.element.id) { index, location in
                    if index > 0 { Divider() }
                    locationRow(location)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
        }
    }

    private func locationRow(_ location: MSLStorageInfo.Location) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                revealInFinder(location.path)
            } else {
                files.navigate(to: location.path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: location.symbol)
                    .foregroundStyle(theme.companion).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name).fontWeight(.medium)
                    Text(location.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Design.Spacing.medium)
            .padding(.vertical, 9)
            .opacity(location.exists ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!location.exists)
    }

    // MARK: Maintenance

    /// Housekeeping that otherwise means knowing a path and a terminal: how
    /// MSL's daemon is doing, and the logs.
    private var maintenanceSection: some View {
        section("MSL itself", "The background service, and what it has written down.") {
            VStack(spacing: 0) {
                daemonRow
                Divider()
                logsRow
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
        }
    }

    private var daemonRow: some View {
        HStack(spacing: 10) {
            Image(systemName: daemonUp ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(daemonUp ? Color.green : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Background service").fontWeight(.medium)
                Text(daemonUp
                     ? "Running. This is what keeps your instances going."
                     : "Not running. Instances cannot start until it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, 9)
    }

    private var logsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(theme.companion).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Logs").fontWeight(.medium)
                Text(logBytes == 0
                     ? "Nothing written yet."
                     : "\(Uninstaller.format(UInt64(max(0, logBytes)))) across \(logCount) file\(logCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { revealInFinder(MSLPaths.logsDirectory.path) }
                .buttonStyle(.link)
            Button("Clear") { clearLogs() }
                .buttonStyle(.link)
                .disabled(logBytes == 0)
        }
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, 9)
    }

    private func clearLogs() {
        // Truncated, not deleted - mslhd holds these open, and an unlinked
        // log means a daemon writing to an inode with no name. See
        // `MSLLogs.clear`.
        Task {
            _ = await Task.detached(priority: .utility) { MSLLogs.clear() }.value
            await refreshLogs()
        }
    }

    /// Off the main actor: `isRunning()` is a real `connect()` and sizing
    /// walks a directory. This is the same mistake the file picker had.
    private func refreshLogs() async {
        let snapshot = await Task.detached(priority: .utility) {
            (MSLLogs.files(), DaemonClient.isRunning())
        }.value
        logBytes = snapshot.0.reduce(0) { $0 + $1.bytes }
        logCount = snapshot.0.count
        daemonUp = snapshot.1
    }

    // MARK: Theme

    private var themeSection: some View {
        section("Theme", "Make MSL Files yours. The default is the Finder look.") {
            ThemeGallery(files: files)
        }
    }

    // MARK: Helpers

    private func section(_ title: String, _ caption: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func freeOf(_ image: MSLStorageInfo.DiskImage) -> UInt64 {
        image.capacity > image.allocated ? image.capacity - image.allocated : 0
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
