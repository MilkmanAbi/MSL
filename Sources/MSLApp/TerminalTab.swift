import AppKit
import MSLCore
import SwiftTerm
import SwiftUI

/// One live shell session against one instance, kept alive independently of
/// whichever view happens to be on screen.
///
/// The session runs the real `msl <instance>` command line inside a
/// pseudo-terminal, rather than reimplementing the shell protocol on top of
/// `ShellClient`. That is deliberate, and it is the exact opposite of the
/// choice `LinuxAppLauncher` makes: `msl`'s interactive path wants a
/// controlling terminal - it puts stdin in raw mode, relays SIGWINCH, and
/// half-closes the connection when stdin reaches EOF. A generated `.app`
/// has no tty, which is why *that* path can't use it. A terminal emulator
/// is nothing but a tty, so here it is the right thing to drive, and this
/// inherits every fix the interactive path has ever had.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let instance: String
    let view: LocalProcessTerminalView

    /// `nil` while running; the process's exit code once it has ended.
    @Published private(set) var exitCode: Int32?
    @Published private(set) var hasStarted = false

    init(instance: String) {
        self.instance = instance
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        applyAppearance()
    }

    /// Starts the shell if it isn't already running. Safe to call again
    /// after the session ends - that is what the Reconnect button does.
    func start() {
        guard exitCode != nil || !hasStarted else { return }
        exitCode = nil
        hasStarted = true
        view.startProcess(executable: MSLPaths.tool("msl").path, args: [instance])
    }

    /// Ends the session. The shell gets a `SIGHUP`, the same signal a real
    /// terminal sends when its window closes, so the guest side winds down
    /// the way it always does rather than being cut off mid-write.
    func stop() {
        guard hasStarted, exitCode == nil else { return }
        let pid = view.process.shellPid
        if pid > 0 { kill(pid, SIGHUP) }
    }

    private func applyAppearance() {
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Follow the system's text colours rather than hard-coding a
        // scheme, so the terminal changes with the rest of the app between
        // light and dark instead of being a black rectangle in a light
        // window.
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode code: Int32?) {
        // SwiftTerm hands over `waitpid`'s raw status word, not an exit code.
        let decoded = code.map(ProcessExitStatus.code(fromWaitStatus:)) ?? 0
        Task { @MainActor in self.exitCode = decoded }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Keeps one `TerminalSession` per instance alive for the lifetime of the
/// app, so switching tabs or instances doesn't silently kill a shell
/// somebody is in the middle of using - and, just as importantly, doesn't
/// leave a session open for an instance that has been removed. An open
/// session is what holds the VM awake, so these are not free to leak.
@MainActor
final class TerminalSessions: ObservableObject {
    private var sessions: [String: TerminalSession] = [:]

    func session(for instance: String) -> TerminalSession {
        if let existing = sessions[instance] { return existing }
        let session = TerminalSession(instance: instance)
        sessions[instance] = session
        return session
    }

    func end(_ instance: String) {
        sessions.removeValue(forKey: instance)?.stop()
    }

    /// Drops sessions for instances that no longer exist.
    func prune(keeping names: Set<String>) {
        for name in sessions.keys where !names.contains(name) {
            end(name)
        }
    }
}

// MARK: - Views

struct TerminalTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessions: TerminalSessions
    let instance: Instance

    private var session: TerminalSession { sessions.session(for: instance.name) }

    var body: some View {
        TerminalContent(session: session, instance: instance)
            // Keyed by instance so SwiftUI rebuilds the wrapper - but not
            // the session - when the selection changes.
            .id(instance.name)
    }
}

private struct TerminalContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    let instance: Instance

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TerminalRepresentable(view: session.view)

                if !session.hasStarted {
                    startPrompt
                } else if let code = session.exitCode {
                    endedOverlay(code: code)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            // Auto-connect: opening the Terminal tab *is* the request for a
            // shell. Starting one boots the instance if it isn't running,
            // which counts against the concurrent-VM cap - if the daemon
            // refuses, `msl` prints its reason into this very terminal, so
            // the refusal explains itself where the user is looking.
            if !session.hasStarted { session.start() }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    session.stop()
                } label: {
                    Label("End Session", systemImage: "xmark.circle")
                }
                .disabled(session.exitCode != nil || !session.hasStarted)
                .help("Close this shell")

                Button {
                    model.openTerminal(instance)
                } label: {
                    Label("Open in Terminal", systemImage: "arrow.up.forward.app")
                }
                .help("Open the same shell in Terminal.app")
            }
        }
    }

    private var startPrompt: some View {
        ContentUnavailableView {
            Label("Terminal", systemImage: "terminal")
        } description: {
            Text("Opens a Linux shell in \(instance.name).")
        } actions: {
            Button("Connect") { session.start() }
                .buttonStyle(.borderedProminent)
        }
        .background(.regularMaterial)
    }

    private func endedOverlay(code: Int32) -> some View {
        VStack(spacing: Design.Spacing.medium) {
            Image(systemName: code == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(code == 0 ? Color.secondary : .orange)
            Text(code == 0 ? "Session ended" : "Session ended (exit \(code))")
                .font(.headline)
            // The scrollback stays visible behind this, so whatever the
            // shell or the daemon printed on the way out is still readable -
            // a refused start explains itself here rather than vanishing.
            Button("Reconnect") { session.start() }
                .buttonStyle(.borderedProminent)
        }
        .padding(Design.Spacing.section)
        .background(
            RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        )
    }
}

/// Hosts SwiftTerm's AppKit view. The view is owned by the `TerminalSession`,
/// not created here - SwiftUI rebuilds representables freely, and a terminal
/// that lost its scrollback every time the window resized would be useless.
private struct TerminalRepresentable: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView { view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
