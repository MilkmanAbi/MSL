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
    /// See `FileClickLayer.dragHandleWidth`.
    var dragHandleWidth: CGFloat? = nil

    @State private var dropTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(dropHighlight)
            // Every left click - select, open, drag - goes through this one
            // AppKit layer; see `FileClickLayer` for why there must be exactly
            // one. Right-clicks pass through it to the context menu below.
            .overlay(
                FileClickLayer(
                    path: item.path,
                    isSelected: { files.selection.contains(item.path) },
                    onSelect: { modifiers in
                        if let onSingleTap { onSingleTap() }
                        else { files.handleTap(on: item, modifiers: modifiers) }
                    },
                    onOpen: {
                        // In column view the first click already descended into
                        // a folder; opening it again would push it twice.
                        if onSingleTap != nil, item.isBrowsableDirectory { return }
                        files.open(item)
                    },
                    dragItems: { dragPayload },
                    enabled: files.renaming != item.path,
                    dragHandleWidth: dragHandleWidth))
            .contextMenu { menu }
            // Dropping onto a folder puts the files inside it.
            .fileDropTarget(targeted: $dropTargeted) {
                // Decided at drop time rather than when the row was built: a
                // folder can stop being writable while it is on screen.
                item.isBrowsableDirectory && files.canWrite ? item.path : nil
            } receive: { urls, destination in
                files.receive(urls, into: destination)
            }

    }

    /// What a drag starting on this item carries: the whole selection if the
    /// item is part of it, otherwise just the item.
    private var dragPayload: [MSLFileItem] {
        guard files.selection.contains(item.path), files.selection.count > 1 else { return [item] }
        let selected = files.visibleItems.filter { files.selection.contains($0.path) }
        return selected.isEmpty ? [item] : selected
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 5)
                .fill(files.theme.selection.opacity(0.25))
        }
    }

    /// Right-clicking inside a multi-selection acts on the whole
    /// selection, as Finder does; right-clicking outside it acts on the one
    /// item under the cursor.
    private var targets: Set<String> {
        files.selection.contains(item.path) ? files.selection : [item.path]
    }

    /// Finder's label for the Mac path: the name for one item, a count for
    /// several. ("Mac" rather than Finder's bare "Pathname" because the twin
    /// item right below it copies the Linux path, and the pair has to read as
    /// a pair.)
    private var copyMacPathTitle: String {
        targets.count == 1
            ? "Copy \u{201C}\(item.name)\u{201D} as Mac Path"
            : "Copy \(targets.count) Items as Mac Paths"
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
        // The Finder-parity "Open With ▸" - every Mac app that can open this
        // file, plus Other…. Works on a guest file because the row's path is a
        // real mounted file the system can hand to any app.
        OpenWithMenu(item: item, targets: targets)
        Button("Quick Look") {
            files.quickLookTarget = QuickLookTarget(item: item)
        }
        // No `.keyboardShortcut("i")` here: the File menu (`FilesCommands`)
        // is the one authoritative ⌘I registration. A context menu is rebuilt
        // per row, so attaching it here would register ⌘I once for every
        // visible row - the same trap the Copy-as-Pathname item documents.
        Button("Get Info") { files.infoTarget = item }
        // Folders only: git is about a working tree, and a file's repository
        // is its folder's. Offered on every folder rather than only on ones
        // that are repositories, because finding out is the question - and
        // for a folder that is not one, the panel offers to make it one.
        if item.isBrowsableDirectory {
            Button("Git…") {
                files.gitTarget = GitPanelTarget(path: item.path, name: item.name)
            }
        }
        if files.canEditAsText(item) {
            Button("Edit as Text…") {
                files.editorTarget = FileTextEditorTarget(url: URL(fileURLWithPath: item.path))
            }
        }
        Divider()
        // One item renames inline; several open Power Rename - the batch
        // find/replace + numbering sheet Finder never had.
        if targets.count > 1 {
            Button("Rename \(targets.count) Items…") { files.beginPowerRename(targets) }
                .disabled(!files.canWrite)
        } else {
            Button("Rename…") { files.renaming = item.path }
                .disabled(!files.canWrite)
        }
        Button("Duplicate") { files.duplicate(targets) }
            .disabled(!files.canWrite)
        Button("Copy") { files.copyToPasteboard(targets) }
        // The modern macOS share sheet: Mail, Messages, AirDrop, Reminders and
        // any third-party service registered for these files - macOS's own
        // "services for this selection", surfaced the supported way.
        ShareLink(items: targets.sorted().map { URL(fileURLWithPath: $0) }) {
            Text("Share…")
        }
        // The one Finder has no reason to offer: chmod +x on a Linux file,
        // straight to the guest inode (a WebDAV permission change never
        // reaches it). Shown only for a guest file that isn't already
        // runnable - "I downloaded a script and it won't run."
        if files.canMakeExecutable(targets) {
            Button("Make Executable") { files.makeExecutable(targets) }
        }
        Divider()
        Menu("Tags") {
            TagMenuItems(files: files, paths: targets,
                         applied: Set(item.tags.map(\.name)))
        }
        Divider()
        // Two paths for the same file, because the file has two: the
        // `/Volumes/127.0.0.1/...` the Mac sees, and the `/etc/...` the guest
        // does. "Copy Linux Path" is the one Finder cannot offer, and the
        // reason someone reaches for this browser over Finder for a guest
        // file - it's the path your shell, a Dockerfile, or a config actually
        // wants. It offers itself only when the row maps into a guest.
        //
        // No `.keyboardShortcut` on either: a context menu is rebuilt per row,
        // so a shortcut here would register once for every visible row on top
        // of the File menu's one authoritative ⌥⌘C. The menu bar owns them.
        Button(copyMacPathTitle) { files.copyPaths(targets) }
        if files.hasLinuxPath(targets) {
            Button("Copy Linux Path") { files.copyLinuxPaths(targets) }
        }

        Divider()

        Toggle("Show Hidden Files", isOn: Binding(
            get: { files.showHidden },
            set: { files.showHidden = $0 }))

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.sorted().map {
                URL(fileURLWithPath: $0)
            })
        }
        Divider()
        // A shell on either side of the boundary, at this row's folder - the
        // enclosing folder when the row is a file, as Finder's "New Terminal
        // at Folder" does. On the Mac side it offers every terminal installed;
        // on the Linux side it opens a shell in the guest that owns the file.
        TerminalMenu(item: item, files: files)
        openInMSL
        Divider()
        Button("Move to Trash", role: .destructive) { files.delete(targets) }
            .disabled(!files.canWrite)
    }
}

/// Dropping onto a folder copies into *that* folder, not the one being
/// viewed - which is what makes dragging into a subfolder work without
/// opening it first.
extension View {
    func fileItemInteractions(_ item: MSLFileItem, files: FilesModel,
                              onSingleTap: (() -> Void)? = nil,
                              dragHandleWidth: CGFloat? = nil) -> some View {
        modifier(FileItemInteractions(item: item, files: files, onSingleTap: onSingleTap,
                                      dragHandleWidth: dragHandleWidth))
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
