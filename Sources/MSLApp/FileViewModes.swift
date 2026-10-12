import AppKit
import MSLCore
import Quartz
import SwiftUI

// MARK: - List

/// A `List`, not a `Table`.
///
/// `Table` was the obvious choice for name/size/kind/date columns, and it is
/// what this used first - but on macOS it is an `NSTableView` underneath
/// that handles clicks on its own rows and never delivers a tap gesture,
/// whether the gesture is attached to the cell content or to the table
/// itself. Double-clicking a row did nothing at all, confirmed with a real
/// `CGEvent` double-click (click state 1 then 2) rather than only through
/// scripted events, so it was SwiftUI and not the test harness. A file
/// browser without double-click-to-open is not a file browser, so the
/// columns are laid out by hand instead - which costs column *resizing*,
/// and buys the interaction everything else depends on. Click-to-sort is
/// implemented on the hand-laid header instead of being lost with it.
struct FileListView: View {
    @ObservedObject var files: FilesModel
    /// True when the window shows a Darker surface or a tinted wash behind
    /// the files; the list then drops its own opaque background.
    @Environment(\.filesCustomBackdrop) private var customBackdrop

    /// Fixed widths, shared by the header and every row so the two line up.
    /// Hand-laid columns mean nothing enforces that agreement but this.
    private enum Columns {
        static let permissions: CGFloat = 96
        static let size: CGFloat = 80
        static let kind: CGFloat = 150
        static let modified: CGFloat = 170
        /// Without this the right-aligned size runs straight into the
        /// left-aligned kind: "79 bytestext".
        static let gap: CGFloat = 16
    }

    /// The `ls -l` permissions column earns its space only on a Linux root,
    /// where the mode is real and worth seeing; on a Mac root it would just
    /// repeat what Finder already conveys, so it stays hidden.
    private var showsPermissions: Bool { files.selectedRoot?.isGuest == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // No `selection:` binding: selection belongs to `FileClickLayer`
            // and the model, as in every other view mode. A bound List draws
            // AppKit's own blue highlight (which ignores the theme) and its
            // native click handling competed with ours.
            List {
                ForEach(files.groupedItems, id: \.title) { group in
                    if group.title.isEmpty {
                        ForEach(group.items) { item in
                            selectableRow(item)
                        }
                    } else {
                        Section {
                            ForEach(group.items) { item in
                                selectableRow(item)
                            }
                        } header: {
                            Text("\(group.title)  (\(group.items.count))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(files.theme.headerText)
                        }
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 22)
            .listStyle(.inset)
            .scrollContentBackground(customBackdrop ? .hidden : .automatic)
            .alternatingRowBackgrounds()
            // Drag on empty space to rubber-band select (see `MarqueeLayer`).
            .overlay(MarqueeLayer(files: files))
            .dropsIntoCurrentFolder(files)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell(.name).frame(maxWidth: .infinity, alignment: .leading)
            if showsPermissions {
                Text("Permissions")
                    .foregroundStyle(.secondary)
                    .frame(width: Columns.permissions, alignment: .leading)
                    .padding(.leading, Columns.gap)
            }
            headerCell(.size, alignment: .trailing).frame(width: Columns.size, alignment: .trailing)
            headerCell(.kind).frame(width: Columns.kind, alignment: .leading)
                .padding(.leading, Columns.gap)
            headerCell(.modified, alignment: .trailing)
                .frame(width: Columns.modified, alignment: .trailing)
        }
        .font(.caption)
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, 4)
    }

    private func headerCell(_ key: FileSortKey, alignment: HorizontalAlignment = .leading) -> some View {
        Button { files.toggleSort(key) } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(key.title)
                    .foregroundStyle(files.sortKey == key ? .primary : .secondary)
                if files.sortKey == key {
                    Image(systemName: files.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Icon + name: the part of a row that drags the file. Beyond it the row
    /// is whitespace a drag rubber-bands from, as in Finder's list view.
    private func nameHandleWidth(_ item: MSLFileItem) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = (item.name as NSString).size(withAttributes: [.font: font]).width
        return 16 + 6 + text + 12
    }

    /// A row with its interactions and the themed selection highlight.
    private func selectableRow(_ item: MSLFileItem) -> some View {
        let selected = files.selection.contains(item.path)
        return row(item)
            .fileItemInteractions(item, files: files, dragHandleWidth: nameHandleWidth(item))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? files.theme.selection.opacity(0.30) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? files.theme.selection.opacity(0.55) : .clear))
                    .padding(.horizontal, 6))
    }

    private func row(_ item: MSLFileItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                FileIcon(item: item, size: 16)
                if files.renaming == item.path {
                    RenameField(name: item.name) { files.rename(item, to: $0) }
                } else {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                if let badge = files.gitBadge(for: item) { GitDot(badge: badge) }
                LinuxTypeBadge(mode: files.linuxMode(for: item), tint: files.theme.companion)
                Spacer(minLength: 6)
                // Finder draws tag dots at the trailing edge of the Name
                // column, not in a column of their own.
                TagSwatches(tags: item.tags)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsPermissions {
                Text(files.linuxMode(for: item).map(LinuxFileMode.lsString) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: Columns.permissions, alignment: .leading)
                    .padding(.leading, Columns.gap)
                    .help("Linux permissions")
            }

            Text(FileFormat.size(item))
                .foregroundStyle(.secondary).monospacedDigit()
                .frame(width: Columns.size, alignment: .trailing)
            Text(item.kind ?? "--")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .frame(width: Columns.kind, alignment: .leading)
                .padding(.leading, Columns.gap)
            Text(FileFormat.date(item.modified))
                .foregroundStyle(.secondary)
                .frame(width: Columns.modified, alignment: .trailing)
        }
    }
}

/// A small glyph marking a Linux file type the file icon can't convey on its
/// own - a symlink, a named pipe, a socket, a device node. Nothing for a
/// plain file or folder, and nothing on a Mac root (the mode is nil there),
/// so it costs a real row nothing.
/// The git dot on a folder: green when the working tree is clean, red the
/// moment anything has changed.
///
/// **A folder with no dot is not a repository, or could not be read.** The
/// absence is never "clean" - a repository that timed out produces no badge
/// at all, precisely so that nothing shows green on the strength of an answer
/// nobody got.
///
/// Red and green alone are the classic pair two people in a hundred cannot
/// tell apart, so the shape differs too - a filled dot for changes, a ring
/// for clean - and the tooltip says it in words with a count.
struct GitDot: View {
    let badge: Git.Badge

    var body: some View {
        Image(systemName: badge.isClean ? "circle" : "circle.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(badge.isClean ? Color.green : Color.red)
            .help(badge.summary)
            .accessibilityLabel(badge.summary)
    }
}

struct LinuxTypeBadge: View {
    let mode: UInt32?
    var tint: Color = .secondary
    var body: some View {
        if let mode, let symbol = LinuxFileMode.kind(mode).badgeSymbol {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .help(LinuxFileMode.kind(mode).label ?? "")
        }
    }
}

// MARK: - Icon

/// Finder's icon view: a wrapping grid of large thumbnails with the name
/// beneath, names wrapping to two lines and centred.
struct FileIconGridView: View {
    @ObservedObject var files: FilesModel
    var iconSize: CGFloat = 64

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 44), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14,
                      pinnedViews: [.sectionHeaders]) {
                ForEach(files.groupedItems, id: \.title) { group in
                    Section {
                        ForEach(group.items) { item in
                            cell(item).fileItemInteractions(item, files: files)
                        }
                    } header: {
                        if !group.title.isEmpty {
                            HStack {
                                Text("\(group.title)  (\(group.items.count))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(files.theme.headerText)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .background(.regularMaterial)
                        }
                    }
                }
            }
            .padding(Design.Spacing.medium)
        }
        // Empty space belongs to the marquee: drag to rubber-band select,
        // click to clear the selection, as in Finder.
        .overlay(MarqueeLayer(files: files))
        .dropsIntoCurrentFolder(files)
    }

    private func cell(_ item: MSLFileItem) -> some View {
        let selected = files.selection.contains(item.path)
        return VStack(spacing: 4) {
            FileThumbnail(item: item, size: iconSize)
                .frame(width: iconSize, height: iconSize)
                // On the icon's corner rather than beside the name: a grid
                // cell's name is centred and often two lines, so anything
                // added inline moves as the text reflows.
                .overlay(alignment: .bottomTrailing) {
                    if let badge = files.gitBadge(for: item) {
                        GitDot(badge: badge)
                            .padding(2)
                            .background(Circle().fill(.background).opacity(0.9))
                    }
                }
            Group {
                if files.renaming == item.path {
                    RenameField(name: item.name) { files.rename(item, to: $0) }
                        .frame(width: iconSize + 36)
                } else {
                    Text(item.name)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? files.theme.selection : .clear))
                        .foregroundStyle(selected ? Color.white : .primary)
                }
            }
            .frame(width: iconSize + 40)
            TagSwatches(tags: item.tags, diameter: 7)
        }
        .frame(width: iconSize + 40)
    }
}

// MARK: - Column

/// Finder's column view: the directory chain side by side, each column
/// showing one level, with a preview pane when the selection is a file.
///
/// The columns are derived from the navigation path rather than stored
/// separately - see `FilesModel.columnChain` for why that matters.
struct FileColumnView: View {
    @ObservedObject var files: FilesModel
    /// True when the window shows a Darker surface or a tinted wash behind
    /// the files; the list then drops its own opaque background.
    @Environment(\.filesCustomBackdrop) private var customBackdrop

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(files.columnChain.enumerated()), id: \.offset) { index, column in
                        columnList(column, at: index)
                            .frame(width: 230)
                            .id(index)
                        Divider()
                    }
                    if let focused = files.focusedItem, !focused.isBrowsableDirectory {
                        FileInspector(item: focused, files: files, showsPreview: true)
                            .frame(width: 260)
                            .id("preview")
                    }
                }
            }
            .onChange(of: files.path.count) { _, _ in
                // Follow the newest column, the way Finder scrolls right as
                // you descend.
                withAnimation { proxy.scrollTo(files.breadcrumbs.count - 1, anchor: .trailing) }
            }
        }
        .task { await files.loadAncestors() }
    }

    private func columnList(_ column: (path: String, items: [MSLFileItem], selected: String?),
                            at index: Int) -> some View {
        List {
            ForEach(column.items) { item in
                HStack(spacing: 6) {
                    FileIcon(item: item, size: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let badge = files.gitBadge(for: item) { GitDot(badge: badge) }
                    LinuxTypeBadge(mode: files.linuxMode(for: item), tint: files.theme.companion)
                    Spacer(minLength: 4)
                    TagSwatches(tags: item.tags, diameter: 7)
                    if item.isBrowsableDirectory {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
                .listRowBackground(
                    column.selected == item.path
                        ? RoundedRectangle(cornerRadius: 4).fill(files.theme.selection.opacity(0.85))
                        : nil)
                .foregroundStyle(column.selected == item.path ? Color.white : .primary)
                // Single click moves through columns here - that is what
                // column view is for.
                .fileItemInteractions(item, files: files) {
                    files.selectInColumn(item, at: index)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(customBackdrop ? .hidden : .automatic)
        .environment(\.defaultMinListRowHeight, 22)
        // Each column drops into the folder that column is showing, not into
        // whichever one happens to be selected.
        .fileDropTarget {
            files.canWrite ? column.path : nil
        } receive: { urls, destination in
            files.receive(urls, into: destination)
        }
    }
}

// MARK: - Gallery

/// Finder's gallery view: one large preview, a filmstrip of the rest along
/// the bottom, and the inspector on the right.
struct FileGalleryView: View {
    @ObservedObject var files: FilesModel

    private var current: MSLFileItem? {
        files.focusedItem ?? files.visibleItems.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let current {
                    // Capped rather than filling the pane: `QLPreviewView`
                    // scales its content up to whatever room it is given,
                    // and a folder blown up to 700pt looks like a rendering
                    // bug rather than a preview.
                    QuickLookPreview(url: URL(fileURLWithPath: current.path))
                        .frame(maxWidth: 520, maxHeight: 520)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(Design.Spacing.large)
                } else {
                    Spacer()
                }
                Divider()
                filmstrip
            }
            if let current {
                Divider()
                FileInspector(item: current, files: files, showsPreview: false)
                    .frame(width: 260)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files.visibleItems) { item in
                        let selected = current?.path == item.path
                        FileThumbnail(item: item, size: 48)
                            .frame(width: 56, height: 56)
                            .padding(3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? files.theme.selection.opacity(0.35) : .clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selected ? files.theme.selection : .clear))
                            .id(item.path)
                            .fileItemInteractions(item, files: files)
                    }
                }
                .padding(.horizontal, Design.Spacing.medium)
                .padding(.vertical, 8)
            }
            .onChange(of: files.selection) { _, _ in
                if let path = files.selection.first {
                    withAnimation { proxy.scrollTo(path, anchor: .center) }
                }
            }
        }
        .frame(height: 78)
    }
}

// MARK: - Inspector

/// The right-hand information panel: preview, name, and the metadata Finder
/// shows - kind, size, created, modified.
struct FileInspector: View {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel
    var showsPreview: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                if showsPreview {
                    QuickLookPreview(url: URL(fileURLWithPath: item.path))
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Spacer()
                        FileThumbnail(item: item, size: 96)
                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text([item.kind, item.isBrowsableDirectory ? nil : FileFormat.size(item)]
                        .compactMap { $0 }.joined(separator: " - "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Information").font(.subheadline.weight(.semibold))
                    field("Created", FileFormat.date(item.created))
                    field("Modified", FileFormat.date(item.modified))
                    field("Where", (item.path as NSString).deletingLastPathComponent)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.subheadline.weight(.semibold))
                    HStack(spacing: 7) {
                        ForEach(FileTag.standardNames, id: \.self) { name in
                            let applied = item.tags.contains { $0.name == name }
                            Button {
                                files.toggleTag(name, on: [item.path])
                            } label: {
                                Circle()
                                    .fill(FileTag(name: name,
                                                  colorIndex: FileTag.standardColorIndex(for: name))
                                        .color ?? .gray)
                                    .frame(width: 15, height: 15)
                                    .overlay {
                                        if applied {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                    Text(item.tags.isEmpty
                         ? "Add Tags…"
                         : item.tags.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(Design.Spacing.medium)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}

// MARK: - Quick Look

// MARK: - Quick Look sheet

/// The space-bar Quick Look: a real preview beside an info panel.
///
/// The old sheet was `QLPreviewView` alone, which draws *nothing* for a folder
/// (the common case here) and nothing for a file whose type it can't preview,
/// so the peek looked broken. This keeps the live preview where there is one
/// and always shows the metadata Finder's Quick Look puts in its title bar and
/// More-Info: kind, size, dates, and - the part Finder can't - the real Linux
/// permissions. For a folder it counts what's inside.
struct QuickLookSheet: View {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel
    let onClose: () -> Void

    @State private var folderStats: FolderStats?
    @State private var textPreview: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FileIcon(item: item, size: 16)
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                LinuxTypeBadge(mode: files.linuxMode(for: item), tint: files.theme.companion)
                Spacer()
                Button("Open") { files.open(item); onClose() }
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(Design.Spacing.medium)
            Divider()
            HStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                infoPanel
                    .frame(width: 240)
            }
            // Space and Escape both dismiss, as they do in Finder's Quick Look.
            // Zero-sized so they only register the key equivalents.
            Group {
                Button("", action: onClose).keyboardShortcut(.space, modifiers: [])
                Button("", action: onClose).keyboardShortcut(.cancelAction)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: item.path) {
            folderStats = nil
            textPreview = nil
            if item.isBrowsableDirectory {
                folderStats = await FolderStats.load(item.path, provider: files.currentProvider)
            } else if item.size <= UInt64(QuickLookSheet.textPreviewLimit) {
                textPreview = await Self.loadTextPreview(item.path)
            }
        }
    }

    /// A text file preview reads up to this much - enough to fill the pane,
    /// far short of loading a log the size of a disk.
    static let textPreviewLimit = 512 * 1024

    /// The head of a file, decoded as text, or nil if it isn't text. Off the
    /// main actor: the read goes over the WebDAV mount for a guest file. This
    /// is what makes the peek show *something* for the config files and
    /// scripts `QLPreviewView` draws blank.
    static func loadTextPreview(_ path: String) async -> String? {
        let limit = textPreviewLimit
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limit) else { return nil }
            guard TextFileKind.looksTextual(sample: data.prefix(TextFileKind.sniffByteCount)) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    @ViewBuilder private var previewArea: some View {
        if item.isBrowsableDirectory {
            // A folder has no Quick Look content, so show it as itself, big -
            // the same move Finder makes.
            VStack(spacing: 12) {
                FileThumbnail(item: item, size: 128)
                if let stats = folderStats {
                    Text(stats.summaryLine).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else if let text = textPreview {
            // A real text peek for the extensionless configs and scripts that
            // QLPreviewView shows nothing for.
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Spacing.medium)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            QuickLookPreview(url: URL(fileURLWithPath: item.path))
                .padding(1)
        }
    }

    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                infoGroup("General") {
                    infoRow("Kind", kindLine)
                    if item.isBrowsableDirectory {
                        // No "Size" for a folder: this counts only the
                        // immediate level, so a folder of folders would read
                        // "Zero KB" and look broken. The count is the honest
                        // figure a quick peek can give without a full walk.
                        if let stats = folderStats {
                            infoRow("Contains", stats.containsLine)
                            if stats.totalSize > 0 {
                                infoRow("Files here", ByteCountFormatter.string(
                                    fromByteCount: Int64(stats.totalSize), countStyle: .file))
                            }
                        }
                    } else {
                        infoRow("Size", FileFormat.size(item))
                    }
                    infoRow("Where", (item.path as NSString).deletingLastPathComponent)
                    infoRow("Created", FileFormat.date(item.created))
                    infoRow("Modified", FileFormat.date(item.modified))
                }
                if let mode = files.linuxMode(for: item) {
                    infoGroup("Linux") {
                        infoRow("Permissions", LinuxFileMode.lsString(mode))
                        infoRow("Octal", LinuxFileMode.octalString(mode))
                        if let linux = files.guestPath(forHostPath: item.path) {
                            infoRow("Path", linux)
                        }
                    }
                }
                if !item.tags.isEmpty {
                    infoGroup("Tags") {
                        Text(item.tags.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Spacing.medium)
        }
    }

    private var kindLine: String {
        if let mode = files.linuxMode(for: item), let label = LinuxFileMode.kind(mode).label {
            return label
        }
        return item.kind ?? (item.isDirectory ? "Folder" : "Document")
    }

    private func infoGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One directory's immediate contents, counted. Immediate rather than
/// recursive on purpose: a recursive walk of a guest tree over the WebDAV
/// mount would make a "quick" look anything but. It's the same figure Finder
/// shows first, before its own slower recursive total catches up.
struct FolderStats: Equatable {
    let folders: Int
    let files: Int
    let totalSize: UInt64

    var summaryLine: String {
        "\(folders + files) item\(folders + files == 1 ? "" : "s")"
    }
    var containsLine: String {
        "\(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
    }

    static func load(_ path: String, provider: LocalFileProvider?) async -> FolderStats {
        guard let provider else { return FolderStats(folders: 0, files: 0, totalSize: 0) }
        let entries = (try? await provider.list(path)) ?? []
        let folders = entries.filter(\.isDirectory).count
        let size = entries.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
        return FolderStats(folders: folders, files: entries.count - folders, totalSize: size)
    }
}

/// A real Quick Look preview.
///
/// `QLPreviewView` rather than `QLPreviewPanel`: the panel is driven through
/// the responder chain (`acceptsPreviewPanelControl`, `beginPreviewPanelControl`),
/// which SwiftUI gives no reliable hook into. The view is an ordinary
/// `NSView` that renders whatever `previewItem` points at, which is all this
/// needs and works identically inside a sheet, the gallery, and the
/// inspector.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }
}
