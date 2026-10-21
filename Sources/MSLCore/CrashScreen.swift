import Darwin
import Foundation
import MSLObserver
import Security

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
        /// Not MSL falling over, but MSL's observer saying from outside that
        /// it has. See `MSLObserver` - and note the window reads one note
        /// format and does not care which of them wrote it.
        case observer = "mslod"
    }

    /// Where the last crash left its note, for the window to read.
    public static var reportURL: URL {
        MSLPaths.appSupport.appendingPathComponent("last-crash.txt")
    }

    /// A stop code in the spirit of the thing: readable, specific enough to
    /// grep the logs for, and not pretending to be a diagnosis.
    /// One named way MSL can stop dead.
    ///
    /// **A stop code is a promise, not a label.** The number is stable and
    /// is never reused for a different condition, because the whole point is
    /// that somebody can paste it into an issue - or search it - and find
    /// the same thing every time. Rename the text freely; never renumber.
    ///
    /// `next` is what the person can actually do. It is `nil` for the
    /// unanticipated ones, and that absence is honest: when MSL does not
    /// know what went wrong it must not invent advice.
    public struct StopCode: Equatable, Sendable {
        public let number: UInt32
        public let name: String
        public let happened: String
        public let next: String?
        /// Which part of MSL this is about. nil for the unanticipated ones,
        /// for the same reason `next` is: naming a subsystem MSL has not
        /// actually established was at fault would send somebody looking in
        /// a place nobody has any reason to think is wrong.
        public let subsystem: String?

        public init(number: UInt32, name: String, happened: String, next: String? = nil,
                    subsystem: String? = nil) {
            self.number = number
            self.name = name
            self.happened = happened
            self.next = next
            self.subsystem = subsystem
        }

        /// `0x00000010`, the form that goes on screen and into a search box.
        public var printed: String { String(format: "0x%08X", number) }

        /// The same code, declared by the observer. A plain conversion and
        /// nothing more: the observer owns the words, this type owns how
        /// they are shown.
        public init(_ observer: ObserverStopCode) {
            self.init(number: observer.number, name: observer.name,
                      happened: observer.happened, next: observer.next,
                      subsystem: observer.subsystem)
        }
    }

    /// Every code, which is also how `code(named:)` finds one.
    ///
    /// **One table, including the observer's.** `MSLObserver` is a leaf
    /// target with no dependencies - it cannot import this file - so its
    /// codes are declared there and folded in here rather than written out
    /// twice. Two switches over the same thing is how a name ends up with
    /// one number here and another on screen, which is the mistake the rest
    /// of this file was already written to avoid.
    public static let allStopCodes: [StopCode] =
        ownStopCodes + ObserverStopCode.all.map(StopCode.init)

    /// The ones MSL raises about itself.
    public static let ownStopCodes: [StopCode] = [
        .wentSomewhereItShouldnt, .busTookAWrongTurn, .instructionMakesNoSense,
        .mathsHappened, .gaveUpOnItself, .trippedOverATrap,
        .serviceCannotListen, .signingKeyUnreadable, .keyStoreUnprotected,
        .virtualizationRefused,
    ]

    /// Where the guide that explains a code lives. The crash screen's one
    /// piece of advice that always applies is "read this".
    public static let wikiStopCodes = ObserverWiki.stopCodes

    /// The page for one code, by its anchor, so the screen can send somebody
    /// to the paragraph about the number in front of them rather than to the
    /// top of a long page. nil in, the top of the page out - an uncaught
    /// error has no paragraph of its own to go to.
    public static func wikiPage(for code: StopCode?) -> String {
        guard let code else { return ObserverWiki.stopCodes }
        return ObserverWiki.stopCodes + "#" + code.name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    /// The observer's report on an incident it raised: the code, the detail,
    /// and the tail of everything it saw leading up to it.
    ///
    /// Separate from the log on purpose. The observer's log is **this boot's
    /// only** and goes at the next one; this is the evidence behind a screen
    /// that may not have been read yet, so it survives until it has been.
    public static var observerIncidentURL: URL { ObserverPaths.incident }

    /// Clears the observer's report, once it has been shown.
    public static func clearObserverIncident() {
        try? FileManager.default.removeItem(at: observerIncidentURL)
    }

    /// The code a recorded name belongs to, for the window to show more than
    /// the name. An uncaught exception has no fixed name - it carries the
    /// exception's own - so this answers nil and the window shows what it has.
    public static func code(named name: String) -> StopCode? {
        allStopCodes.first { $0.name == name }
    }

    /// Whether this process is allowed to create virtual machines.
    ///
    /// **Only a definite "no" counts.** `SecTaskCopyValueForEntitlement`
    /// answers nil both for an entitlement that is absent and for a task it
    /// could not read, and crash-screening a Mac because the second happened
    /// would be far worse than the bug being caught. So this returns false
    /// only when the task was readable and the entitlement was not there.
    ///
    /// Verified both ways before being relied on: the same test binary
    /// reports absent unsigned, and present after `codesign --entitlements`
    /// with `com.apple.security.virtualization`.
    public static func canCreateVirtualMachines() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return true }
        // A signing identifier proves the task is readable; without one,
        // nothing can be concluded from a nil entitlement.
        guard SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString,
                                             nil) == nil else { return true }
        guard SecTaskCopySigningIdentifier(task, nil) != nil else { return true }
        return false
    }

    /// Stops MSL on purpose, with a code that says why.
    ///
    /// Unlike the signal path this is not running inside a signal handler,
    /// so it can use Foundation freely - but it keeps the same on-disk note
    /// format, because the window reads one thing.
    public static func stop(_ code: StopCode, detail: String = "") -> Never {
        note(stopCode: code.name, detail: detail.isEmpty ? code.happened : detail)
        present()
        // Out, rather than carrying on in a state MSL has just said it
        // cannot work in.
        exit(EXIT_FAILURE)
    }

    /// The code for a signal, taken from the one table rather than a second
    /// list - two switches over the same thing is how a name ends up with
    /// one number here and another on screen.
    public static func stop(signal: Int32) -> StopCode? {
        switch signal {
        case SIGSEGV: return .wentSomewhereItShouldnt
        case SIGBUS:  return .busTookAWrongTurn
        case SIGILL:  return .instructionMakesNoSense
        case SIGFPE:  return .mathsHappened
        case SIGABRT: return .gaveUpOnItself
        case SIGTRAP: return .trippedOverATrap
        default:      return nil
        }
    }

    public static func stopCode(signal: Int32) -> String {
        stop(signal: signal)?.name ?? "SIGNAL_\(signal)"
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

/// The codes themselves, on the type they belong to, so a call site can
/// say `.serviceCannotListen` and read as the sentence it is.
extension CrashScreen.StopCode {
    // MARK: - The unanticipated ones
    //
    // MSL did not see these coming and has nothing to suggest. They keep
    // their original names: the numbers were added later, and changing a
    // name people may already have searched for would be worse than a
    // slightly odd one.

    public static let wentSomewhereItShouldnt = Self(
        number: 0x01, name: "WENT_SOMEWHERE_IT_SHOULDNT",
        happened: "MSL read or wrote memory that was not its own.")
    public static let busTookAWrongTurn = Self(
        number: 0x02, name: "BUS_TOOK_A_WRONG_TURN",
        happened: "MSL asked for memory the processor could not give it.")
    public static let instructionMakesNoSense = Self(
        number: 0x03, name: "INSTRUCTION_MAKES_NO_SENSE",
        happened: "MSL tried to run something that is not an instruction.")
    public static let mathsHappened = Self(
        number: 0x04, name: "MATHS_HAPPENED",
        happened: "An arithmetic operation had no answer MSL could use.")
    public static let gaveUpOnItself = Self(
        number: 0x05, name: "GAVE_UP_ON_ITSELF",
        happened: "MSL hit a check inside itself that it could not carry on past.")
    public static let trippedOverATrap = Self(
        number: 0x06, name: "TRIPPED_OVER_A_TRAP",
        happened: "MSL ran into a trap left for a debugger.")

    // MARK: - The ones MSL raises on purpose
    //
    // Each of these is a condition MSL **cannot continue past**, detected
    // where it actually happens. They are not the same as the errors that
    // get a sentence and a retry - an instance that will not start, a disk
    // that needs checking - because those leave MSL working. These do not.

    /// 0x10. `mslhd` could not serve its control socket, so nothing can
    /// reach it: not the app, not `msl`, not a Linux app asking for a file.
    public static let serviceCannotListen = Self(
        number: 0x10, name: "SERVICE_CANNOT_LISTEN",
        happened: "MSL's background service could not open the socket everything "
                + "else talks to it on, so nothing can reach it.",
        next: "Another copy of it may already be running. Quit MSL, open it again, "
            + "and if that does not help, restart the Mac.",
        subsystem: "mslhd - the control socket")

    /// 0x11. The signing key is there and cannot be read. MSL must not
    /// generate another - that would orphan every identity on this Mac - so
    /// there is nothing it can do but stop.
    public static let signingKeyUnreadable = Self(
        number: 0x11, name: "SIGNING_KEY_UNREADABLE",
        happened: "The key MSL signs your instances with is there but cannot be read. "
                + "MSL will not replace it: a new key would make every instance on "
                + "this Mac unverifiable, permanently.",
        next: "Check that /Users/Shared/MSL and the machine-key file inside it still "
            + "belong to you and are readable.",
        subsystem: "instance identity - the machine key")

    /// 0x12. The store that decides which policies are honoured is writable
    /// by somebody else, so every signature check fails closed - on a Mac
    /// that is actually managed, that means the administrator's rules have
    /// silently stopped applying.
    public static let keyStoreUnprotected = Self(
        number: 0x12, name: "KEY_STORE_UNPROTECTED",
        happened: "This Mac is managed, but the folder holding the administrator's "
                + "keys can be written by other accounts - so signed policies no "
                + "longer verify and the rules have stopped applying.",
        next: "An administrator can repair it with: "
            + "sudo chown -R root /Users/Shared/MSL && sudo chmod -R go-w /Users/Shared/MSL",
        subsystem: "MSL Admin Portal - the key store")

    /// 0x13. macOS will not let this build create a virtual machine, so no
    /// instance can ever start. Almost always a copy of `mslhd` that was
    /// moved into place by hand instead of installed.
    public static let virtualizationRefused = Self(
        number: 0x13, name: "VIRTUALIZATION_REFUSED",
        happened: "macOS will not let this copy of MSL's service create a virtual "
                + "machine, so no instance can start.",
        next: "Install MSL from its package rather than copying the files in: the "
            + "permission is part of the signature and does not survive a plain copy.",
        subsystem: "mslhd - the virtualization entitlement")
}
