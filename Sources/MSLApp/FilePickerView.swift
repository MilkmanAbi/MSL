import Combine
import MSLCore
import SwiftUI

/// MSL Files acting as a Linux app's Open/Save dialog.
///
/// A Linux app asks for a file, `mslhd` parks the request, and MSL Files is
/// opened on the token that names it (see `READMES/24-FILE-PICKER.md`). This
/// is that window: the same browser as the rest of MSL Files, plus the chrome
/// a file dialog needs and an answer that goes back over the daemon socket.
///
/// **Every exit must answer.** The app on the other side is blocked on its
/// D-Bus reply, so cancelling, closing the window and failing to load all
/// send something back - silence would hang it.
@MainActor
final class FilePickerModel: ObservableObject {
    @Published var request: HostFilePickRequest?
    @Published var instance = ""
    @Published var filename = ""
    @Published var failure: String?
    /// Set once an answer has gone back, so the window closing afterwards
    /// does not send a second one.
    private(set) var answered = false

    let token: String
    let files = FilesModel()

    /// Republishes the browser's changes as our own.
    ///
    /// **SwiftUI does not forward a nested `ObservableObject`.** `files`
    /// lives inside this object, so a view observing *this* one never
    /// redraws when the browser changes - and this feature has been bitten
    /// by it twice: first the listing stayed empty however often it
    /// reloaded, then the Open button stayed disabled with a row visibly
    /// selected, because `canConfirm` reads `files.selection` and nothing
    /// told the footer to look again. Forwarding here fixes every reader at
    /// once, instead of each view having to remember to observe both.
    private var browserChanges: AnyCancellable?

    init(token: String) {
        self.token = token
        browserChanges = files.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Asks the daemon what this pick wants shown, and in doing so claims it.
    ///
    /// **Nothing slow may come before this.** Sending `filePickDetails` *is*
    /// the claim - it is what tells `PendingFilePicks` that MSL Files is
    /// alive and coming - and the daemon gives up on an unclaimed pick after
    /// `claimDeadline`, six seconds. This used to run after
    /// `AppModel.refresh()`, whose own daemon call is allowed ten, so a
    /// daemon slow enough to make that wait produced the worst outcome
    /// available: the guest app was told no picker was coming and fell back
    /// to its own dialog, while this window opened anyway to announce that
    /// nobody was waiting for it. Two dialogs, one of them dead.
    ///
    /// It is also off the main thread. `DaemonClient.send` is a blocking
    /// socket read, and on `@MainActor` a daemon that never answers froze
    /// the whole window for the full timeout.
    func claim() async {
        let token = self.token
        let reply = await Task.detached(priority: .userInitiated) {
            // Ten seconds, not the default two minutes: the daemon is
            // reading back a request it already holds in memory, so an
            // answer that slow is one that is not coming.
            DaemonClient.send(.filePickDetails(token: token), timeout: 10)
        }.value

        // Replies are "OK <payload>" or "ERROR <reason>" - the prefix is not
        // part of the JSON.
        guard let reply,
              reply.hasPrefix("OK "),
              let data = String(reply.dropFirst(3)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instance = object["instance"] as? String
        else {
            failure = "This file dialog is no longer waiting for an answer."
            return
        }
        let mode = (object["mode"] as? String).flatMap(HostFilePickRequest.Mode.init(rawValue:)) ?? .open
        let request = HostFilePickRequest(
            mode: mode,
            startGuestPath: object["start"] as? String ?? "/",
            suggestedName: object["name"] as? String ?? "",
            allowsMultiple: object["multiple"] as? Bool ?? false,
            title: object["title"] as? String ?? "")
        self.instance = instance
        self.request = request
        self.filename = request.suggestedName
    }

    /// Builds the sidebar and walks to the folder the app asked for.
    ///
    /// Split from `claim()` because this is the part that needs the instance
    /// list, and fetching that must never be what makes the claim late.
    func showRoots(instances: [Instance]) {
        guard let request, !instance.isEmpty else { return }
        files.rebuildRoots(from: instances)
        // Select the instance's root first, then walk to the folder the app
        // asked for. Selecting is what loads a listing at all (`select` vs a
        // bare `selectedRoot =`), and it also puts the sidebar on the right
        // row so the person can see where they are.
        if let root = files.roots.first(where: { $0.id == "guest-\(instance)" }) {
            files.select(root)
            if let start = HostFilePicker.startDirectory(guestPath: request.startGuestPath,
                                                         mountPath: root.path),
               start != root.path {
                files.navigate(to: start)
            }
        }
    }

    /// The instance's mount, from the roots the browser already built.
    private var mountPath: String? {
        files.roots.first { $0.id == "guest-\(instance)" }?.path
    }

    /// What the buttons say and whether the confirm one can be pressed.
    var confirmTitle: String {
        switch request?.mode {
        case .save: return "Save"
        case .directory: return "Choose"
        default: return "Open"
        }
    }

    var canConfirm: Bool {
        guard request != nil, failure == nil else { return false }
        switch request?.mode {
        case .save: return !filename.trimmingCharacters(in: .whitespaces).isEmpty
        case .directory: return true
        default: return !files.selection.isEmpty
        }
    }

    /// The host paths this window is offering, before translation.
    private var chosenHostPaths: [String] {
        switch request?.mode {
        case .save:
            let name = filename.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return [] }
            // Only a name, never a path: a typed "../../etc/passwd" must
            // land in this folder as a file called `passwd`, not escape it.
            return [(files.currentPath as NSString)
                .appendingPathComponent((name as NSString).lastPathComponent)]
        case .directory:
            return files.selection.isEmpty ? [files.currentPath] : Array(files.selection)
        default:
            return Array(files.selection)
        }
    }

    func confirm() {
        let paths = HostFilePicker.guestPaths(for: chosenHostPaths, instance: instance,
                                              mountPath: mountPath)
        guard !paths.isEmpty else {
            // Everything chosen is somewhere the guest cannot see. Saying so
            // is far better than handing the app a path that does not exist
            // there - it would fail to open it with no explanation.
            failure = "Linux can't reach that location. Choose somewhere inside \(instance) or your Mac home folder."
            return
        }
        answer(paths: paths, cancelled: false)
    }

    func cancel() {
        answer(paths: [], cancelled: true)
    }

    /// Called when the window goes away by any route. Harmless after a real
    /// answer; essential after the close button, which is a cancel.
    func answerIfUnanswered() {
        guard !answered else { return }
        answer(paths: [], cancelled: true)
    }

    /// Posted once an answer has gone back, so the window can move on to
    /// the next queued pick.
    static let didFinish = Notification.Name("MSLFilePickDidFinish")

    private func answer(paths: [String], cancelled: Bool) {
        guard !answered else { return }
        answered = true
        let encoded = paths.map { Data($0.utf8).base64EncodedString() }
        _ = DaemonClient.send(.filePickResult(token: token, encodedPaths: encoded, cancelled: cancelled))
        NotificationCenter.default.post(name: Self.didFinish, object: nil)
    }
}

struct FilePickerView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: FilePickerModel
    @Environment(\.dismiss) private var dismiss

    init(token: String) {
        _model = StateObject(wrappedValue: FilePickerModel(token: token))
    }

    var body: some View {
        Group {
            if let failure = model.failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(failure).multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.request == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // **The real MSL Files browser, not a copy of it.** An Open
                // dialog is this browser plus a bar of buttons, so it is
                // built from the same view - which is what gives the picker
                // icon/column/gallery views, sorting, search, Quick Look,
                // New Folder, arrow keys, the path bar and the enclosing-
                // folder button for nothing, and keeps every fix to the
                // browser working here too. The hand-written list this
                // replaced had already re-created a bug the browser solved
                // long ago: a row carrying a double-click gesture swallows
                // the single click, so nothing could be selected and Open
                // stayed disabled forever (`FilesModel.handleTap`).
                FilesView(files: model.files, title: title) { footer }
            }
        }
        // Wide enough that the name is readable. The list's fixed columns
        // (permissions 96, size 80, kind 150, modified 170, plus gaps and
        // padding) take about 560pt whatever the window does, so at 820 the
        // name got what was left - around 80pt - and every file showed as
        // `o…ng`. In a file dialog the name *is* the interface.
        .frame(minWidth: 1040, minHeight: 600)
        .task {
            // The claim goes first and alone - see `claim()` for why the
            // order here is the whole feature working or not.
            await model.claim()
            // Double-clicking a file in a picker means "choose it", not
            // "open it on the Mac".
            model.files.chooseFile = { _ in confirm() }
            await app.refresh()
            model.showRoots(instances: app.instances)
        }
        // The app on the other side is blocked until something is sent, so
        // the window disappearing has to count as a cancel.
        .onDisappear { model.answerIfUnanswered() }
    }

    /// The asking app's own title, so the dialog says what the app called it.
    private var title: String {
        if let given = model.request?.title, !given.isEmpty { return given }
        return model.request?.mode == .save ? "Save to Linux" : "Open from Linux"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.request?.mode == .save {
                Text("Save as:").foregroundStyle(.secondary)
                TextField("Name", text: $model.filename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { if model.canConfirm { confirm() } }
            }
            Spacer()
            Button("Cancel") {
                model.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(model.confirmTitle) { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
        }
        .padding(12)
    }

    private func confirm() {
        model.confirm()
        // A failure message means nothing was sent, so the window stays up
        // and the person can choose somewhere the guest can actually see.
        if model.failure == nil { dismiss() }
    }
}

/// The single picker window, showing one pick at a time.
///
/// A file dialog is modal to the app that asked for it, so queueing is the
/// right shape: a second Linux app's request waits until the first is
/// answered rather than fighting for the same window.
struct FilePickerHost: View {
    @State private var token: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let token {
                FilePickerView(token: token)
                    .id(token)   // a new pick is a new view, not a reused one
            } else {
                // Only ever a flicker on the way out: with no pick to show
                // this window closes itself. It is kept rather than left
                // blank so that if a close ever fails, the window says what
                // it is instead of being an empty grey rectangle.
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No file dialog is waiting.")
                    Text("A Linux app opens this when it asks you to choose a file.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // **A dialog with nothing to ask must not stay on screen.** This
        // window exists for one Linux app's question; empty, it is a window
        // nobody asked for - and for a while it was the window a Dock click
        // produced, because macOS had restored it and SwiftUI opens the first
        // scene at launch (reported 2026-09-30). Closing on sight is the
        // backstop for every route that could leave it empty: restoration, a
        // pick claimed by another window, or a queue that has drained.
        .onAppear {
            advance()
            if token == nil { dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MSLFilesPicks.didArrive)) { _ in
            // Only take a new one when nothing is on screen; the current
            // dialog must not be swapped out from under the person.
            if token == nil { advance() }
        }
        .onReceive(NotificationCenter.default.publisher(for: FilePickerModel.didFinish)) { _ in
            token = nil
            advance()
            // Answered and nothing queued behind it: the dialog is done, so
            // it goes away rather than lingering as an empty window.
            if token == nil { dismiss() }
        }
    }

    private func advance() {
        if token == nil { token = MSLFilesPicks.next() }
    }
}
