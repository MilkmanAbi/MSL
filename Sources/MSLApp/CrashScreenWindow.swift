import AppKit
import MSLCore
import SwiftUI

/// The screen MSL puts up when it has run out of explanations.
///
/// Shown as its own window, from its own launch (`--crash-screen`), because
/// the process that crashed is in no condition to draw anything - a daemon
/// has no UI at all, and an app that just took a SIGSEGV has seconds to
/// live. So the handler spawns this and then lets the original die
/// properly, keeping the crash report macOS writes.
struct CrashScreenView: View {
    let report: (component: String, stopCode: String, detail: String)?

    var body: some View {
        ZStack(alignment: .bottom) {
            // The picture carries the whole message. It is deliberately
            // unhelpful about the cause, which is the honest position when
            // nothing knows what went wrong.
            if let image = NSImage(named: "Crash_Screen")
                ?? Bundle.main.image(forResource: "Crash_Screen") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Even the crash screen can fail to load its own picture.
                Color(red: 0.11, green: 0.12, blue: 0.16)
                Text("¯\\(x_x)/¯\nYour MSL ran into a problem.")
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }

            // The one thing the picture cannot carry: what actually
            // happened, in text somebody can paste into an issue.
            if let report {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                // The code first, in the form somebody can search for. A
                // bare name told them nothing they could look up; a number
                // that never moves does.
                if let code = CrashScreen.code(named: report.stopCode) {
                    Text("\(code.printed) · \(code.name)")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    Text(code.happened)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    // Only when there is something to do. For the
                    // unanticipated ones there is not, and inventing advice
                    // would be worse than the silence.
                    if let next = code.next {
                        Text(next)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // An uncaught exception carries its own name, so there
                    // is no entry to look up - show what there is.
                    Text(report.stopCode)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                HStack(spacing: Design.Spacing.medium) {
                    Text(report.component)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy details") {
                        NSPasteboard.general.clearContents()
                        // Everything an issue needs, including the number.
                        let code = CrashScreen.code(named: report.stopCode)
                        NSPasteboard.general.setString(
                            [code.map { "\($0.printed) \($0.name)" } ?? report.stopCode,
                             "component: \(report.component)",
                             MSLVersion.display,
                             report.detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                            forType: .string)
                    }
                    Button("Open the log") {
                        // The log is where a crash like this actually gets
                        // diagnosed - the picture is only there to be
                        // honest about MSL not knowing.
                        let logs = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Logs/MSL")
                        NSWorkspace.shared.selectFile(
                            logs.appendingPathComponent("mslhd.log").path,
                            inFileViewerRootedAtPath: logs.path)
                    }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                }
                .padding(.horizontal, Design.Spacing.large)
                .padding(.vertical, Design.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.65))
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
    }
}

/// Opens it, from a process that is still able to.
enum CrashScreenPresenter {
    /// Whether this launch is a crash screen rather than the app.
    static var isCrashLaunch: Bool {
        CommandLine.arguments.contains("--crash-screen")
    }

    static func show() {
        let report = CrashScreen.lastReport()
        // Read once and cleared, so the next ordinary launch is an ordinary
        // launch. A crash screen that reappears forever is its own bug.
        CrashScreen.clearReport()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "MSL"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: CrashScreenView(report: report))
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Runs the crash-screen launch and nothing else.
///
/// Deliberately not the normal app delegate: this process exists to show one
/// window for a program that is already gone, and must not start instances,
/// touch the daemon, or become a second MSL.
final class CrashScreenDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashScreenPresenter.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
