import SwiftUI
import MSLCore

/// What a folder's git repository looks like, for somebody who already knows
/// git and wants to see where they are without leaving the file browser.
///
/// It reads and does not write, apart from offering to create a repository
/// where there is none. Everything that changes history, or talks to a
/// remote, belongs in a terminal - a button that silently did the wrong
/// merge would be much worse than no button.
struct GitPanel: View {
    let path: String
    let folderName: String
    @ObservedObject var files: FilesModel
    let dismiss: () -> Void

    @State private var state: State = .loading
    @State private var working = false
    @State private var editingOrigin = false
    @State private var originDraft = ""
    @State private var originError: String?

    private enum State {
        case loading
        case repository(Git.Snapshot)
        case absent(Git.Absence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 480)
        .task(id: path) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Spacing.small) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    Text(folderName).font(.headline)
                }
                if case .repository(let snapshot) = state {
                    Text(snapshot.root).font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(Design.Spacing.large)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            Spacer()
            ProgressView("Reading the repository…").frame(maxWidth: .infinity)
            Spacer()
        case .absent(let absence):
            absentView(absence)
        case .repository(let snapshot):
            repositoryView(snapshot)
        }
    }

    // MARK: - Nothing to show

    private func absentView(_ absence: Git.Absence) -> some View {
        VStack(spacing: Design.Spacing.medium) {
            Spacer()
            Image(systemName: absence == .notARepository ? "folder" : "exclamationmark.triangle")
                .font(.system(size: 32)).foregroundStyle(.secondary)
            Text(absence.sentence).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Only offered where it is the obvious next thing. A folder that
            // could not be read is not a folder to start creating things in.
            if absence == .notARepository {
                Button(working ? "Creating…" : "Initialise a repository here") {
                    Task { await initialise() }
                }
                .disabled(working)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Design.Spacing.large)
    }

    // MARK: - A repository

    private func repositoryView(_ snapshot: Git.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(snapshot)
            Divider()
            List {
                if !snapshot.conflicted.isEmpty {
                    changeSection("Conflicted", snapshot.conflicted, tint: .red)
                }
                if !snapshot.staged.isEmpty {
                    changeSection("Staged", snapshot.staged, tint: .green)
                }
                if !snapshot.unstaged.isEmpty {
                    changeSection("Changed", snapshot.unstaged, tint: .orange)
                }
                if !snapshot.untracked.isEmpty {
                    changeSection("Untracked", snapshot.untracked, tint: .secondary)
                }
                if snapshot.isClean {
                    Section("Working tree") {
                        Label(snapshot.isEmpty
                              ? "A new repository, with nothing committed yet."
                              : "Nothing changed.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !snapshot.commits.isEmpty {
                    Section("History") {
                        ForEach(snapshot.commits, id: \.hash) { commit in
                            commitRow(commit)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ snapshot: Git.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.medium) {
                Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.medium))
                // Only shown when there is an upstream to be ahead or behind
                // of; zero and zero against nothing means nothing.
                if !snapshot.upstream.isEmpty {
                    if snapshot.ahead > 0 {
                        Label("\(snapshot.ahead)", systemImage: "arrow.up")
                            .foregroundStyle(.green)
                    }
                    if snapshot.behind > 0 {
                        Label("\(snapshot.behind)", systemImage: "arrow.down")
                            .foregroundStyle(.orange)
                    }
                    if snapshot.ahead == 0 && snapshot.behind == 0 {
                        Text("up to date with \(snapshot.upstream)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            originRow(snapshot)
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.vertical, Design.Spacing.medium)
    }

    private func changeSection(_ title: String, _ changes: [Git.Change],
                               tint: Color) -> some View {
        Section("\(title) — \(changes.count)") {
            ForEach(changes, id: \.path) { change in
                HStack(spacing: Design.Spacing.small) {
                    Text(String(change.isUntracked ? "?" : (change.isStaged ? change.index : change.worktree)))
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                        if let from = change.from {
                            Text("was \(from)").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(change.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commitRow(_ commit: Git.Commit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .lineLimit(2)
            HStack(spacing: Design.Spacing.small) {
                Text(commit.shortHash).font(.caption.monospaced())
                Text(commit.author).font(.caption)
                if let date = commit.date {
                    Text(date, format: .relative(presentation: .named)).font(.caption)
                }
                if !commit.refs.isEmpty {
                    Text(commit.refs).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
    }

    // MARK: - The remote

    @ViewBuilder
    private func originRow(_ snapshot: Git.Snapshot) -> some View {
        if editingOrigin {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                TextField("https://github.com/you/project.git", text: $originDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit { Task { await saveOrigin() } }
                Button("Save") { Task { await saveOrigin() } }
                    .disabled(working || !originDraftIsUsable)
                Button("Cancel") { editingOrigin = false; originError = nil }
            }
        } else if snapshot.origin.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "link.badge.plus").font(.caption)
                Text("No remote").font(.caption)
                Button("Add one") { beginEditingOrigin(snapshot.origin) }
                    .buttonStyle(.link).font(.caption)
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.caption)
                Text(snapshot.origin).font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot.origin, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.plain).help("Copy the remote URL")
                // Only when the remote certainly has a web page: guessing one
                // for a path or `file://` remote would open an address that
                // does not exist.
                if let web = Git.webURL(forRemote: snapshot.origin) {
                    Button { NSWorkspace.shared.open(web) } label: {
                        Image(systemName: "arrow.up.right.square").font(.caption)
                    }
                    .buttonStyle(.plain).help("Open \(web.absoluteString)")
                }
                Button("Change") { beginEditingOrigin(snapshot.origin) }
                    .buttonStyle(.link).font(.caption)
            }
            .foregroundStyle(.secondary)
        }

        // Inline, and the snapshot stays on screen. A failure here must not
        // throw away the panel the way a failed initialise does.
        if let originError {
            Label(originError, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Empty is allowed - it means "remove the remote" - but a value that is
    /// present has to be one git will accept.
    private var originDraftIsUsable: Bool {
        let trimmed = originDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || Git.isUsableRemote(trimmed)
    }

    private func beginEditingOrigin(_ current: String) {
        originDraft = current
        originError = nil
        editingOrigin = true
    }

    private func saveOrigin() async {
        guard originDraftIsUsable else { return }
        working = true
        defer { working = false }
        let host = path
        let guest = files.guestPath(forHostPath: host)
        let instance = files.instanceOwning(hostPath: host)
        let url = originDraft
        let failure = await Task.detached(priority: .userInitiated) {
            GitService.setOrigin(hostPath: host, guestPath: guest,
                                 instance: instance, url: url)
        }.value
        if let failure {
            originError = failure.sentence
            return
        }
        originError = nil
        editingOrigin = false
        await load()
    }

    // MARK: - Doing it

    private func load() async {
        state = .loading
        let host = path
        let guest = files.guestPath(forHostPath: host)
        let instance = files.instanceOwning(hostPath: host)
        // Off the main actor: this is a daemon round trip, or a process.
        let outcome = await Task.detached(priority: .userInitiated) {
            GitService.inspect(hostPath: host, guestPath: guest, instance: instance)
        }.value
        switch outcome {
        case .repository(let snapshot): state = .repository(snapshot)
        case .absent(let absence): state = .absent(absence)
        }
    }

    private func initialise() async {
        working = true
        defer { working = false }
        let host = path
        let guest = files.guestPath(forHostPath: host)
        let instance = files.instanceOwning(hostPath: host)
        let failure = await Task.detached(priority: .userInitiated) {
            GitService.initialise(hostPath: host, guestPath: guest, instance: instance)
        }.value
        if let failure {
            state = .absent(failure)
        } else {
            await load()
        }
    }
}

/// Names the folder a git panel is open on. A struct rather than a bare
/// path so `.sheet(item:)` has something `Identifiable` to key on, and so
/// the panel's title can say the folder's name rather than its whole path.
struct GitPanelTarget: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
}
