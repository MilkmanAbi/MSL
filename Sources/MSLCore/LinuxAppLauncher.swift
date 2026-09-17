import Foundation

/// Starts one Linux GUI application on mslgd (this project's own X11
/// server) from a host process that has **no controlling terminal** - a
/// generated `.app` bundle launched by LaunchServices, or anything else
/// started by launchd.
///
/// This deliberately does not shell out to `msl gui-native`, even though
/// that verb does the same four steps. `msl`'s session path
/// (`runShellSession`) relays *stdin*, and half-closes the vsock's write
/// side the moment stdin hits EOF so the guest shell gets its SIGHUP - the
/// correct behaviour for a terminal. A bundle's stdin is `/dev/null`, where
/// the very first `read()` returns 0, so that path tears the session down
/// within milliseconds of starting it and the daemon then auto-suspends the
/// VM three seconds later. (This is also, in hindsight, why backgrounded
/// `nohup ... </dev/null &` keepalives kept dying during GUI testing.)
///
/// `ShellClient` has no such problem: it sends one EXEC frame, never reads
/// stdin, and never half-closes - so it is the right base for anything
/// headless, and this builds on it.
public enum LinuxAppLauncher {
    public enum LaunchError: Error, CustomStringConvertible {
        case daemonRefused(String)
        case tunnelFailed(String)

        public var description: String {
            switch self {
            case .daemonRefused(let reason): return reason
            case .tunnelFailed(let reason): return "couldn't start the X11 tunnel in the guest: \(reason)"
            }
        }
    }

    /// Brings up everything `command` needs and then runs it, **blocking
    /// until the Linux application exits**.
    ///
    /// Blocking is the point, not an inconvenience: for as long as this
    /// call is outstanding the daemon counts a live session for `instance`,
    /// which is what stops it auto-suspending the VM out from under a
    /// running app. The caller is expected to be a process whose whole job
    /// is to be that app's macOS-side lifetime.
    ///
    /// Returns the guest command's exit code.
    @discardableResult
    public static func run(
        instance: String,
        distro: GuestDistro,
        command: String,
        log: ((String) -> Void)? = nil
    ) throws -> Int32 {
        try runCapturingOutput(instance: instance, distro: distro, command: command, log: log).exitCode
    }

    /// `run`, also handing back what the app printed - for explaining a
    /// launch that failed (`failureMessage`).
    public static func runCapturingOutput(
        instance: String,
        distro: GuestDistro,
        command: String,
        log: ((String) -> Void)? = nil
    ) throws -> (exitCode: Int32, output: String) {
        try prepareDisplay(instance: instance, distro: distro, log: log)

        log?("running: \(command)")
        let client = ShellClient()
        let (exitCode, output) = try client.runOneShotCommand(
            instance: instance, distro: distro,
            command: GuestIntegration.launchCommand(command, settings: MSLExperimentalSettingsStore.load())
        )
        if !output.isEmpty { log?(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        log?("exited with code \(exitCode)")
        return (exitCode, output)
    }

    /// What to tell the user about a launch that ended, or nil when there is
    /// nothing worth interrupting them for.
    ///
    /// Launches used to fail in silence: the Run button and the generated
    /// `.app`s wrote exit 127 to a log nobody reads, and nothing appeared on
    /// screen (2026-09-16). "Not found" and "not executable" are always
    /// reported. Any other non-zero exit is reported only when the app died
    /// within `quickExit` seconds - after that it is an app the user was
    /// using, and how it chose to exit is its own business.
    public static let quickExit: TimeInterval = 5

    public static func failureMessage(
        appName: String, instance: String, command: String,
        exitCode: Int32, output: String, runTime: TimeInterval
    ) -> String? {
        let program = command.split(separator: " ").first.map(String.init) ?? command
        let detail = output.split(separator: "\n").suffix(4).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case 0:
            return nil
        case 127:
            return "\(program) isn't installed in \(instance), or isn't on its PATH. Install \(appName) in \(instance) again, then refresh its applications."
        case 126:
            return "\(program) exists in \(instance) but couldn't be run - it may not be executable."
                + (detail.isEmpty ? "" : "\n\n" + detail)
        default:
            guard runTime < quickExit else { return nil }
            return "\(appName) quit right away (exit code \(exitCode))."
                + (detail.isEmpty ? "" : "\n\n" + detail)
        }
    }

    /// Makes MSL's display usable in `instance`: the host's X11 server for
    /// it, the guest's tunnel to that server, and `DISPLAY` for every shell.
    ///
    /// Shared by launched apps and by every `msl` shell session - the app's
    /// Terminal tab and Terminal.app alike - so a Linux GUI app started from
    /// a prompt opens as a Mac window exactly as one started from the
    /// Applications tab does. Idempotent and cheap once done: the server is
    /// already up and the tunnel's pidfile check returns at once.
    public static func prepareDisplay(instance: String, distro: GuestDistro, log: ((String) -> Void)? = nil) throws {
        try DaemonClient.ensureRunning(log: log)

        log?("starting the native GUI server for \(instance)")
        guard let response = DaemonClient.send(.startNativeGui(instance: instance)) else {
            throw LaunchError.daemonRefused("couldn't reach mslhd")
        }
        guard response.hasPrefix("OK") else {
            // This is where the concurrent-VM cap surfaces, among other
            // things - pass the daemon's own wording straight through
            // rather than inventing a vaguer one.
            throw LaunchError.daemonRefused(String(response.dropFirst(2).drop(while: { $0 == " " })))
        }

        try startTunnel(instance: instance, distro: distro, log: log)
    }

    /// Starts `x11tunnel` in the guest if it isn't already running.
    ///
    /// Liveness is checked through the pidfile, never `pgrep -f x11tunnel`:
    /// that self-matches the very command line doing the checking, so it
    /// always "finds" a tunnel and never starts one. `--announce` is what
    /// makes each client tell the host its application name, which is what
    /// gives each Linux app its own Dock tile - see `X11AppIdentity`.
    ///
    /// Descriptors 3-9 are closed before the tunnel starts. Images built
    /// before 2026-09-14 hand the session's own vsock connection to
    /// everything its shell runs; a tunnel that inherits it keeps the session
    /// open after this command ends, so this call never returned and the
    /// first app launched after each boot never started. `exec` keeps the pid
    /// `$!` recorded, so the pidfile stays right.
    ///
    /// The MSL integration kit (`GuestIntegration`) is refreshed in the same
    /// command, to save a round trip per launch. It cannot fail the launch.
    private static func startTunnel(instance: String, distro: GuestDistro, log: ((String) -> Void)?) throws {
        let start = GuestIntegration.installCommand() + "\n" + GuestIntegration.displayProfileCommand() + "\n" + """
        kill -0 $(cat /tmp/x11tunnel-1-5003.pid 2>/dev/null) 2>/dev/null || \
        (setsid sh -c 'exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; exec /usr/local/bin/x11tunnel 1 5003 --announce' </dev/null >/tmp/x11tunnel-native.log 2>&1 & \
        echo $! > /tmp/x11tunnel-1-5003.pid; sleep 1; \
        kill -0 $(cat /tmp/x11tunnel-1-5003.pid) 2>/dev/null || \
        (cat /tmp/x11tunnel-native.log >&2; exit 1))
        """
        let client = ShellClient()
        let (code, output) = try client.runOneShotCommand(instance: instance, distro: distro, command: start)
        guard code == 0 else {
            throw LaunchError.tunnelFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log?("x11tunnel ready")
    }
}
