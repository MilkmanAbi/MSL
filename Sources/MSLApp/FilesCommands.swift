import MSLCore
import SwiftUI

/// The menu bar for MSL Files, modelled on Finder's.
///
/// Deliberately item-for-item and shortcut-for-shortcut where Finder has an
/// equivalent, because a menu bar is where muscle memory lives: ⌘1-⌘4 for
/// the view modes, ⌘[ and ⌘] for back and forward, ⌘↑ for the enclosing
/// folder, and the whole Go menu with its ⇧⌘ destinations. Someone moving
/// between Finder and this window should never have to look.
///
/// Two deliberate departures, both because MSL is not Finder:
///
/// - **⌘N stays "New Instance"**, MSL's own long-standing meaning, rather
///   than becoming "New Finder Window". The Files window is ⌥⌘F.
/// - **The Go menu lists running Linux instances**, which is the one thing
///   Finder's cannot do and most of why this window exists.
struct FilesCommands: Commands {
    /// The focused browser window, or nil when the main MSL window has
    /// focus - every file command disables itself in that case rather than
    /// acting on some other window's selection.
    ///
    /// `@FocusedObject`, not `@FocusedValue`. The value variant hands over
    /// the model but does not *observe* it, so every `disabled(...)` in
    /// here was evaluated once and then went stale: "Enclosing Folder"
    /// rendered greyed out inside a nested folder while ⌘↑ worked fine.
    /// The object variant subscribes to `objectWillChange`, so the menus
    /// track selection and navigation as they change.
    @FocusedObject private var files: FilesModel?
    /// Set by the Help window, whose search field ⌘F should reach too.
    @FocusedValue(\.helpSearchAvailable) private var helpSearch

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("New Folder") { files?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(files?.canWrite != true)
            Button("New Folder with Selection") { files?.newFolderWithSelection() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(files?.canWrite != true || files?.selection.isEmpty != false)

            Divider()
            Button("Open") { files?.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(files?.selection.isEmpty != false)
            Button("Get Info") { files?.showInfoForSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(files?.focusedItem == nil)
            Button("Rename") { files?.beginRenamingSelection() }
                .disabled(files?.canWrite != true || files?.selection.count != 1)
            Button("Compress") { files.map { $0.compress($0.selection) } }
                .disabled(files?.canWrite != true || files?.selection.isEmpty != false)
            Button("Duplicate") { files.map { $0.duplicate($0.selection) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(files?.canWrite != true || files?.selection.isEmpty != false)
            Button("Quick Look") { files?.quickLookSelection() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(files?.selection.isEmpty != false)

            Divider()
            // Finder's File menu carries the tag swatches and a Tags…
            // item; a submenu is the closest a SwiftUI menu gets to the
            // row of coloured dots.
            Menu("Tags") {
                if let files {
                    TagMenuItems(files: files, paths: files.selection,
                                 applied: Set(files.visibleItems
                                    .filter { files.selection.contains($0.path) }
                                    .flatMap { $0.tags.map(\.name) }))
                }
            }
            .disabled(files?.selection.isEmpty != false)
            ShareLink(items: (files?.selection ?? []).sorted().map { URL(fileURLWithPath: $0) }) {
                Text("Share…")
            }
            .disabled(files?.selection.isEmpty != false)

            Divider()
            // Finder's wording and its ⌥⌘C, matching the context menu's
            // twin - both now go through `copyPaths`.
            Button("Copy as Pathname") { files?.copyPathOfSelection() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(files?.selection.isEmpty != false)
            Button("Open in Terminal") {
                if let files, let item = files.focusedItem { files.openInTerminal(item) }
            }
            .disabled(files?.focusedItem == nil)
            Button("Reveal in Finder") { files?.revealSelectionInFinder() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(files?.selection.isEmpty != false)

            Divider()
            Button("Move to Trash") { files.map { $0.delete($0.selection) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(files?.canWrite != true || files?.selection.isEmpty != false)

            Divider()
            Button("Find") { focusSearchField() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(files == nil && helpSearch != true)
        }

        CommandGroup(after: .pasteboard) {
            // The system's Copy/Paste stay as they are, so text fields keep
            // working; these are the file-level equivalents Finder offers,
            // and they act only when a browser window has focus.
            Divider()
            Button("Select All Items") { files?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(files == nil)
        }

        CommandMenu("Go") {
            Button("Back") { files?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(files?.canGoBack != true)
            Button("Forward") { files?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(files?.canGoForward != true)
            Button("Enclosing Folder") { files?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(files?.path.isEmpty != false)

            Divider()
            Button("Recents") { files?.goToRoot(id: "recents") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(files == nil)
            ForEach(Self.destinations, id: \.title) { destination in
                Button(destination.title) { files?.navigate(to: destination.path) }
                    .keyboardShortcut(destination.key, modifiers: destination.modifiers)
                    .disabled(files == nil)
            }

            // The part Finder's Go menu cannot have.
            if let guests = files?.roots(in: .linux), !guests.isEmpty {
                Divider()
                ForEach(guests) { root in
                    Button(root.name) { files?.goToRoot(id: root.id) }
                }
            }

            Divider()
            Button("Go to Folder…") { files?.goToFolderPresented = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(files == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(FileViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.label) { files?.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(files == nil)
            }

            Divider()
            Menu("Sort By") {
                ForEach(FileSortKey.allCases) { key in
                    Button(key.title) { files?.toggleSort(key) }
                }
                Divider()
                Toggle("Ascending", isOn: Binding(
                    get: { files?.sortAscending ?? true },
                    set: { files?.sortAscending = $0 }))
                Toggle("Keep Folders on Top", isOn: Binding(
                    get: { files?.foldersOnTop ?? true },
                    set: { files?.foldersOnTop = $0 }))
            }
            .disabled(files == nil)

            Menu("Group By") {
                ForEach(FileGrouping.allCases) { grouping in
                    Button(grouping.title) { files?.grouping = grouping }
                }
            }
            .disabled(files == nil)

            Divider()
            // `NavigationSplitView` contributes no sidebar command to a
            // `Window` scene, so this posts AppKit's own action - the same
            // one the toolbar's sidebar button sends.
            Button("Hide Sidebar") {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(files == nil)

            Divider()
            // Finder's own shortcut for this, and the reason people can
            // never remember it is that it is the only one with a period.
            Toggle("Show Hidden Files", isOn: Binding(
                get: { files?.showHidden ?? false },
                set: { files?.showHidden = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(files == nil)
            Toggle("Show Path Bar", isOn: Binding(
                get: { files?.showPathBar ?? true },
                set: { files?.showPathBar = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(files == nil)
            Toggle("Show Status Bar", isOn: Binding(
                get: { files?.showStatusBar ?? true },
                set: { files?.showStatusBar = $0 }))
                .keyboardShortcut("/", modifiers: .command)
                .disabled(files == nil)
            Divider()
        }
    }

    /// Finder's Go destinations, with Finder's shortcuts. Only the ones
    /// that mean something on this Mac - AirDrop and Network have no
    /// equivalent in a browser that lists directories.
    private static let destinations: [(title: String, path: String,
                                       key: KeyEquivalent, modifiers: EventModifiers)] = {
        let home = NSHomeDirectory()
        var items: [(String, String, KeyEquivalent, EventModifiers)] = [
            ("Documents", home + "/Documents", "o", [.command, .shift]),
            ("Desktop", home + "/Desktop", "d", [.command, .shift]),
            ("Downloads", home + "/Downloads", "l", [.command, .option]),
            ("Home", home, "h", [.command, .shift]),
            ("Computer", "/", "c", [.command, .shift]),
            ("Applications", "/Applications", "a", [.command, .shift]),
            ("Utilities", "/Applications/Utilities", "u", [.command, .shift]),
        ]
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) {
            items.append(("iCloud Drive", iCloud, "i", [.command, .shift]))
        }
        return items.filter { FileManager.default.fileExists(atPath: $0.1) }
    }()
}

/// Moves keyboard focus into the toolbar's search field.
///
/// SwiftUI's own `.searchFocused` is macOS 15 and later; this app targets
/// 14, so the field is found in the window's view tree and made first
/// responder directly. `.searchable` renders a real `NSSearchField`, so
/// there is a concrete view to find.
@MainActor
private func focusSearchField() {
    guard let window = NSApp.keyWindow else { return }
    func search(_ view: NSView) -> NSView? {
        if view is NSSearchField { return view }
        for subview in view.subviews {
            if let hit = search(subview) { return hit }
        }
        return nil
    }
    // The field lives in the toolbar, which is not inside contentView.
    let roots = [window.contentView, window.toolbar?.items
        .compactMap(\.view).first(where: { search($0) != nil })].compactMap { $0 }
    for root in roots {
        if let field = search(root) {
            window.makeFirstResponder(field)
            return
        }
    }
}

/// Finder's ⇧⌘G.
struct GoToFolderSheet: View {
    @ObservedObject var files: FilesModel
    @State private var path = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Go to Folder").font(.headline)
            TextField("/ or ~/", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(go)
                .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { files.goToFolderPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
        }
        .padding(Design.Spacing.large)
        .onAppear { focused = true }
    }

    private func go() {
        guard !path.isEmpty else { return }
        files.goToFolderPresented = false
        files.navigate(to: path)
    }
}
