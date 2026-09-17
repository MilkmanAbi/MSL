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

    /// Fixed widths, shared by the header and every row so the two line up.
    /// Hand-laid columns mean nothing enforces that agreement but this.
    private enum Columns {
        static let size: CGFloat = 80
        static let kind: CGFloat = 150
        static let modified: CGFloat = 170
        /// Without this the right-aligned size runs straight into the
        /// left-aligned kind: "79 bytestext".
        static let gap: CGFloat = 16
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $files.selection) {
                ForEach(files.groupedItems, id: \.title) { group in
                    if group.title.isEmpty {
                        ForEach(group.items) { item in
                            row(item).tag(item.path)
                                .fileItemInteractions(item, files: files)
                        }
                    } else {
                        Section {
                            ForEach(group.items) { item in
                                row(item).tag(item.path)
                                    .fileItemInteractions(item, files: files)
                            }
                        } header: {
                            Text("\(group.title)  (\(group.items.count))")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 22)
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell(.name).frame(maxWidth: .infinity, alignment: .leading)
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

    private func row(_ item: MSLFileItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                FileIcon(item: item, size: 16)
                if files.renaming == item.path {
                    RenameField(name: item.name) { files.rename(item, to: $0) }
                } else {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                // Finder draws tag dots at the trailing edge of the Name
                // column, not in a column of their own.
                TagSwatches(tags: item.tags)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                                    .foregroundStyle(.secondary)
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
        // Clicking empty space clears the selection, as it does in Finder.
        .contentShape(Rectangle())
        .onTapGesture { files.selection = [] }
    }

    private func cell(_ item: MSLFileItem) -> some View {
        let selected = files.selection.contains(item.path)
        return VStack(spacing: 4) {
            FileThumbnail(item: item, size: iconSize)
                .frame(width: iconSize, height: iconSize)
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
                                .fill(selected ? Color.accentColor : .clear))
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
                        ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.85))
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
        .environment(\.defaultMinListRowHeight, 22)
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
                                    .fill(selected ? Color.accentColor.opacity(0.35) : .clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selected ? Color.accentColor : .clear))
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
