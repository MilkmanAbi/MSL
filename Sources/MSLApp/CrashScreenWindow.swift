import AppKit
import MSLCore
import MSLObserver
import SwiftUI

/// The screen MSL puts up when it has run out of explanations.
///
/// Shown as its own window, from its own launch (`--crash-screen`), because
/// the process that crashed is in no condition to draw anything - a daemon
/// has no UI at all, and an app that just took a SIGSEGV has seconds to
/// live. So the handler spawns this and then lets the original die
/// properly, keeping the crash report macOS writes.
///
/// ## Two halves, on purpose
///
/// The picture is funny. It is allowed to be: there is nothing useful to say
/// in the moment somebody's work disappears, and pretending otherwise is
/// worse than a joke. But a funny picture is **all** this screen used to be,
/// and somebody looking at it had no way to tell a real failure from MSL
/// being dramatic - no code, no component, no time, nothing to quote.
///
/// So the right-hand side is the opposite of the left: a plain report, in the
/// order somebody actually needs it. What stopped, which part of MSL it was
/// about, which part noticed, when, what it measured, and where to read more.
/// It is deliberately unstyled and unexciting. The picture gets the feeling;
/// this gets the facts.
struct CrashScreenView: View {
    let report: (component: String, stopCode: String, detail: String)?
    /// The observer's own report, when it was the observer that raised this.
    let incident: ObserverIncident?

    private var code: CrashScreen.StopCode? {
        report.flatMap { CrashScreen.code(named: $0.stopCode) }
    }

    var body: some View {
        HStack(spacing: 0) {
            picture
            if report != nil {
                Divider()
                ScrollView { sidebar }
                    .frame(width: 360)
                    .background(Color(red: 0.08, green: 0.09, blue: 0.12))
            }
        }
        .frame(minWidth: 980, minHeight: 520)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
    }

    // MARK: - The left-hand side

    private var picture: some View {
        ZStack {
            // The picture carries the whole feeling of the thing. It is
            // deliberately unhelpful about the cause, which is the honest
            // position when nothing knows what went wrong - and it carries
            // the guide's address and a code of the same, for a photograph
            // taken on a phone.
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The right-hand side

    @ViewBuilder
    private var sidebar: some View {
        if let report {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                heading
                stopCodeBlock(report)
                if let code {
                    section("What happened", code.happened)
                    // Only when there is something to do. For the
                    // unanticipated ones there is not, and inventing advice
                    // would be worse than the silence.
                    if let next = code.next { section("What to do", next) }
                } else if !report.detail.isEmpty {
                    section("What happened", report.detail)
                }
                Divider().overlay(Color.white.opacity(0.15))
                facts(report)
                Divider().overlay(Color.white.opacity(0.15))
                reference
                buttons(report)
                Spacer(minLength: 0)
            }
            .padding(Design.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The line that answers the question the picture provokes: is this real?
    private var heading: some View {
        HStack(spacing: Design.Spacing.small) {
            Circle().fill(Color(red: 0.95, green: 0.35, blue: 0.3)).frame(width: 8, height: 8)
            Text("THIS IS A REAL MSL ERROR")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .kerning(1.2)
        }
    }

    private func stopCodeBlock(_ report: (component: String, stopCode: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The number first, in the form somebody can search for. A bare
            // name told them nothing they could look up; a number that never
            // moves does.
            Text(code?.printed ?? incident?.code ?? "no stop code")
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
            Text(code?.name ?? report.stopCode)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.4))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The part somebody copies into a bug report: what, where, who noticed,
    /// when, and what was actually measured.
    private func facts(_ report: (component: String, stopCode: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("Subsystem", code?.subsystem ?? incident?.subsystem ?? "not established")
            fact("Reported by", Self.reporter(component: report.component,
                                              incident: incident))
            fact("Recorded", Self.recordedDescription(incident?.recorded))
            fact("Build", incident?.version ?? MSLVersion.display)
            // What the observer measured, in numbers - the difference
            // between "something is wrong" and a report worth reading.
            let evidence = incident?.observed ?? report.detail
            if !evidence.isEmpty { fact("Evidence", evidence) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The address, as selectable text and not only as a button.
    ///
    /// Somebody reading this screen is often looking at a photograph of it
    /// taken on a phone, or at a Mac whose MSL will not open. A button helps
    /// neither of them.
    private var reference: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("REFERENCE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.1)
            Text(referenceURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1.0))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var referenceURL: String {
        incident?.reference ?? CrashScreen.wikiPage(for: code)
    }

    private func buttons(_ report: (component: String, stopCode: String, detail: String)) -> some View {
        VStack(spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Button("Read the guide") {
                    guard let url = URL(string: referenceURL) else { return }
                    NSWorkspace.shared.open(url)
                }
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.details(for: report, incident: incident),
                                                   forType: .string)
                }
            }
            HStack(spacing: Design.Spacing.small) {
                Button("Open the log") {
                    // The log is where a crash like this actually gets
                    // diagnosed - the picture is only there to be honest
                    // about MSL not knowing.
                    //
                    // Which log depends on who is talking. An incident raised
                    // by MSL's observer is explained by the observer's own
                    // record of the minutes before it, not by mslhd's - and
                    // that record is this boot's only, so now is the time.
                    let logs = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/MSL")
                    let file = report.component == "mslod" ? "observer.log" : "mslhd.log"
                    NSWorkspace.shared.selectFile(
                        logs.appendingPathComponent(file).path,
                        inFileViewerRootedAtPath: logs.path)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(.top, Design.Spacing.small)
    }

    // MARK: - Wording

    /// Who noticed. Saying "MSL's observer" rather than `mslod` matters: the
    /// component that *reported* a failure is almost never the one that had
    /// it, and a person reading `mslod` has no way to know that.
    static func reporter(component: String, incident: ObserverIncident?) -> String {
        switch component {
        case "mslod": return incident?.reportedBy ?? "mslod - MSL's observer"
        case "mslhd": return "mslhd - MSL's background service, about itself"
        case "MSLApp": return "MSL, about itself"
        case "MSLFiles": return "MSL Files, about itself"
        case "msl": return "the msl command, about itself"
        default: return component
        }
    }

    static func recordedDescription(_ date: Date?) -> String {
        guard let date else { return "just now" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Everything an issue needs, on the clipboard in one go - and, when
    /// MSL's observer raised this, the record of what it saw beforehand.
    ///
    /// That last part is why the observer writes a report separately from its
    /// log: the log is this boot's only, and somebody reading this screen may
    /// well restart the Mac next.
    static func details(for report: (component: String, stopCode: String, detail: String),
                        incident: ObserverIncident?) -> String {
        let code = CrashScreen.code(named: report.stopCode)
        var lines = [code.map { "\($0.printed) \($0.name)" } ?? report.stopCode,
                     "subsystem: \(code?.subsystem ?? incident?.subsystem ?? "not established")",
                     "reported by: \(reporter(component: report.component, incident: incident))",
                     "recorded: \(recordedDescription(incident?.recorded))",
                     MSLVersion.display,
                     report.detail]
        if let incident {
            lines.append("")
            lines.append(incident.body)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
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
        let incident = report?.component == "mslod" ? ObserverIncident.read() : nil
        // Read once and cleared, so the next ordinary launch is an ordinary
        // launch. A crash screen that reappears forever is its own bug.
        CrashScreen.clearReport()
        // The observer's report goes with it, now that it has been read into
        // the window - leaving it behind would attach this incident to the
        // *next* crash screen, which would be a lie about a different one.
        CrashScreen.clearObserverIncident()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "MSL"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: CrashScreenView(report: report, incident: incident))
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
