import SwiftUI
import MSLCore

/// Removing MSL, with the Linux kept or removed as the person chooses.
///
/// **Why a window and not just the CLI.** Uninstalling is the one thing a
/// person does when they have already decided they are finished, and
/// making them find a terminal for it is the software arguing. It is also
/// the moment they most deserve a straight answer about what is on their
/// Mac: the list below is itemised and sized, and nothing is removed until
/// they have read it.
///
/// Everything it shows comes from `Uninstaller.plan`, which is also what
/// `msl uninstall` prints — one inventory, so the two can never disagree
/// about what MSL leaves behind.
struct UninstallWindow: View {
    @Environment(\.dismiss) private var dismiss

    @State private var keepLinux = true
    @State private var plan: Uninstaller.Plan?
    @State private var confirming = false
    @State private var running = false
    @State private var steps: [String] = []
    @State private var finished: Finish?

    private enum Finish: Equatable {
        case done(leftovers: [String])
        case refused(String)
        case failed([String])
    }

    private var mode: Uninstaller.Mode { keepLinux ? .keepLinux : .everything }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let finished {
                outcome(finished)
            } else if running {
                progress
            } else {
                chooser
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear(perform: reload)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Remove MSL").font(.title2).bold()
            Text("Everything MSL put on this Mac, listed before anything happens.")
                .foregroundStyle(.secondary)
        }
        .padding(Design.Spacing.large)
    }

    // MARK: - Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one decision that matters, and it is the first thing on
            // screen rather than a checkbox under a wall of paths.
            Picker("", selection: $keepLinux) {
                Text("Keep my Linux").tag(true)
                Text("Remove everything").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Spacing.large)
            .padding(.top, Design.Spacing.medium)
            .onChange(of: keepLinux) { _, _ in reload() }

            Text(keepLinux
                 ? "Your instances, their files and your settings stay on this Mac. "
                   + "Install MSL again later and it picks up where it left off."
                 : "Your instances and everything in them are deleted. This cannot be undone.")
                .font(.callout)
                .foregroundStyle(keepLinux ? .secondary : .primary)
                .padding(.horizontal, Design.Spacing.large)
                .padding(.top, Design.Spacing.small)
                .fixedSize(horizontal: false, vertical: true)

            if let plan {
                itemList(plan)
                footer(plan)
            } else {
                Spacer()
                ProgressView("Looking at what is here…")
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .alert("Remove MSL and delete your Linux?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) { run() }
        } message: {
            Text("\(plan?.instances.count ?? 0) instance(s) and "
                 + "\(Uninstaller.format(plan?.removingBytes ?? 0)) will be deleted. "
                 + "There is no undo.")
        }
    }

    private func itemList(_ plan: Uninstaller.Plan) -> some View {
        List {
            Section("Will be removed — \(Uninstaller.format(plan.removingBytes))") {
                ForEach(plan.removing, id: \.path) { item in row(item) }
            }
            if !plan.keeping.isEmpty {
                Section("Will be kept — \(Uninstaller.format(plan.keepingBytes))") {
                    ForEach(plan.keeping, id: \.path) { item in row(item) }
                }
            }
            if !plan.warnings.isEmpty {
                Section("Worth knowing") {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func row(_ item: Uninstaller.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.path).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.bytes > 0 {
                Text(Uninstaller.format(item.bytes))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func footer(_ plan: Uninstaller.Plan) -> some View {
        HStack {
            // Said plainly, because the alternative is somebody clicking
            // the button and then wondering what the password prompt is.
            Text("macOS will ask for your password for the parts it installed.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button(keepLinux ? "Remove MSL" : "Remove Everything…") {
                if keepLinux { run() } else { confirming = true }
            }
            .keyboardShortcut(.defaultAction)
            // Destructive, and it looks it.
            .tint(keepLinux ? nil : .red)
        }
        .padding(Design.Spacing.large)
    }

    // MARK: - Running

    private var progress: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            ProgressView().controlSize(.small)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.caption.monospaced()).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: steps.count) { _, count in
                    withAnimation { scroll.scrollTo(count - 1) }
                }
            }
        }
        .padding(Design.Spacing.large)
    }

    // MARK: - Outcome

    @ViewBuilder
    private func outcome(_ finish: Finish) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            switch finish {
            case .done(let leftovers):
                Label("MSL has been removed", systemImage: "checkmark.circle")
                    .font(.title3)
                if leftovers.isEmpty {
                    Text("Nothing of MSL is left on this Mac.")
                } else {
                    // Named, not glossed over: "removed" that left things
                    // behind without saying so is how people stop trusting
                    // an uninstaller.
                    Text("These are still here, because removing them was not authorised:")
                    ForEach(leftovers, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            case .refused(let why):
                Label("The administrator does not allow this", systemImage: "lock")
                    .font(.title3)
                Text(why).fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed.")
                    .font(.callout).foregroundStyle(.secondary)
            case .failed(let reasons):
                Label("Some of it could not be removed", systemImage: "exclamationmark.triangle")
                    .font(.title3)
                ForEach(reasons, id: \.self) { reason in
                    Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.large)
    }

    // MARK: - Doing it

    private func reload() {
        let chosen = mode
        Task.detached(priority: .userInitiated) {
            // Sizing walks the whole of Application Support, which is tens
            // of gigabytes - never on the main thread.
            let made = Uninstaller.plan(mode: chosen)
            await MainActor.run { plan = made }
        }
    }

    private func run() {
        guard let plan else { return }
        running = true
        steps = []
        Task.detached(priority: .userInitiated) {
            let report = Uninstaller.perform(plan) { line in
                Task { @MainActor in steps.append(line) }
            }
            // The privileged tail, only if there is one. macOS shows its
            // own authorisation dialog here.
            var leftovers: [String] = []
            if report.refusedByPolicy == nil, !report.needsSudo.isEmpty {
                await MainActor.run { steps.append("asking macOS for permission to finish") }
                if Uninstaller.finishPrivileged(report) != nil {
                    leftovers = report.needsSudo
                }
            }
            let outcome: Finish
            if let refused = report.refusedByPolicy {
                outcome = .refused(refused)
            } else if !report.failed.isEmpty {
                outcome = .failed(report.failed.map { "\($0.path): \($0.reason)" })
            } else {
                outcome = .done(leftovers: leftovers)
            }
            await MainActor.run {
                running = false
                finished = outcome
            }
        }
    }
}
