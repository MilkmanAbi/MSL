import MSLCore
import SwiftUI
import UniformTypeIdentifiers

/// A file browser that can see both sides of MSL.
///
/// It deliberately *is* a Finder work-alike: four view modes, a Favorites
/// and Locations sidebar, sortable columns, Quick Look, back/forward, drag
/// and drop. Finder muscle memory is the whole interface budget most people
/// have for a file browser, so anything that looks like Finder and then
/// behaves differently is worse than not looking like it at all.
///
/// What it adds on top is the part Finder cannot do. Finder *can* reach the
/// guest - the mount is a real volume - but it appears under a loopback IP
/// address with no indication which instance it belongs to, which is why it
/// feels invisible. Here those roots are named, sit beside the Mac's own,
/// and files move across the boundary by dragging.
struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var files = FilesModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if files.selectedRoot == nil {
                ContentUnavailableView {
                    Label("Nothing to browse", systemImage: "folder")
                } description: {
                    Text("Start an instance to see its Linux filesystem here.")
                }
            } else {
                browser
            }
        }
        .navigationTitle(files.breadcrumbs.last?.name ?? "MSL Files")
        .onAppear { files.rebuildRoots(from: model.instances) }
        .onOpenURL { url in
            // The instance's mount may be newer than this window's list of
            // roots; the reveal waits for the refresh if it has to.
            if files.reveal(url) { Task { await model.refresh() } }
        }
        .onChange(of: model.instances) { _, new in files.rebuildRoots(from: new) }
        .sheet(item: $files.quickLookTarget) { target in
            quickLookSheet(target.url)
        }
        .sheet(item: $files.infoTarget) { item in
            FileInfoSheet(item: item, files: files) { files.infoTarget = nil }
        }
        .sheet(isPresented: $files.goToFolderPresented) {
            GoToFolderSheet(files: files)
        }
        .background(shortcuts)
        .confirmationDialog(
            "This volume has no Trash.",
            isPresented: Binding(
                get: { !files.pendingPermanentDelete.isEmpty },
                set: { if !$0 { files.pendingPermanentDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete \(files.pendingPermanentDelete.count) Item\(files.pendingPermanentDelete.count == 1 ? "" : "s") Permanently",
                   role: .destructive) {
                files.confirmPermanentDelete()
            }
            Button("Cancel", role: .cancel) { files.pendingPermanentDelete = [] }
        } message: {
            Text("Deleting here cannot be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { files.selectedRoot?.id },
            set: { id in files.select(files.roots.first { $0.id == id }) })
        ) {
            ForEach(FileRoot.Section.allCases, id: \.self) { section in
                let entries = files.roots(in: section)
                if section == .top {
                    // Finder's Recents sits above the first header, in a
                    // group with no title.
                    ForEach(entries) { rootRow($0).tag($0.id) }
                } else if section == .linux {
                    Section(section.rawValue) {
                        if entries.isEmpty {
                            Text("No running instances")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(entries) { rootRow($0).tag($0.id) }
                        }
                    }
                } else if !entries.isEmpty {
                    Section(section.rawValue) {
                        ForEach(entries) { rootRow($0).tag($0.id) }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210)
    }

    private func rootRow(_ root: FileRoot) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(root.name).lineLimit(1)
                // A lock beside a *tag* would be nonsense - nothing about a
                // saved search is read-only in the way a volume is.
                if root.readOnly, !root.kind.isQuery {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Read-only")
                }
            }
        } icon: {
            if case .tag(let name) = root.kind {
                Circle()
                    .fill(FileTag(name: name,
                                  colorIndex: FileTag.standardColorIndex(for: name)).color ?? .gray)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: root.symbol)
                    .foregroundStyle(root.isGuest ? Color.orange : Color.accentColor)
            }
        }
        .help(root.subtitle)
        // Dropping onto a tag applies it, the way Finder's sidebar tags do.
        .dropDestination(for: URL.self) { urls, _ in
            guard case .tag(let name) = root.kind else { return false }
            files.toggleTag(name, on: Set(urls.map(\.path)))
            return true
        }
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            if files.showPathBar {
                pathBar
                Divider()
            }
            content
            if files.showStatusBar {
                Divider()
                statusBar
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard files.canWrite else { return false }
            files.receive(urls)
            return true
        }
        .toolbar { toolbarContent }
        .focusedSceneObject(files)
        // `.searchable` rather than a `TextField` in a `ToolbarItem`: the
        // toolbar drops items it has no room for, and a hand-rolled field
        // is the first thing to go - it vanished entirely at the window's
        // default width. This one collapses to the standard magnifying
        // glass instead, and comes with ⌘F for free.
        .searchable(text: $files.search, placement: .toolbar, prompt: "Search")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { files.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!files.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
            Button { files.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!files.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])")
            Button { files.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(files.path.isEmpty)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing folder (⌘↑)")
            Button { openSelection() } label: { Image(systemName: "arrow.down.forward.square") }
                .disabled(files.selection.isEmpty)
                .keyboardShortcut(.downArrow, modifiers: .command)
                .help("Open (⌘↓, or double-click)")
        }

        ToolbarItem {
            Picker("View", selection: $files.viewMode) {
                ForEach(FileViewMode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                        .help("View \(mode.label)")
                }
            }
            .pickerStyle(.segmented)
            .help("View mode")
            .disabled(files.isShowingQueryResults)
        }

        ToolbarItem { sortMenu }

        ToolbarItemGroup {
            Button { files.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!files.canWrite)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help(files.canWrite ? "New folder (⇧⌘N)" : "This location is read-only")
            Button {
                if let path = files.selection.first {
                    files.quickLookTarget = QuickLookTarget(url: URL(fileURLWithPath: path))
                }
            } label: { Image(systemName: "eye") }
                .disabled(files.selection.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
                .help("Quick Look (space)")
            ShareLink(items: files.selection.sorted().map { URL(fileURLWithPath: $0) }) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(files.selection.isEmpty)
            .help("Share")
            Menu {
                TagMenuItems(files: files, paths: files.selection,
                             applied: Set(files.visibleItems
                                .filter { files.selection.contains($0.path) }
                                .flatMap { $0.tags.map(\.name) }))
            } label: {
                Image(systemName: "tag")
            }
            .disabled(files.selection.isEmpty)
            .help("Tags")
            Button { files.delete(files.selection) } label: { Image(systemName: "trash") }
                .disabled(files.selection.isEmpty || !files.canWrite)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Move to Trash (⌘⌫)")
        }

    }

    /// Shortcuts with no toolbar button of their own. Zero-sized buttons
    /// are the supported way to register a key equivalent in SwiftUI
    /// without putting a control on screen for it.
    private var shortcuts: some View {
        Group {
            Button("") { files.copyToPasteboard(files.selection) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(files.selection.isEmpty)
            Button("") { files.pasteFromPasteboard() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!files.canWrite)
            Button("") { files.duplicate(files.selection) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(files.selection.isEmpty || !files.canWrite)
            Button("") {
                if let item = files.focusedItem { files.infoTarget = item }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(files.focusedItem == nil)
            // Return renames the selection, as it does in Finder - where
            // Return is *not* "open", which trips up people arriving from
            // Windows but is what Mac muscle memory expects.
            Button("") {
                if let path = files.selection.first { files.renaming = path }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(files.selection.count != 1 || !files.canWrite)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Group by", selection: $files.grouping) {
                ForEach(FileGrouping.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Picker("Sort by", selection: $files.sortKey) {
                ForEach(FileSortKey.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Ascending", isOn: $files.sortAscending)
            Toggle("Keep Folders on Top", isOn: $files.foldersOnTop)
            Divider()
            Toggle("Show Hidden Files", isOn: $files.showHidden)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort and arrange")
    }

    /// Finder's path bar: every ancestor clickable.
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(files.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.name) { files.goTo(crumb.path) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == files.breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, Design.Spacing.medium)
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch files.effectiveViewMode {
            case .icon: FileIconGridView(files: files)
            case .list: FileListView(files: files)
            case .column: FileColumnView(files: files)
            case .gallery: FileGalleryView(files: files)
            }

            if files.loading, files.items.isEmpty {
                ProgressView()
            // Column view has its own empty state: the last column simply
            // shows nothing, with the path that got there still visible
            // beside it. A full-pane overlay would cover that chain.
            } else if !files.loading, files.visibleItems.isEmpty, files.viewMode != .column {
                ContentUnavailableView {
                    Label(files.search.isEmpty ? "Empty folder" : "No matches",
                          systemImage: files.search.isEmpty ? "folder" : "magnifyingglass")
                } description: {
                    if files.search.isEmpty, files.canWrite {
                        Text("Drag files here to copy them in.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack {
            if let error = files.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text(itemCount)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if files.selectedRoot?.readOnly == true, files.selectedRoot?.kind.isQuery == false {
                Label("Read-only", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            if let available = files.availableCapacity, !files.isShowingQueryResults {
                Text("\(available) available").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, 5)
    }

    /// Opens whatever is selected - the one place the "what does opening
    /// mean" decision lives, shared by ⌘↓, the toolbar and the context menu.
    private func openSelection() {
        guard let path = files.selection.first,
              let item = files.visibleItems.first(where: { $0.path == path }) else { return }
        files.open(item)
    }

    private var itemCount: String {
        let total = files.visibleItems.count
        let selected = files.selection.count
        let items = "\(total) item\(total == 1 ? "" : "s")"
        return selected > 1 ? "\(selected) of \(items) selected" : items
    }

    private func quickLookSheet(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { files.quickLookTarget = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Design.Spacing.medium)
            Divider()
            QuickLookPreview(url: url)
                .frame(minWidth: 640, minHeight: 460)
        }
    }
}
