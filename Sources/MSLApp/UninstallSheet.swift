import AppKit
import MSLCore
import SwiftUI

/// Uninstalling MSL, from inside MSL.
///
/// The app shows the plan and then hands the job to `msl uninstall`, in a
/// Terminal window, and quits. It deliberately does not do the removing
/// itself: this bundle and the tools beside it are on the list, and code
/// that deletes the file it is running from - then carries on to the next
/// step - is the kind of thing that works until the day it doesn't. One
/// implementation, in `Uninstaller`, driven by one caller.
struct UninstallSection: View {
    @State private var showSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Uninstall").font(.headline)
            Text("Removes MSL from this Mac. Your Linux instances, images and settings are kept, so installing MSL again picks up where you left off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Uninstall MSL…") { showSheet = true }
        }
        .sheet(isPresented: $showSheet) { UninstallSheet() }
    }
}

struct UninstallSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var plan: Uninstaller.Plan?
    @State private var alsoDeleteLinux = false
    @State private var typed = ""
    @State private var handedOff = false

    private var mode: Uninstaller.Mode { alsoDeleteLinux ? .everything : .keepLinux }
    private var confirmed: Bool { !alsoDeleteLinux || RemovalConfirmation.matches(typed) }
    /// The sheet hands the job to `msl uninstall`. In an app whose first
    /// launch never finished, that command doesn't exist yet - so say so
    /// rather than opening a Terminal window that reports a missing file.
    private var toolInstalled: Bool { FileManager.default.isExecutableFile(atPath: MSLPaths.tool("msl").path) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text(alsoDeleteLinux ? "Uninstall MSL and delete your Linux" : "Uninstall MSL")
                .font(.title3).bold()

            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                        list("Will be removed", plan.removing, tint: .primary)
                        if !plan.keeping.isEmpty {
                            list("Will be kept", plan.keeping, tint: .green)
                        }
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(alsoDeleteLinux ? Color.red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at what's installed…") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Toggle("Also delete my Linux - every instance, image and setting", isOn: $alsoDeleteLinux)
                .toggleStyle(.checkbox)
            if alsoDeleteLinux {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This cannot be undone. Type \(RemovalConfirmation.word) to confirm.")
                        .font(.caption).foregroundStyle(.red)
                    TextField(RemovalConfirmation.word, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            if toolInstalled {
                Text("MSL will open a Terminal window to finish, and quit.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // The sheet can only hand off to `msl`, so say so rather than
                // opening a Terminal window that reports a missing file.
                Label("The msl command isn't installed yet, so there is nothing here to remove but the app itself - drag it to the Trash.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(alsoDeleteLinux ? "Delete Everything" : "Uninstall MSL") { handOff() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || !confirmed || handedOff || !toolInstalled)
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 520)
        .task(id: alsoDeleteLinux) {
            let wanted = mode
            let made = await Task.detached(priority: .userInitiated) { Uninstaller.plan(mode: wanted) }.value
            plan = made
        }
    }

    private func list(_ title: String, _ items: [Uninstaller.Item], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold().foregroundStyle(tint)
            ForEach(items, id: \.path) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label)
                    if let note = item.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Uninstaller.format(item.bytes)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Writes a `.command` file and opens it: double-clickable shell scripts
    /// open in Terminal by themselves, which needs no permission to script
    /// Terminal (the Apple-events prompt "Open in Terminal" has to raise).
    private func handOff() {
        handedOff = true
        let tool = MSLPaths.tool("msl").path
        let script = """
        #!/bin/sh
        # Written by MSL.app. Safe to delete.
        clear
        "\(tool)" uninstall --yes\(alsoDeleteLinux ? " --everything" : "")
        status=$?
        echo
        echo "You can close this window."
        exit $status
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Uninstall MSL.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil
        else {
            handedOff = false
            return
        }
        NSWorkspace.shared.open(url)
        // Long enough for Terminal to have the file open, short enough that
        // quitting still feels like part of the same action. The script runs
        // in Terminal, not here, so it survives this process ending - which
        // it must, because it is about to delete this process's own bundle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }
}
