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
        // Launching Linux apps at all. Checked before the display is
        // prepared, so a denied instance does not start an X server it
        // will never use.
        guard MSLAPGate.allows("apps.launch", instance: instance) else {
            throw MSLAPRefusal(MSLAPGate.reason("apps.launch", instance: instance)
                               ?? "Not allowed by the MSL Admin Portal")
        }
        try prepareDisplay(instance: instance, distro: distro, log: log)

        // As the user's own account, never root. The shell protocol treats an
        // empty user as root, which is what every launched app used to get.
        let user = GuestUser.shellUser(instance: instance, distro: distro)
        log?("running: \(command)\(GuestUser.isRoot(user) ? " (as root - no Linux account yet)" : " (as \(user))")")
        let client = ShellClient()
        if let custom = AppCustomCommandStore.command(instance: instance, command: command) {
            log?("custom launch command: \(custom)")
        }
        let guestCommand = GuestIntegration.launchCommand(
            command, instance: instance, settings: MSLExperimentalSettingsStore.load())
        var (exitCode, output) = try client.runOneShotCommand(
            instance: instance, distro: distro, command: guestCommand, user: user
        )

        // One retry when the app could not open the display.
        //
        // "x11tunnel ready" proves the guest can reach the tunnel; it does
        // not prove the HOST is serving yet. A freshly started tunnel
        // accepts a connection happily while `mslhd`'s listener is still
        // coming up, and the client gets a connection that closes on it -
        // so the first app launched after a cold VM boot sometimes dies
        // instantly with "cannot open display :1". Measured 2026-09-23:
        // one failure in three cold boots, so a race rather than something
        // deterministic, and the app that fails is always the first one.
        //
        // Retried rather than fixed with a stronger readiness probe on
        // purpose: an end-to-end probe means completing an X11 handshake
        // from the guest, and a bare probe client announces itself like
        // any other app (`x11tunnel --announce`), which starts a host
        // process for the probe. That is a bigger change than the bug
        // justifies. `startTunnel` already self-heals the same way.
        if exitCode != 0, Self.looksLikeDisplayNotReady(output) {
            log?("display was not ready yet - preparing it again and retrying once")
            try? prepareDisplay(instance: instance, distro: distro, log: log)
            (exitCode, output) = try client.runOneShotCommand(
                instance: instance, distro: distro, command: guestCommand, user: user
            )
        }

        if !output.isEmpty { log?(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        log?("exited with code \(exitCode)")
        return (exitCode, output)
    }

    /// Whether a failed launch looks like "the display was not up yet"
    /// rather than a real problem with the app.
    ///
    /// Matched on the toolkits' own wording. Deliberately narrow: a retry
    /// must never fire for an app that genuinely failed, or a crash on
    /// startup becomes two crashes.
    static func looksLikeDisplayNotReady(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("cannot open display")       // GTK, Xlib
            || lowered.contains("can't open display")        // Xt ("Xt error: Can't open display")
            || lowered.contains("could not connect to display") // Qt/xcb
            || lowered.contains("failed to open display")
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
        // `isNewline`, not "\n": the guest runs on a pty and sends CRLF, which
        // Swift treats as a single Character, so splitting on "\n" would hand
        // back the whole output as one "line".
        let detail = output.split(whereSeparator: \.isNewline).suffix(4)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
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

        // A real user session first: snap will not run without one, and
        // portals look for /run/user/<uid>. Root-side, idempotent, and a
        // no-op on a guest without logind - see
        // `GuestIntegration.userSessionCommand`.
        let account = GuestUser.shellUser(instance: instance, distro: distro)
        // Both of these need root, and the second one is why a shell used to
        // get nothing: the profile stub lives in /etc, which the user account
        // cannot write, so running it as the user wrote nothing and failed
        // silently (`|| true`). Sent together to save a round trip, and run
        // even when the account IS root - the stub is what a login shell
        // reads either way.
        // **The session command runs in a subshell, and that is load-bearing.**
        // It begins `command -v loginctl || { …; exit 0; }`, so on a guest
        // without logind - Alpine, which is OpenRC - that `exit` ended the
        // whole `sh -c` and everything after it was silently skipped. The
        // profile stub below is what gives a shell its DISPLAY and session
        // bus, so on Alpine alone, typing an app's name at a prompt failed
        // with "Failed to open display" while every systemd distro worked
        // (reported 2026-10-02). Parenthesised, its `exit` leaves only itself.
        let session = GuestUser.isRoot(account)
            ? "" : "(\n" + GuestIntegration.userSessionCommand(user: account) + "\n)\n"
        _ = try? ShellClient().runOneShotCommand(
            instance: instance, distro: distro,
            command: session + GuestIntegration.sessionProfileCommand(),
            user: "")

        log?("starting the native GUI server for \(instance)")
        // Retried, because `ensureRunning` above can return the moment the
        // daemon's socket exists while it is still coming up - and because a
        // daemon that has just been replaced (an MSL upgrade, a developer
        // build) is unreachable for a second or two. Clicking an app in that
        // window failed outright with "couldn't reach mslhd". The request
        // itself is idempotent: it starts the X11 server for an instance, or
        // says it already did.
        var response: String?
        for attempt in 0..<10 {
            response = DaemonClient.send(.startNativeGui(instance: instance))
            if response != nil { break }
            if attempt < 9 { usleep(400_000) }
        }
        guard let response else {
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
        // The audio setup goes before the tunnel start, never after: it
        // ends in `|| true`, and as the last line it would hide a failed
        // tunnel from the exit-code check below.
        // `sessionEnvFileCommand` writes the per-user half of the session
        // environment, in the user's own home, with the settings as they are
        // right now - which is what keeps a shell in step with the Mac's
        // experimental switches. Its root half (the profile stub that sources
        // it) went out in `prepareDisplay`.
        let start = GuestIntegration.installCommand() + "\n" + GuestIntegration.displayProfileCommand()
            + "\n" + GuestIntegration.sessionEnvFileCommand(settings: MSLExperimentalSettingsStore.load())
            + "\n" + GuestIntegration.sessionAudioCommand
            + "\n" + GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        // Also as the user: the tunnel writes its pidfile and the display
        // socket in /tmp, and `GuestIntegration.installCommand` writes the kit
        // into $HOME. Started as root, the kit landed in root's home, where
        // the app that needs it never looks.
        let client = ShellClient()
        var (code, output) = try client.runOneShotCommand(
            instance: instance, distro: distro, command: start,
            user: GuestUser.shellUser(instance: instance, distro: distro))

        // Self-healing, once. Both failures below mean the same thing: an
        // earlier tunnel that ran as root left files the user cannot
        // touch - in `/tmp` and in the sticky `/tmp/.X11-unix` - and the
        // shipped images carry them from their own build. Clearing them
        // needs root, so MSL does that itself rather than leaving someone
        // with an app that will never open. See
        // `GuestIntegration.tunnelCleanupCommand`.
        // Any failure, not only the two messages this used to look for: the
        // display can be unusable in ways that never reach the tunnel's own
        // output at all, and the cleanup is safe to run whenever a start has
        // just failed.
        if code != 0 {
            log?("clearing a stale display socket left by an earlier session")
            _ = try? client.runOneShotCommand(
                instance: instance, distro: distro,
                command: GuestIntegration.tunnelCleanupCommand(display: 1, port: 5003),
                user: "")
            (code, output) = try client.runOneShotCommand(
                instance: instance, distro: distro, command: start,
                user: GuestUser.shellUser(instance: instance, distro: distro))
        }
        guard code == 0 else {
            throw LaunchError.tunnelFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log?("x11tunnel ready")
    }
}
