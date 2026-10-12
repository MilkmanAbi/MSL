import MSLCore
import SwiftUI

/// Editing a text file in place, without copying it to the Mac first.
///
/// The whole point of MSL Files is that both sides are one window, and
/// "open the Linux config, change one line, save" was still a round trip
/// through a terminal. Guest files reach the Mac as a mounted volume, so
/// reading and writing is ordinary file I/O; what needs care is refusing
/// politely (binary, enormous, read-only) and never truncating a file that
/// could not be written.
struct FileTextEditorTarget: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct FileTextEditorSheet: View {
    let target: FileTextEditorTarget
    let onClose: () -> Void

    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var refusal: String?
    @State private var error: String?
    @State private var readOnly = false

    private var changed: Bool { text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            header
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let refusal {
                VStack(spacing: Design.Spacing.small) {
                    Image(systemName: "doc.questionmark").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(refusal).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .disabled(readOnly)
                    .overlay(RoundedRectangle(cornerRadius: Design.cornerRadius).stroke(.quaternary))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(Design.Spacing.large)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if readOnly {
                Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if changed, !readOnly {
                Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(saving ? "Saving…" : "Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(readOnly || !changed || saving || refusal != nil)
        }
    }

    private func load() {
        loading = true
        let url = target.url
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(String?, String?, Bool), Error> in
                do {
                    let data = try Data(contentsOf: url)
                    if let why = TextFileKind.refusal(for: data) { return .success((nil, why, true)) }
                    let writable = FileManager.default.isWritableFile(atPath: url.path)
                    return .success((String(decoding: data, as: UTF8.self), nil, !writable))
                } catch {
                    return .failure(error)
                }
            }.value
            loading = false
            switch outcome {
            case .success(let (contents, why, locked)):
                refusal = why
                readOnly = locked
                text = contents ?? ""
                original = text
            case .failure(let failure):
                error = "Couldn't open it: \(failure.localizedDescription)"
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        let url = target.url
        let contents = text
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    // Not atomic: an atomic write replaces the file, which on
                    // a guest volume loses its ownership and permissions, and
                    // breaks a config that something else is watching by inode.
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data(contents.utf8))
                    return nil
                } catch {
                    return error
                }
            }.value
            saving = false
            if let outcome {
                error = isReadOnlyVolumeError(outcome)
                    ? "This volume is read-only, so the change wasn't saved."
                    : "Couldn't save it: \(outcome.localizedDescription)"
            } else {
                original = contents
            }
        }
    }
}
