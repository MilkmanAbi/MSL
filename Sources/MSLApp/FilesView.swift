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
    @StateObject private var files: FilesModel
    /// Which window this view is in, so a link can tell a real window from
    /// the hidden one prewarming leaves behind. See `consumeLink`.
    @StateObject private var hostWindow = HostWindowBox()

    /// A bar across the bottom of the window. The file picker puts its
    /// "Save as" field and Cancel/Open buttons here, which is the whole
    /// reason this view is reusable: a Linux app's Open dialog is this
    /// browser plus two buttons, not a second browser written from scratch.
    private let accessory: AnyView?
    /// The asking app's own dialog title ("Save As", "Open Image"), which
    /// should win over the folder name a normal window shows.
    private let titleOverride: String?

    /// An ordinary MSL Files window, owning its own model.
    init() {
        _files = StateObject(wrappedValue: FilesModel())
        accessory = nil
        titleOverride = nil
    }

    /// The same browser driven by someone else's model, with a bar along the
    /// bottom - what the file picker uses.
    ///
    /// The model is passed in because the picker has to configure it before
    /// the view appears (select the instance, walk to the folder the app
    /// asked for) and read the selection back when a button is pressed.
    init(files: FilesModel, title: String?, @ViewBuilder accessory: () -> some View) {
        _files = StateObject(wrappedValue: files)
        self.accessory = AnyView(accessory())
        titleOverride = title
    }

    /// True when this is a picker rather than a window in its own right.
    private var isPicker: Bool { accessory != nil }

    /// Takes the pending link, if this window is the one that gets it.
    /// Whether this window has been on screen before. A link held for a new
    /// window is only ever given to a window appearing for the first time.
    @State private var hasAppearedBefore = false

    private func consumeLink(firstAppearance: Bool = false) {
        // Never in a picker: a reveal meant for a real MSL Files window must
        // not be swallowed by a dialog that is about to close, which would
        // lose it entirely.
        guard !isPicker else { return }
        // Nor in the hidden window prewarming left behind: it is alive and
        // listening with nothing on screen, so it used to take the link and
        // navigate invisibly, leaving the window that opened a moment later
        // on the MSL tab. See `NSWindow.isWithdrawnPrewarm`.
        if hostWindow.window?.isWithdrawnPrewarm == true { return }
        guard let url = MSLFilesLink.take(firstAppearance: firstAppearance) else { return }
        if files.reveal(url) { Task { await model.refresh() } }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            if let accessory {
                Divider()
                accessory
            }
        }
        // Layer 1, the base: the window's own appearance (System / Light /
        // Dark / Darker). Set on the NSWindow so sheets and menus agree.
        .preferredColorScheme(files.appearance.colorScheme)
        .background(WindowAppearance(appearance: files.appearance.nsAppearance))
        // Layer 2, the highlight: tints selection, focused controls and the
        // toolbar. `nil` keeps the system accent (Finder).
        .tint(files.theme.accent)
        // Published from the top of the window, not the browser: while the MSL
        // dashboard showed, the menu bar couldn't see the model at all, so the
        // Go menu, Go to Folder (⇧⌘G) and every File command went dead there.
        .focusedSceneObject(files)
        // Arrow keys move the selection in every view mode (shift extends).
        // An AppKit key monitor rather than `.keyboardShortcut`: SwiftUI
        // matched a plain arrow to the shift-registered shortcut, so every
        // arrow press extended the selection.
        .background(ArrowKeyMonitor(files: files))
        .readsHostWindow(into: hostWindow)
        .environment(\.filesFolderTint, files.tintFolderArea ? files.theme.muted : nil)
        .environment(\.filesCustomBackdrop, files.usesCustomBackdrop)
        .navigationTitle(titleOverride
                         ?? (files.isShowingDashboard ? "MSL" : (files.breadcrumbs.last?.name ?? "MSL Files")))
        .onAppear { files.rebuildRoots(from: model.instances) }
        // Links come from `MSLFilesLink`, not SwiftUI's `onOpenURL`: routing
        // them through SwiftUI opened a second window on a cold launch. The
        // instance's mount may be newer than this window's list of roots, so
        // the reveal waits for the refresh if it has to.
        .onAppear {
            // Only the first appearance counts as a new window: SwiftUI
            // calls this again when a window comes back to the front, and a
            // window being re-shown must not take a link meant for a new one.
            let isNew = !hasAppearedBefore
            hasAppearedBefore = true
            consumeLink(firstAppearance: isNew)
        }
        .onReceive(NotificationCenter.default.publisher(for: MSLFilesLink.didArrive)) { _ in consumeLink() }
        .onChange(of: model.instances) { _, new in files.rebuildRoots(from: new) }
        .sheet(item: $files.quickLookTarget) { target in
            QuickLookSheet(item: target.item, files: files) { files.quickLookTarget = nil }
        }
        .sheet(item: $files.editorTarget) { target in
            FileTextEditorSheet(target: target) { files.editorTarget = nil }
        }
        .sheet(item: $files.infoTarget) { item in
            FileInfoSheet(item: item, files: files) { files.infoTarget = nil }
        }
        .sheet(item: $files.gitTarget) { target in
            GitPanel(path: target.path, folderName: target.name, files: files) {
                files.gitTarget = nil
                // Whatever was done in there may have changed the dots.
                files.refreshGitBadges()
            }
        }
        // Editing a file *inside* a repository does not change the listing
        // that contains it, so navigation alone would never notice. Coming
        // back to the window is the moment that matters: somebody worked in a
        // terminal or an editor and returned. Deliberately not a timer -
        // every pass is a guest command, and polling would keep an idle
        // instance from ever suspending.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            files.refreshGitBadges()
        }
        .sheet(isPresented: $files.goToFolderPresented) {
            GoToFolderSheet(files: files)
        }
        .sheet(isPresented: Binding(
            get: { !files.powerRenameTargets.isEmpty },
            set: { if !$0 { files.powerRenameTargets = [] } })
        ) {
            PowerRenameSheet(files: files, paths: files.powerRenameTargets)
        }
        .background(shortcuts)
        // Track when a text field (search, rename, Go-to-Folder) is being
        // edited, so the bare-key file shortcuts can stand aside for it. The
        // field editor posts these for every `NSTextField`/`NSSearchField` in
        // the window, which is exactly the set we want to yield to.
        .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidBeginEditingNotification)) { _ in
            files.isEditingText = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in
            files.isEditingText = false
        }
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

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if files.isShowingDashboard {
            MSLDashboardView(files: files, instances: model.instances)
        } else if files.selectedRoot == nil {
            ContentUnavailableView {
                Label("Nothing to browse", systemImage: "folder")
            } description: {
                Text("Start an instance to see its Linux filesystem here.")
            }
        } else {
            browser
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
        // Darker replaces the translucent sidebar material with a deep solid,
        // matching the folder area; every other appearance keeps the system
        // sidebar.
        .scrollContentBackground(files.appearance == .darker ? .hidden : .automatic)
        .background(files.appearance == .darker ? FolderBackdrop.darkerSidebar : Color.clear)
    }

    private func rootRow(_ root: FileRoot) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(root.name).lineLimit(1)
                // A lock belongs only on a real read-only directory - not on a
                // saved search (nothing about it is "read-only" like a volume)
                // and not on the MSL dashboard (which isn't a place at all).
                if root.readOnly, root.kind == .directory {
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
                    .foregroundStyle(root.isGuest ? Color.orange : files.theme.selection)
            }
        }
        .help(root.subtitle)
        // Re-clicking the root you're already inside returns to its top, as
        // Finder does. The gesture is masked off (`.subviews`) on every row
        // except the selected one: a tap gesture on all of them competed with
        // the List's own selection, which made clicking to *switch* roots
        // laggy and sometimes eat the click after a text field had focus. Only
        // the already-selected row needs it, and that's the row you re-click.
        .simultaneousGesture(
            TapGesture().onEnded { files.returnToTop(root) },
            including: root.id == files.selectedRoot?.id ? .all : .subviews)
        // Dropping onto a sidebar row does what the row is: a tag gets
        // applied, the way Finder's sidebar tags do, and a place takes the
        // files. Dragging something to Downloads or to an instance without
        // first navigating there is most of what a sidebar is for.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            switch root.kind {
            case .tag(let name):
                FileDropTarget.loadFileURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    files.toggleTag(name, on: Set(urls.map(\.path)))
                }
                return true
            case .directory:
                guard !root.readOnly else { return false }
                FileDropTarget.loadFileURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    files.receive(urls, into: root.path)
                }
                return true
            default:
                // Recents and the dashboard are not places files can go.
                return false
            }
        }
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            if files.showPathBar {
                pathBar
                Divider()
            }
            // The background menu goes on the content area, not the whole
            // window: right-clicking a row must still get the row's own menu,
            // and SwiftUI gives the innermost one.
            content
                .fileBackgroundMenu(files)
            if files.showStatusBar {
                Divider()
                statusBar
            }
        }
        // The whole window, in AppKit: SwiftUI's List answers drags over its
        // own empty space and never passes them out. See `FileDropCatcher`.
        .background(
            FileDropCatcher(destination: { files.canWrite ? files.currentPath : nil },
                            folderUnderPoint: { files.dropFolder(at: $0) },
                            receive: { urls, destination in
                                files.receive(urls, into: destination)
                            })
        )
        .toolbar { toolbarContent }
        // `.searchable` rather than a `TextField` in a `ToolbarItem`: the
        // toolbar drops items it has no room for, and a hand-rolled field
        // is the first thing to go - it vanished entirely at the window's
        // default width. This one collapses to the standard magnifying
        // glass instead, and comes with ⌘F for free.
        .searchable(text: $files.search, placement: .toolbar, prompt: "Search")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // These are toolbar affordances only; their key equivalents are owned
        // by `FilesCommands` (the Go menu, ⌘↓ Open) so they register exactly
        // once. A key equivalent on a toolbar button *and* the menu fires the
        // action twice.
        ToolbarItemGroup(placement: .navigation) {
            Button { files.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!files.canGoBack)
                .help("Back (⌘[)")
            Button { files.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!files.canGoForward)
                .help("Forward (⌘])")
            Button { files.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(files.path.isEmpty)
                .help("Enclosing folder (⌘↑)")
            Button { openSelection() } label: { Image(systemName: "arrow.down.forward.square") }
                .disabled(files.selection.isEmpty)
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

        ToolbarItem { ThemePicker(files: files) }

        ToolbarItemGroup {
            Button { files.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!files.canWrite)
                .help(files.canWrite ? "New folder (⇧⌘N)" : "This location is read-only")
            // The eye toggles hidden files, for Mac and Linux roots alike
            // (`showHidden` filters every root). A real `Toggle` in `.button`
            // style, not a tinted `Button`: a toolbar draws the button style's
            // on-state as a filled highlight (and ignores `foregroundStyle`),
            // so "on" actually looks pressed the way the ask wanted. Open eye
            // when showing everything, slashed eye when hiding. Quick Look
            // lives on the space bar and in the right-click menu now.
            Toggle(isOn: $files.showHidden) {
                Image(systemName: files.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(files.showHidden
                  ? "Showing hidden files - click to hide them (⇧⌘.)"
                  : "Hidden files are hidden - click to show them (⇧⌘.)")
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
                .help("Move to Trash (⌘⌫)")
        }

    }

    /// The bare-key and Edit-style file shortcuts, as zero-sized buttons -
    /// the supported way to register a key equivalent in SwiftUI without a
    /// visible control. Only the ones `FilesCommands` does *not* already own
    /// live here (⌘D, ⌘I and the navigation keys are the menu's, registered
    /// once): a key equivalent in two places fires twice.
    ///
    /// Every one of these is a key macOS also gives to a focused text field -
    /// ⌘C/⌘V to copy and paste text, Space to type a space, Return to commit -
    /// so each disables itself while `isEditingText`. A *disabled* button
    /// yields its key equivalent instead of consuming it, so the keystroke
    /// falls through to the search field, the rename field or the Go-to-Folder
    /// sheet where it belongs.
    private var shortcuts: some View {
        Group {
            // ⌘C / ⌘V: the `isEditingText` disable hands the keystroke to a
            // field once it is *actively editing*. But a field that has focus
            // and a selection but hasn't been typed into yet doesn't count as
            // editing, so these also forward to the field editor at action
            // time - copying the selected *text*, not the selected files.
            Button("") {
                if let text = NSApp.keyWindow?.firstResponder as? NSText { text.copy(nil); return }
                files.copyToPasteboard(files.selection)
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(files.selection.isEmpty || files.isEditingText)
            Button("") {
                if let text = NSApp.keyWindow?.firstResponder as? NSText { text.paste(nil); return }
                files.pasteFromPasteboard()
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!files.canWrite || files.isEditingText)
            // ⌘↓ opens the selection, the second Finder way to open (⌘O is the
            // other, owned by FilesCommands). Guarded because ⌘↓ moves to
            // end-of-text in a field.
            Button("") { openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(files.selection.isEmpty || files.isEditingText)
            // Space is Quick Look, as in Finder - owned here rather than by the
            // toolbar's eye button so it can carry the text-field guard.
            Button("") {
                if let path = files.selection.first { files.quickLook(path: path) }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(files.selection.isEmpty || files.isEditingText || files.renaming != nil)
            // Return renames the selection, as it does in Finder - where
            // Return is *not* "open", which trips up people arriving from
            // Windows but is what Mac muscle memory expects.
            Button("") {
                if let path = files.selection.first { files.renaming = path }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(files.selection.count != 1 || !files.canWrite
                      || files.isEditingText || files.renaming != nil)
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
                    // The folder you're in is drawn in the theme colour (or
                    // plain, under Finder), its ancestors dimmed - so the trail
                    // carries the paint too.
                    let isCurrent = index == files.breadcrumbs.count - 1
                    Button(crumb.name) { files.goTo(crumb.path) }
                        .buttonStyle(.plain)
                        .foregroundStyle(isCurrent
                                         ? AnyShapeStyle(files.theme.accent ?? Color.primary)
                                         : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .fontWeight(isCurrent ? .medium : .regular)
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
        .background { FolderBackdrop(files: files) }
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
            if files.selectedRoot?.readOnly == true, files.selectedRoot?.kind == .directory {
                Label("Read-only", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            // On a Linux root, the real disk figures (a WebDAV mount reports
            // none); on a Mac root, the volume's free space.
            if let guest = files.guestDiskSummary {
                Text(guest).foregroundStyle(.secondary)
            } else if let available = files.availableCapacity, !files.isShowingQueryResults {
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
}
