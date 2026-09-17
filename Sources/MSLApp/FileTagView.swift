import MSLCore
import SwiftUI

extension FileTag {
    /// Finder's swatch for this tag.
    ///
    /// Driven by the colour *index*, not the name, so a tag keeps its
    /// colour on a system whose standard tags are localised - on a French
    /// Mac the red tag is called "Rouge" and still stores index 6.
    var color: Color? {
        switch colorIndex {
        case 1: return Color(nsColor: .systemGray)
        case 2: return Color(nsColor: .systemGreen)
        case 3: return Color(nsColor: .systemPurple)
        case 4: return Color(nsColor: .systemBlue)
        case 5: return Color(nsColor: .systemYellow)
        case 6: return Color(nsColor: .systemRed)
        case 7: return Color(nsColor: .systemOrange)
        // A custom tag with no colour assigned. Finder shows the name in
        // menus but draws no dot, so neither does this.
        default: return nil
        }
    }
}

/// The coloured dots Finder draws beside a tagged file's name.
struct TagSwatches: View {
    let tags: [FileTag]
    var diameter: CGFloat = 8

    var body: some View {
        let colored = tags.compactMap { tag in tag.color.map { (tag.name, $0) } }
        if !colored.isEmpty {
            HStack(spacing: -diameter / 3) {
                // Finder draws multiple tags as overlapping dots, newest
                // last and on top.
                ForEach(Array(colored.enumerated()), id: \.offset) { _, entry in
                    Circle()
                        .fill(entry.1)
                        .frame(width: diameter, height: diameter)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                       lineWidth: 0.5))
                }
            }
            .help(tags.map(\.name).joined(separator: ", "))
        }
    }
}

/// The tag section of a context menu: the seven standard tags with a check
/// against the ones already applied.
struct TagMenuItems: View {
    @ObservedObject var files: FilesModel
    let paths: Set<String>
    let applied: Set<String>

    var body: some View {
        ForEach(FileTag.standardNames, id: \.self) { name in
            Button {
                files.toggleTag(name, on: paths)
            } label: {
                if applied.contains(name) {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
        }
        if !applied.isEmpty {
            Divider()
            Button("Clear Tags") {
                for name in applied { files.toggleTag(name, on: paths) }
            }
        }
    }
}

/// Finder's Get Info window: the full metadata for one item, and a place to
/// change its tags.
struct FileInfoSheet: View {
    let item: MSLFileItem
    @ObservedObject var files: FilesModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(item.name) Info").font(.headline).lineLimit(1)
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
            .padding(Design.Spacing.medium)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    HStack(spacing: Design.Spacing.medium) {
                        FileThumbnail(item: item, size: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.title3.weight(.semibold)).lineLimit(2)
                            Text([item.kind, item.isBrowsableDirectory ? nil : FileFormat.size(item)]
                                .compactMap { $0 }.joined(separator: " - "))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider()
                    section("General") {
                        row("Kind", item.kind ?? "--")
                        row("Size", FileFormat.size(item))
                        row("Where", (item.path as NSString).deletingLastPathComponent)
                        row("Created", FileFormat.date(item.created))
                        row("Modified", FileFormat.date(item.modified))
                    }

                    Divider()
                    section("Tags") {
                        // Swatches to click, which is how Finder's own Get
                        // Info panel offers them.
                        HStack(spacing: 8) {
                            ForEach(FileTag.standardNames, id: \.self) { name in
                                let applied = item.tags.contains { $0.name == name }
                                Button {
                                    files.toggleTag(name, on: [item.path])
                                } label: {
                                    Circle()
                                        .fill(FileTag(name: name,
                                                      colorIndex: FileTag.standardColorIndex(for: name))
                                            .color ?? .gray)
                                        .frame(width: 18, height: 18)
                                        .overlay {
                                            if applied {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .help(name)
                            }
                        }
                        if !item.tags.isEmpty {
                            Text(item.tags.map(\.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Design.Spacing.medium)
            }
        }
        .frame(width: 380, height: 460)
    }

    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(value).textSelection(.enabled).lineLimit(4).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
