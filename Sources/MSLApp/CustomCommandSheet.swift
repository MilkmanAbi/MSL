import SwiftUI

/// Edits the command one Linux app is launched with.
///
/// The case this exists for: an app whose own `.desktop` entry does not
/// work here - a game that needs a different LÖVE build, a binary that
/// wants an environment variable set, a packaged entry pointing at the
/// wrong path. Those are one-line fixes if the command is editable, and
/// otherwise they are "this app doesn't work on MSL".
struct CustomCommandSheet: View {
    let appName: String
    let originalCommand: String
    @Binding var draft: String
    let hasOverride: Bool
    let onSave: () -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isUnchanged: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == originalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Launch Command")
                .font(.headline)
            Text(appName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Command", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .font(.system(.body, design: .monospaced))
                // Not autocorrected or capitalised: this is a shell command,
                // and "Love" is not "love".
                .autocorrectionDisabled()

            Text("Runs inside \(appName.contains("·") ? "the instance" : "Linux") exactly as written, "
                 + "as your own user. Shell syntax works, so environment "
                 + "variables and arguments are fine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isUnchanged || hasOverride {
                Label("Originally: \(originalCommand)", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack {
                if hasOverride {
                    Button("Reset to Default") {
                        onReset()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 440)
    }
}
