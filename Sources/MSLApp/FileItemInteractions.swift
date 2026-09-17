import AppKit
import MSLCore
import SwiftUI

/// Everything that must behave the same in all four view modes:
/// double-click to open, the context menu, dragging out, and - for folders -
/// dropping onto them.
///
/// Factored out because Finder's consistency here is a large part of why it
/// feels solid: a right-click means the same thing in icon view as in list
/// view. Four copies of this logic would drift.
struct FileItemInteractions: ViewModifier {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel
    /// What a single click does. Column view overrides it to navigate;
    /// every other mode leaves it nil and gets Finder's selection rules.
    var onSingleTap: (() -> Void)?

    @State private var dropTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(dropHighlight)
            .onTapGesture(count: 2) { files.open(item) }
            .modifier(SingleTap(action: onSingleTap ?? {
                // Read the modifiers at the moment of the click: SwiftUI's
                // tap gesture does not carry them, and Finder's ⌘ and ⇧
                // behaviour is most of what makes multi-selection usable.
                files.handleTap(on: item, modifiers: NSEvent.modifierFlags)
            }))
            .contextMenu { menu }
            // Dragging out hands over the real file URL, so a drop into
            // Finder, Mail, or the other root is an ordinary file copy that
            // needs no cooperation from this app.
            .draggable(URL(fileURLWithPath: item.path)) {
                HStack(spacing: 6) {
                    FileIcon(item: item, size: 16)
                    Text(item.name).lineLimit(1)
                }
                .padding(4)
            }
            .modifier(FolderDropTarget(item: item, files: files, targeted: $dropTargeted))
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.25))
        }
    }

    /// Right-clicking inside a multi-selection acts on the whole
    /// selection, as Finder does; right-clicking outside it acts on the one
    /// item under the cursor.
    private var targets: Set<String> {
        files.selection.contains(item.path) ? files.selection : [item.path]
    }

    /// Finder's label: the name for one item, a count for several.
    private var copyPathTitle: String {
        targets.count == 1
            ? "Copy \u{201C}\(item.name)\u{201D} as Pathname"
            : "Copy \(targets.count) Items as Pathnames"
    }

    /// "Open Folder in MSL", which is only meaningful where the guest can
    /// actually see the folder.
    ///
    /// Three outcomes, and the disabled one matters: a folder on the Mac
    /// outside the home directory - `/usr/local`, `/Applications`, another
    /// volume - is not visible from inside any guest at all. Opening a
    /// shell at a path that does not exist there would look like a broken
    /// feature rather than an unsupported one, so the item greys out
    /// instead.
    @ViewBuilder private var openInMSL: some View {
        switch files.guestMapping(for: item) {
        case .guestFilesystem(let instance, _):
            // Already Linux-side: only the instance that owns this
            // filesystem can reach it, so there is nothing to choose.
            Button("Open Folder in MSL (\(instance))") {
                files.openInMSL(item, instance: instance)
            }

        case .macHomeShare:
            // Under the Mac home share, which every running instance sees
            // at the same path - so which one to open in is a real choice.
            let instances = files.roots(in: .linux)
            if instances.count == 1, let only = instances.first {
                Button("Open Folder in MSL (\(only.name))") {
                    files.openInMSL(item, instance: only.name)
                }
            } else if instances.isEmpty {
                // `/mnt/mac` only exists inside a running guest.
                Button("Open Folder in MSL") {}.disabled(true)
            } else {
                Menu("Open Folder in MSL") {
                    ForEach(instances) { root in
                        Button(root.name) {
                            files.openInMSL(item, instance: root.name)
                        }
                    }
                }
            }

        case .unreachable:
            Button("Open Folder in MSL") {}.disabled(true)
        }
    }

    @ViewBuilder private var menu: some View {
        Button(item.isBrowsableDirectory ? "Open" : "Open with default app") {
            files.open(item)
        }
        Button("Quick Look") {
            files.quickLookTarget = QuickLookTarget(url: URL(fileURLWithPath: item.path))
        }
        Button("Get Info") { files.infoTarget = item }
            .keyboardShortcut("i", modifiers: .command)
        Divider()
        Button("Rename…") { files.renaming = item.path }
            .disabled(!files.canWrite)
        Button("Duplicate") { files.duplicate(targets) }
            .disabled(!files.canWrite)
        Button("Copy") { files.copyToPasteboard(targets) }
        ShareLink(items: targets.sorted().map { URL(fileURLWithPath: $0) }) {
            Text("Share…")
        }
        Divider()
        Menu("Tags") {
            TagMenuItems(files: files, paths: targets,
                         applied: Set(item.tags.map(\.name)))
        }
        Divider()
        // Finder's own wording and shortcut. It acts on `targets`, not on
        // `item`: right-clicking inside a multiple selection used to copy
        // three files with "Copy" and exactly one path with this one.
        // No `.keyboardShortcut` here, deliberately - unlike "Get Info"
        // above, which predates this. A context menu is rebuilt per row, so
        // attaching one registers the same ⌥⌘C once for every visible row on
        // top of the File menu's registration. The menu-bar item is the one
        // authoritative registration; the cost is that this item shows no
        // accelerator glyph next to it, where Finder does.
        Button(copyPathTitle) { files.copyPaths(targets) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.sorted().map {
                URL(fileURLWithPath: $0)
            })
        }
        Divider()
        // A shell on either side of the boundary, at this row's folder -
        // the enclosing folder when the row is a file, as Finder's "New
        // Terminal at Folder" does.
        Button("Open in Terminal") { files.openInTerminal(item) }
        openInMSL
        Divider()
        Button("Move to Trash", role: .destructive) { files.delete(targets) }
            .disabled(!files.canWrite)
    }
}

/// Runs the mode's click behaviour.
private struct SingleTap: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture(perform: action)
    }
}

/// Dropping onto a folder copies into *that* folder, not the one being
/// viewed - which is what makes dragging into a subfolder work without
/// opening it first.
private struct FolderDropTarget: ViewModifier {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if item.isBrowsableDirectory, files.canWrite {
            content.dropDestination(for: URL.self) { urls, _ in
                files.receive(urls, into: item.path)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

extension View {
    func fileItemInteractions(_ item: MSLFileItem, files: FilesModel,
                              onSingleTap: (() -> Void)? = nil) -> some View {
        modifier(FileItemInteractions(item: item, files: files, onSingleTap: onSingleTap))
    }
}

/// Inline rename, committing on Return and cancelling on Escape.
struct RenameField: View {
    @State var name: String
    let commit: (String) -> Void
    @FocusState private var focused: Bool

    init(name: String, commit: @escaping (String) -> Void) {
        _name = State(initialValue: name)
        self.commit = commit
    }

    var body: some View {
        TextField("", text: $name)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { commit(name) }
            .onExitCommand { commit(name) }
    }
}

/// Shared formatting so a size or a date reads identically in every mode.
enum FileFormat {
    static func size(_ item: MSLFileItem) -> String {
        // Every directory, bundles included. An .app has no size of its own
        // - the bytes are in the files inside it - and reporting the zero
        // that `fileSize` returns renders as "Zero KB", which reads as a
        // broken app rather than as "not applicable". Finder shows the
        // recursive total instead; that means walking the whole bundle, so
        // this says nothing rather than something wrong.
        item.isDirectory
            ? "--"
            : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
