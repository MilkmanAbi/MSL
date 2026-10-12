import Darwin
import Foundation

/// A signal handler is a plain C function pointer, so it can capture
/// nothing - which is why everything it needs is static on `CrashScreen`.
private func crashSignalHandler(_ raised: Int32) {
    CrashScreen.handle(signal: raised)
}

/// The screen MSL puts up when it has nothing useful left to say.
///
/// Every other failure in MSL gets a sentence explaining what happened and
/// what to do. This is for the ones that do not: a signal, an uncaught
/// exception, something MSL genuinely did not anticipate. Pretending to
/// explain those would be worse than admitting it, so it admits it.
///
/// ## What it must not do
///
/// **Swallow the crash report.** macOS writes a `.ips` with a backtrace,
/// and that file is the only thing that ever makes a crash like this
/// fixable - MSL's own notes say to read it first. So the handler shows the
/// window and then *re-raises the signal with the default handler*, letting
/// the process die exactly as it would have. Nothing is traded away for the
/// screen.
///
/// **Block in a signal handler.** Almost nothing is safe to call from one.
/// This does the minimum: writes a short line with `write(2)`, spawns the
/// viewer with `posix_spawn`, and gets out.
public enum CrashScreen {

    /// Which part of MSL fell over. The screen itself says nothing useful,
    /// so this is what makes the log worth opening.
    public enum Component: String, Sendable {
        case app = "MSLApp"
        case daemon = "mslhd"
        case cli = "msl"
        case files = "MSLFiles"
    }

    /// Where the last crash left its note, for the window to read.
    public static var reportURL: URL {
        MSLPaths.appSupport.appendingPathComponent("last-crash.txt")
    }

    /// A stop code in the spirit of the thing: readable, specific enough to
    /// grep the logs for, and not pretending to be a diagnosis.
    public static func stopCode(signal: Int32) -> String {
        let name: String
        switch signal {
        case SIGSEGV: name = "WENT_SOMEWHERE_IT_SHOULDNT"
        case SIGBUS:  name = "BUS_TOOK_A_WRONG_TURN"
        case SIGILL:  name = "INSTRUCTION_MAKES_NO_SENSE"
        case SIGFPE:  name = "MATHS_HAPPENED"
        case SIGABRT: name = "GAVE_UP_ON_ITSELF"
        case SIGTRAP: name = "TRIPPED_OVER_A_TRAP"
        default:      name = "SIGNAL_\(signal)"
        }
        return name
    }

    public static func stopCode(exception name: String) -> String {
        "UNCAUGHT_" + name.uppercased()
            .replacingOccurrences(of: "NSEXCEPTION", with: "")
            .replacingOccurrences(of: ".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Installing

    nonisolated(unsafe) private static var component: Component = .app
    nonisolated(unsafe) private static var viewerPath: String = ""
    nonisolated(unsafe) private static var installed = false

    /// **Everything the handler needs, as plain C strings, worked out
    /// before anything has gone wrong.**
    ///
    /// The first version computed the report path inside the handler -
    /// `MSLPaths.appSupport`, `URL`, `appendingPathComponent`. All
    /// Foundation, none of it safe to call from a signal handler, and it
    /// silently did nothing: the screen appeared and the note never got
    /// written, so there was a crash screen with nothing to say. Which is
    /// precisely what the comment above it warned about.
    nonisolated(unsafe) private static var reportPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var viewerPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var componentC: UnsafeMutablePointer<CChar>?

    /// Starts catching the unrecoverable ones.
    ///
    /// `viewer` is the executable that can put a window on screen - the app
    /// itself, usually. A daemon has no UI of its own, so it spawns the app
    /// with `--crash-screen` rather than trying to draw anything.
    public static func install(for component: Component, viewer: String?) {
        guard !installed else { return }
        installed = true
        Self.component = component
        Self.viewerPath = viewer ?? ""
        // Resolved now, while Foundation is safe to call.
        Self.reportPathC = strdup(reportURL.path)
        Self.viewerPathC = (viewer?.isEmpty == false) ? strdup(viewer!) : nil
        Self.componentC = strdup(component.rawValue)


        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            sigemptyset(&action.sa_mask)
            // Reset to the default on entry, so the re-raise below actually
            // kills the process instead of looping back into here.
            action.sa_flags = Int32(SA_RESETHAND)
            sigaction(signal, &action, nil)
        }

        NSSetUncaughtExceptionHandler { exception in
            CrashScreen.note(stopCode: CrashScreen.stopCode(exception: exception.name.rawValue),
                             detail: exception.reason ?? "no reason given")
            CrashScreen.present()
        }
    }

    /// The signal path. Everything here has to be safe to call from a
    /// signal handler, which rules out most of Foundation.
    static func handle(signal raised: Int32) {
        note(stopCode: stopCode(signal: raised), detail: "signal \(raised)")
        present()
        // And then die properly, so macOS still writes the .ips with the
        // backtrace. The screen is a courtesy; the crash report is the
        // thing that gets this fixed.
        raise(raised)
    }

    /// Leaves a line behind for the window - and for whoever reads the logs
    /// later, which is the part that actually matters.
    public static func note(stopCode: String, detail: String) {
        // Uses the path resolved at install time, so this is just open,
        // write, close - all of which are safe from a signal handler.
        guard let path = reportPathC else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        if let componentC { _ = write(fd, componentC, strlen(componentC)) }
        _ = "\t".withCString { write(fd, $0, 1) }
        _ = stopCode.withCString { write(fd, $0, strlen($0)) }
        _ = "\t".withCString { write(fd, $0, 1) }
        _ = detail.withCString { write(fd, $0, strlen($0)) }
        _ = "\n".withCString { write(fd, $0, 1) }
        close(fd)
    }

    /// Puts the window up, in whatever process can draw one.
    public static func present() {
        guard let viewer = viewerPathC else { return }
        var pid: pid_t = 0
        // Built once at install time for the same reason: no allocation,
        // no Foundation, nothing that can take a lock a dying process may
        // already be holding.
        var argv: [UnsafeMutablePointer<CChar>?] = [viewer, crashFlagC, nil]
        _ = posix_spawn(&pid, viewer, nil, nil, &argv, environ)
    }

    nonisolated(unsafe) private static let crashFlagC = strdup("--crash-screen")

    /// What the last crash was, for the window to show. nil when MSL has
    /// not fallen over - which is the normal case and should stay that way.
    public static func lastReport() -> (component: String, stopCode: String, detail: String)? {
        guard let text = try? String(contentsOf: reportURL, encoding: .utf8) else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard fields.count >= 2 else { return nil }
        return (fields[0], fields[1], fields.count > 2 ? fields[2] : "")
    }

    public static func clearReport() {
        try? FileManager.default.removeItem(at: reportURL)
    }
}
