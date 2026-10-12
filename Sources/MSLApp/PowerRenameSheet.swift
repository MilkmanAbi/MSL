import MSLCore
import SwiftUI

/// Power Rename: rewrite a whole selection's names by a rule, with a live
/// before/after preview. The feature Finder never grew - find & replace
/// (regex too), a prefix or suffix, sequential numbering - and the reason a dev
/// reaches for MSL Files over Finder for a folder of `IMG_1234`s or `K123`s.
struct PowerRenameSheet: View {
    @ObservedObject var files: FilesModel
    let paths: [String]

    @State private var options = PowerRename.Options()

    private var existing: Set<String> { files.currentDirectoryNames }
    private var previews: [PowerRename.Preview] {
        PowerRename.preview(paths: paths, options: options, existing: existing)
    }
    private var problems: Int { previews.filter { $0.problem != nil }.count }
    private var changing: Int { previews.filter { $0.changed && $0.problem == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Rename \(paths.count) Item\(paths.count == 1 ? "" : "s")", systemImage: "character.cursor.ibeam")
                    .font(.headline)
                Spacer()
            }
            .padding(Design.Spacing.medium)
            Divider()

            HStack(spacing: 0) {
                rules.frame(width: 360)
                Divider()
                previewList.frame(minWidth: 420)
            }

            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 540, idealHeight: 600)
        .tint(files.theme.accent)
    }

    // MARK: Rules

    /// A native grouped form: it sizes its own fields to the column, so
    /// nothing can overflow and push the panel sideways (the old stack did,
    /// because the case picker was wider than the column).
    private var rules: some View {
        Form {
            Section("Find & Replace") {
                TextField("Find", text: $options.find, prompt: Text("K123"))
                TextField("Replace with", text: $options.replacement, prompt: Text("Lie01"))
                Picker("Apply to", selection: $options.target) {
                    ForEach(PowerRename.Target.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Regular expression", isOn: $options.useRegex)
                Toggle("Case sensitive", isOn: $options.caseSensitive)
                if let error = options.regexError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section("Add Text") {
                TextField("Prefix", text: $options.prefix, prompt: Text("draft_"))
                TextField("Suffix", text: $options.suffix, prompt: Text("_v2"))
            }

            Section("Numbering") {
                Toggle("Add a sequential number", isOn: $options.numbering)
                if options.numbering {
                    Stepper("Start at \(options.numberStart)", value: $options.numberStart, in: 0...100000)
                    Stepper("Step by \(options.numberIncrement)", value: $options.numberIncrement, in: 1...1000)
                    Stepper("\(options.numberPadding) digit\(options.numberPadding == 1 ? "" : "s")",
                            value: $options.numberPadding, in: 1...8)
                    Picker("Position", selection: $options.numberPosition) {
                        ForEach(PowerRename.NumberPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Separator", text: $options.numberSeparator, prompt: Text("- or _"))
                }
            }

            Section("Letter Case") {
                Picker("Case", selection: $options.letterCase) {
                    ForEach(PowerRename.LetterCase.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Preview

    private var previewList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Current").frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text("New name").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, Design.Spacing.medium).padding(.vertical, 6)
            Divider()
            List(previews) { row in
                HStack(spacing: 8) {
                    Text(row.oldName)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Text(row.newName.isEmpty ? "—" : row.newName)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(color(for: row))
                            .fontWeight(row.changed ? .medium : .regular)
                        if let hint = problemHint(row.problem) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange).help(hint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.callout, design: .monospaced))
            }
            .listStyle(.inset)
        }
    }

    private func color(for row: PowerRename.Preview) -> Color {
        if row.problem != nil { return .orange }
        if row.changed { return files.theme.accent ?? .primary }
        return .secondary
    }

    private func problemHint(_ problem: PowerRename.Preview.Problem?) -> String? {
        switch problem {
        case .empty: return "This rule leaves an empty name."
        case .slash: return "A name can't contain \u{201C}/\u{201D}."
        case .duplicate: return "Two items would get this same name."
        case .collision: return "A file with this name already exists here."
        case nil: return nil
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if problems > 0 {
                Label("\(problems) name\(problems == 1 ? "" : "s") need fixing",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("\(changing) of \(paths.count) will change")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { files.powerRenameTargets = [] }
                .keyboardShortcut(.cancelAction)
            Button("Rename") { files.applyPowerRename(previews) }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isNoOp || problems > 0 || changing == 0)
        }
        .padding(Design.Spacing.medium)
    }
}
