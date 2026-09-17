import Foundation
import MSLCore
#if canImport(Darwin)
import Darwin
#endif

/// Connects to `mslhd`, starting it if it isn't running, and exits with a
/// message if it can't be reached at all.
///
/// The start attempt is not decoration. Nothing in this CLI used to start
/// the daemon - only MSL.app did (`RootView`) - so any state where the
/// LaunchAgent is loaded but the job isn't running, or the job has been
/// booted out entirely, left every `msl` command answering "couldn't reach
/// mslhd" until the user thought to open the app. The installer's
/// `postinstall` boots the old daemon out on purpose during an upgrade,
/// which is exactly that state: measured on 2026-09-16, `msl list`
/// immediately after an install failed for this reason.
func connectToDaemon() -> Int32 {
    if let fd = bestEffortConnectToDaemon() { return fd }
    // A Mac that has only just installed MSL has the app and this command,
    // but nothing in `bin/` yet - the app installs its tools on first
    // launch, and in a terminal-first install this *is* the first thing to
    // run. Install them from beside whatever binary is running (the app
    // bundle, via /usr/local/bin/msl, or a build), so `msl install debian`
    // works without anyone being told to open the app first.
    if !FileManager.default.isExecutableFile(atPath: MSLPaths.tool("mslhd").path) {
        if let source = HostToolInstaller.toolSourceDirectory {
            FileHandle.standardError.write("msl: first run - installing MSL's tools into \(MSLPaths.binDirectory.path)\n".data(using: .utf8)!)
            let result = HostToolInstaller.install(from: source)
            for (tool, reason) in result.failed {
                FileHandle.standardError.write("msl: couldn't install \(tool): \(reason)\n".data(using: .utf8)!)
            }
        }
    }
    // `ensureRunning` writes the LaunchAgent if it's missing, bootstraps a
    // job that was booted out, kickstarts it and waits for it to accept
    // connections - so by the time it returns there is something to talk to.
    do {
        try DaemonClient.ensureRunning()
    } catch {
        FileHandle.standardError.write("msl: couldn't start mslhd - \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    guard let fd = bestEffortConnectToDaemon() else {
        FileHandle.standardError.write("msl: couldn't reach mslhd - is it running? (launchctl list | grep msl)\n".data(using: .utf8)!)
        exit(1)
    }
    return fd
}

/// Sends a control request and prints its single-line text response
/// ("OK ..." / "ERROR ..."), exiting with a matching status code. Used by
/// every subcommand except the interactive shell session, which has its
/// own response handling (a status byte + fd handoff, not a text line).
func runControl(_ request: DaemonProtocol.ControlRequest) -> Never {
    let fd = connectToDaemon()
    defer { close(fd) }
    _ = request.encode().withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard let line = DaemonProtocol.readLine(fd: fd) else {
        FileHandle.standardError.write("msl: no response from mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    print(line)
    exit(line.hasPrefix("OK") ? 0 : 1)
}

/// Like `connectToDaemon()` but never exits the process on failure -
/// returns `nil` instead. For internal, best-effort control-channel uses
/// (session-end notification, `--shutdown`'s per-instance status checks)
/// where an unreachable daemon shouldn't be treated as fatal the way it is
/// for a normal foreground command.
func bestEffortConnectToDaemon() -> Int32? {
    let socketPath = DaemonProtocol.defaultSocketPath()
    let controlFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard controlFD >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
            socketPath.withCString { strncpy(cptr, $0, 103) }
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(controlFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        close(controlFD)
        return nil
    }
    return controlFD
}

/// Sends a control request and returns the daemon's single-line text
/// response, without exiting the process - unlike `runControl`, for
/// callers that need to keep running afterward (e.g. `--shutdown`, which
/// may do this for several instances in one invocation). `nil` on any
/// failure to reach the daemon or get a response.
func sendControlRequest(_ request: DaemonProtocol.ControlRequest) -> String? {
    guard let fd = bestEffortConnectToDaemon() else { return nil }
    defer { close(fd) }
    _ = request.encode().withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return DaemonProtocol.readLine(fd: fd)
}

/// Fire-and-forget notification that this session's relay loop has ended -
/// see `DaemonProtocol.ControlRequest.sessionEnded`'s doc comment for why
/// (drives auto-suspend once the last session for an instance closes).
/// Never blocks on or reports a response; an unreachable daemon at this
/// point just means the active-session count leaks - see that same doc
/// comment on why that's an acceptable failure mode.
func notifySessionEnded(instance: String) {
    guard let fd = bestEffortConnectToDaemon() else { return }
    defer { close(fd) }
    _ = DaemonProtocol.ControlRequest.sessionEnded(instance: instance).encode().withUnsafeBytes {
        write(fd, $0.baseAddress, $0.count)
    }
}

func currentWindowSize() -> (rows: UInt16, cols: UInt16) {
    var ws = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
    return (ws.ws_row, ws.ws_col)
}

func setRawMode() -> termios {
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return original
}

func restoreMode(_ original: termios) {
    var t = original
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
}

/// Writes every byte of `bytes` to `fd`, looping past partial writes -
/// `write()` is allowed to write less than asked even for a normal
/// pipe/socket fd under load, and this is now the sole path for both
/// shell-frame bytes and raw stdout bytes, so it's worth getting right
/// rather than assuming a single `write()` call always finishes the job.
func writeFull(fd: Int32, bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeBytes { ptr in
        var sent = 0
        let base = ptr.baseAddress!
        while sent < ptr.count {
            let n = write(fd, base + sent, ptr.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}

func readFullOrNil(fd: Int32, count: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
        let base = ptr.baseAddress!
        while got < count {
            let n = read(fd, base + got, count - got)
            if n <= 0 { return false }
            got += n
        }
        return true
    }
    return ok ? buf : nil
}

/// Reads one shell-protocol frame off `fd` - see `ShellProtocol`'s doc
/// comment for the wire format. `nil` on EOF/error/an unrecognized frame
/// type (shellinit never sends one, so treating that as a hard stop rather
/// than trying to skip and resync is fine).
func readShellFrame(fd: Int32) -> (type: ShellProtocol.FrameType, payload: [UInt8])? {
    guard let header = readFullOrNil(fd: fd, count: 5) else { return nil }
    guard let type = ShellProtocol.FrameType(rawValue: header[0]) else { return nil }
    let len = (UInt32(header[1]) << 24) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 8) | UInt32(header[4])
    guard len > 0 else { return (type, []) }
    guard let payload = readFullOrNil(fd: fd, count: Int(len)) else { return nil }
    return (type, payload)
}

/// Set from the SIGWINCH handler below - must be a top-level global, not a
/// local captured by the closure: `signal()` needs a plain C function
/// pointer, which can't capture context.
var needsResize: Int32 = 0

/// Runs a shell session against `instance`: interactive (a real login
/// shell, full job control via a genuine pty on the guest side - see
/// `Guest/init/shellinit.c`) when `command` is empty, or a single one-shot
/// command otherwise (ssh-style: `sh -c "<command>"` in the guest, this
/// process's own exit code set to match the guest's when it's done - see
/// `ShellProtocol`'s EXIT frame). `distro` only takes effect the first time
/// `instance` is created (see `InstanceRegistry.ensureRegistered`) - it's
/// ignored for an already-registered instance. `user` empty means root
/// (unchanged default); an unknown user fails fast - exit code 127, no
/// other output, no pty ever created guest-side - matching how "command
/// not found" already reads, since the host has no way to know a user
/// exists without asking the guest, the same as with any command.
/// Instances whose VM is up on `distro`'s disk image. The image is shared by
/// every instance of the distro, so "is *this* instance running" is the
/// wrong question before resizing it: `msl new tmp --disk 32G` would have
/// resized Debian's disk under a different, running Debian instance.
func runningInstances(using distro: GuestDistro) -> [String] {
    registryForLookup.entries().filter { $0.value == distro }.map(\.key).filter { name in
        guard let line = sendControlRequest(.status(instance: name)) else { return false }
        return line == "OK running" || line == "OK paused"
    }.sorted()
}

/// A one-line, redrawn progress meter for reserving disk space - writing a
/// fixed disk takes about a second per 2 GB, and a silent minute looked like
/// a hang. Only on a terminal; piped output gets nothing.
func reservationMeter() -> ((DiskStorage.ReservationProgress) -> Void)? {
    guard isatty(STDERR_FILENO) != 0 else { return nil }
    return { update in
        let width = 28
        let filled = Int(update.fraction * Double(width))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        var line = "\rmsl: reserving space  \(bar) \(Int(update.fraction * 100))%  \(update.description)\u{1B}[K"
        if update.written >= update.total { line += "\n" }
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

/// Every registered instance of `distro`, running or not.
func instances(of distro: GuestDistro) -> [String] {
    registryForLookup.entries().filter { $0.value == distro }.map(\.key).sorted()
}

func runShellSession(instance: String, distro: GuestDistro, command: String, user: String) -> Never {
    signal(SIGWINCH) { _ in needsResize = 1 }

    // Linux GUI apps from any prompt. Typing `gnome-chess` in a shell used
    // to fail with "Failed to open display": `DISPLAY` and the guest's X11
    // tunnel were only ever set up for apps MSL launched itself. Done before
    // the session starts, because the shell reads its profile the moment it
    // does. Skipped for commands that pick their own display (`msl gui`'s
    // XQuartz path), and with MSL_NO_DISPLAY=1 for scripts that want the
    // bare command. A failure never stops the shell - it only means GUI
    // apps won't open from it, which is said once, dimmed.
    var guestCommand = command
    if ProcessInfo.processInfo.environment["MSL_NO_DISPLAY"] == nil, !command.hasPrefix("DISPLAY=") {
        close(connectToDaemon()) // installs the tools and starts mslhd if this is the first run
        do {
            try LinuxAppLauncher.prepareDisplay(instance: instance, distro: distro)
        } catch {
            if command.isEmpty {
                FileHandle.standardError.write("\u{1B}[2mmsl: Linux GUI apps won't open from this shell - \(error)\u{1B}[0m\n".data(using: .utf8)!)
            }
        }
        if !command.isEmpty { guestCommand = GuestIntegration.oneShotDisplayPrefix() + command }
    }

    let controlFD = connectToDaemon()
    let (rows, cols) = currentWindowSize()
    let request = DaemonProtocol.ControlRequest.session(instance: instance, rows: rows, cols: cols, distro: distro).encode()
    _ = request.withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }

    var status: UInt8 = 0
    _ = withUnsafeMutablePointer(to: &status) { read(controlFD, $0, 1) }

    guard status == DaemonProtocol.statusOK else {
        var reason = [UInt8](repeating: 0, count: 256)
        let n = read(controlFD, &reason, 256)
        let message = n > 0 ? String(decoding: reason[0..<n], as: UTF8.self) : "unknown error"
        FileHandle.standardError.write("msl: \(message)\n".data(using: .utf8)!)
        exit(1)
    }

    let dataFD: Int32
    do {
        dataFD = try FileDescriptorPassing.receive(from: controlFD)
    } catch {
        FileHandle.standardError.write("msl: didn't receive session fd (\(error))\n".data(using: .utf8)!)
        // The daemon already counted this as a started session (see
        // `DaemonServer.handleSession`'s `sessionStarted` call, which
        // happens before the fd handoff we just failed to receive) - tell
        // it right away rather than leaving that count permanently
        // inflated for this instance.
        notifySessionEnded(instance: instance)
        exit(1)
    }
    close(controlFD) // control channel's job is done - only the data fd matters now

    // The "zsh is gone, this is now a native Linux terminal" transition -
    // a real screen clear plus a one-time banner, only for a genuinely
    // interactive session (never a one-shot command, which should read
    // like `ssh host cmd`: just the command's own output, nothing extra).
    // Printed here, before `setRawMode()`: raw mode's `cfmakeraw()`
    // disables OPOST, so a bare `print()`'s `\n` afterward wouldn't get
    // translated to `\r\n` and would stair-step - normal canonical-mode
    // output processing needs to still be in effect for this to render
    // right. The guest's own bash prompt takes over immediately after,
    // completely unmodified - this is a banner in front of a native shell,
    // not a fake prompt standing in for one.
    if command.isEmpty {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        print("\u{1B}[1;32mmsl\u{1B}[0m@\u{1B}[1;36m\(distro.rawValue)\u{1B}[0m")
        // Dimmed, and never the same twice running - see `Greeter`. Below
        // the banner rather than above it so the line that actually tells
        // you which machine you are on stays first.
        if let greeting = Greeter.nextGreeting() {
            print("\u{1B}[2m\(greeting.text)\u{1B}[0m")
        }
        print("")
        // `print()` goes through stdio's own buffering (block-buffered
        // whenever stdout isn't a tty), while every byte from here on -
        // the guest's own shell output - goes straight out via a raw
        // `write(STDOUT_FILENO, ...)` that bypasses that buffer entirely.
        // Without an explicit flush the banner can end up reordered after
        // (or lost entirely behind) the relay's unbuffered writes -
        // confirmed live, redirected to a file: the banner never showed up
        // at all, only the guest's own prompt did.
        fflush(stdout)
    }

    let originalTermios = setRawMode()
    defer { restoreMode(originalTermios) }

    // Leave cleanly when the system tears this process down.
    //
    // A logout, a shutdown, or the terminal window closing sends SIGTERM or
    // SIGHUP, and the default action kills this process where it stands -
    // mid-relay, with the terminal still in raw mode and the daemon still
    // counting the session as open. The user gets a shell whose echo and
    // line editing are gone (`reset` territory), and the instance stops
    // auto-suspending because nothing ever sent `.sessionEnded`.
    //
    // Handled on a dedicated `sigwait` thread rather than in a signal
    // handler: restoring the terminal and talking to the daemon are both
    // far outside what is legal in async-signal context, and the main
    // thread is blocked reading frames so it cannot service a dispatch
    // source. Blocking the signals in every thread first is what makes
    // `sigwait` the one place they are delivered.
    var terminationSignals = sigset_t()
    sigemptyset(&terminationSignals)
    sigaddset(&terminationSignals, SIGTERM)
    sigaddset(&terminationSignals, SIGHUP)
    pthread_sigmask(SIG_BLOCK, &terminationSignals, nil)
    Thread {
        var received: Int32 = 0
        sigwait(&terminationSignals, &received)
        restoreMode(originalTermios)
        notifySessionEnded(instance: instance)
        // The guest's shell gets its SIGHUP from shellinit when this
        // connection drops, the same as any terminal hanging up.
        exit(0)
    }.start()

    // EXEC must be the very first frame shellinit sees on this connection -
    // send it before starting the relay so there's no chance a stdin byte
    // races ahead of it.
    writeFull(fd: dataFD, bytes: ShellProtocol.encodeExec(command: guestCommand, rows: rows, cols: cols, user: user))

    // stdin -> guest, framed as DATA, with RESIZE frames spliced in on
    // SIGWINCH.
    let writer = Thread {
        var buf = [UInt8](repeating: 0, count: 4096)
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)

        while true {
            let ready = poll(&pfd, 1, 200) // 200ms so SIGWINCH still gets noticed promptly

            if needsResize == 1 {
                needsResize = 0
                let (r, c) = currentWindowSize()
                writeFull(fd: dataFD, bytes: ShellProtocol.encodeResize(rows: r, cols: c))
            }

            guard ready > 0, pfd.revents & Int16(POLLIN) != 0 else { continue }
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 {
                // EOF on our own stdin (piped input ran out, or a real
                // terminal's Ctrl-D closed it outright rather than sending
                // it as a byte for the guest pty's own line discipline to
                // interpret) - half-close the write side of the vsock
                // connection so shellinit sees EOF too and winds the
                // session down (SIGHUP to the shell, same as a real
                // terminal hanging up), instead of leaving both sides
                // blocked waiting on each other forever. Matches how a
                // real terminal/ssh session behaves when input is
                // exhausted - important for anything that pipes a command
                // in and expects the session to actually end, not hang.
                shutdown(dataFD, Int32(SHUT_WR))
                break
            }
            writeFull(fd: dataFD, bytes: ShellProtocol.encodeData(buf[0..<n]))
        }
    }
    writer.start()

    // guest -> stdout, until EXIT (normal end of session) or the
    // connection just drops (guest-side crash, VM going away mid-session,
    // etc. - treated as a plain failure exit rather than hanging).
    var exitCode: Int32 = 1
    var sawExit = false
    var sawOutput = false
    while true {
        guard let frame = readShellFrame(fd: dataFD) else { break }
        switch frame.type {
        case .data:
            sawOutput = true
            writeFull(fd: STDOUT_FILENO, bytes: frame.payload)
        case .exit:
            exitCode = Int32(frame.payload.first ?? 1)
            sawExit = true
        case .exec, .resize:
            break // host->guest-only frame types - shellinit never sends these
        }
    }
    // A dropped connection with no EXIT frame ever seen used to exit(1)
    // completely silently - genuinely indistinguishable from a real command
    // that just happened to exit 1. Surfacing it (using the ShellProtocolError
    // case that already existed for exactly this but was never actually
    // wired up anywhere) turned out to be what exposed the real concurrent-
    // session bug this was added to debug - see VMManager's `isStarting`
    // doc comment and DaemonServer's `lastActivity` doc comment for the two
    // real races this helped find.
    if !sawExit {
        FileHandle.standardError.write("msl: \(ShellProtocol.ShellProtocolError.connectionClosed)\n".data(using: .utf8)!)
    }
    notifySessionEnded(instance: instance)
    if sawExit, exitCode == 127, !sawOutput, !user.isEmpty {
        // `exit()` below skips the deferred restore - put the terminal back
        // first so the explanation doesn't stair-step.
        restoreMode(originalTermios)
        explainIfUserMissing(instance: instance, distro: distro, user: user)
    }
    exit(exitCode)
}

/// shellinit refuses a session for a user the guest doesn't have with a bare
/// exit 127 and no output - so a stale remembered user (the distro was
/// reinstalled, or the account deleted inside Linux) made every session die
/// straight after the banner, and the app's Terminal tab just said "Session
/// ended". Confirms the account really is missing, as root, before saying
/// so: a one-shot command can also exit 127 silently. A missing *remembered*
/// user is forgotten, so the next start offers account setup; a `-u` name is
/// the caller's own choice and left alone.
func explainIfUserMissing(instance: String, distro: GuestDistro, user: String) {
    let check = "id -u \(DesktopEntry.shellQuote(user)) >/dev/null 2>&1 && echo present || echo missing"
    let (_, output) = runOneShotCommand(instance: instance, distro: distro, command: check, user: "", echo: false)
    guard output.contains("missing") else { return }

    var message = "msl: there's no Linux user '\(user)' in \(instance)."
    let registry = DefaultUserRegistry(path: defaultUsersRegistryURL)
    if requestedUser.isEmpty, registry.defaultUser(for: distro) == user {
        try? registry.forgetDefaultUser(for: distro)
        message += " MSL remembered it from an earlier \(distro.rawValue) install and has now forgotten it -"
        message += " start the session again to create your account."
    } else {
        message += " Pick an existing account, or use root: msl \(instance) -u root"
    }
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Runs a one-shot command against `instance` without taking over the
/// calling terminal (no raw mode, no SIGWINCH/resize plumbing) - for
/// internal steps that need to execute something in the guest and see its
/// result rather than host a real interactive session: the first-run user
/// setup wizard, and `--shutdown`'s active-process check + guest-side
/// poweroff. Captures guest stdout/stderr into the returned `output`
/// regardless; also streams it live to this process's own stdout when
/// `echo` is true. Notifies the daemon the session ended before returning
/// either way, same as `runShellSession` does at exit.
@discardableResult
func runOneShotCommand(instance: String, distro: GuestDistro, command: String, user: String, echo: Bool) -> (exitCode: Int32, output: String) {
    let controlFD = connectToDaemon()
    let request = DaemonProtocol.ControlRequest.session(instance: instance, rows: 24, cols: 80, distro: distro)
    _ = request.encode().withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }

    var status: UInt8 = 0
    _ = withUnsafeMutablePointer(to: &status) { read(controlFD, $0, 1) }
    guard status == DaemonProtocol.statusOK else {
        var reason = [UInt8](repeating: 0, count: 256)
        let n = read(controlFD, &reason, 256)
        let message = n > 0 ? String(decoding: reason[0..<n], as: UTF8.self) : "unknown error"
        FileHandle.standardError.write("msl: \(message)\n".data(using: .utf8)!)
        close(controlFD)
        return (1, "")
    }

    guard let dataFD = try? FileDescriptorPassing.receive(from: controlFD) else {
        FileHandle.standardError.write("msl: didn't receive session fd\n".data(using: .utf8)!)
        close(controlFD)
        notifySessionEnded(instance: instance)
        return (1, "")
    }
    close(controlFD)

    writeFull(fd: dataFD, bytes: ShellProtocol.encodeExec(command: command, rows: 24, cols: 80, user: user))

    var exitCode: Int32 = 1
    var collected: [UInt8] = []
    loop: while true {
        guard let frame = readShellFrame(fd: dataFD) else { break }
        switch frame.type {
        case .data:
            collected.append(contentsOf: frame.payload)
            if echo { writeFull(fd: STDOUT_FILENO, bytes: frame.payload) }
        case .exit:
            // The command's own exit code has arrived - done, full stop.
            // Do NOT loop back to `readShellFrame` waiting for EOF too: if
            // the command backgrounded a child (this project's own
            // `x11tunnel`, even after `setsid` + full fd redirection can
            // still end up holding some other reference to the session's
            // pty/socket), the far end may never actually close the
            // connection, and `readShellFrame` blocks forever reading data
            // that will never come - even though the exit code we needed
            // already arrived. This was the exact, repeatedly-hit
            // `x11tunnel`-starting hang: this client sitting forever after
            // already printing everything, never returning to a prompt.
            exitCode = Int32(frame.payload.first ?? 1)
            break loop
        case .exec, .resize:
            break
        }
    }
    close(dataFD)
    notifySessionEnded(instance: instance)
    return (exitCode, String(decoding: collected, as: UTF8.self))
}

/// Single-quotes `s` for safe embedding inside a shell command string,
/// escaping any embedded single quotes the POSIX-shell way (`'\''`) - used
/// wherever a value that isn't already validated-safe (a chosen password,
/// in particular) gets spliced into a guest-side setup script.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Reads one line from stdin with terminal echo disabled (canonical line
/// editing/backspace still work - only ECHO is cleared, not ICANON) - for
/// the password prompts below, matching how `passwd`/`sudo` hide input.
/// Always restores the original termios afterward, even on EOF/Ctrl-D.
func readHiddenLine(prompt: String) -> String? {
    print(prompt, terminator: "")
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    let line = readLine()
    tcsetattr(STDIN_FILENO, TCSANOW, &original)
    print("") // Enter's newline wasn't echoed either - move to a fresh line
    return line
}

/// Shared with the app, which creates the same account from its setup sheet.
let defaultUsersRegistryURL = LinuxUserSetup.registryURL

/// WSL-style first-run prompt, run at most once per distro (see
/// `DefaultUserRegistry`): asks for a username + password and creates that
/// user as an administrator whose sudo asks for its password - the guest
/// side is `LinuxUserSetup.script`, the same one the app's sheet runs.
/// Remembers the user and returns it so the caller can use it for this
/// session too. Only called once the caller has already confirmed this is
/// worth prompting for (a real TTY, no explicit `-u`, nothing remembered
/// yet for `distro`) - see `resolveUser`.
/// The cat, for a terminal that cannot show a picture.
///
/// Printed once, at the one moment the CLI actually greets somebody -
/// first-run user setup - and nowhere else, because a banner on every
/// command is a banner nobody wants twice. The per-session greeting is one
/// line and lives in `Greeter`.
///
/// A raw string literal, and the whitespace is load-bearing: this is drawn
/// with U+3000 IDEOGRAPHIC SPACE rather than ASCII spaces, so it only lines
/// up in a font that renders those at full width. Do not "tidy" the
/// indentation - reflowing it to normal spaces collapses the cat.
let mslMascot = #"""
              ＿＿
　　 　　　🌸＞　　フ
　　　 　　| 　_　 _l
　  　  　／` ミ＿xノ 
　　 　 /　　　 　 |
　　　 /　 ヽ　　 ﾉ
　 　 │　　|　|　|
　／￣|　　 |　|　|
　| (￣ヽ＿_ヽ_)__)
　＼二つ
"""#

func runFirstUserSetupIfNeeded(instance: String, distro: GuestDistro) -> String? {
    print("""

    \(mslMascot)

    Welcome to MSL - \(distro.rawValue)!
    Please create a default UNIX user account. The username does not need
    to match your Mac username. It becomes your login for \(distro.rawValue) from now
    on, and its password is the one sudo asks for.
    (root is always available from the Mac: msl \(instance) -u root)

    """)

    func giveUp(_ reason: String) -> String? {
        FileHandle.standardError.write("msl: \(reason) - using root for this session\n".data(using: .utf8)!)
        return nil
    }

    // Round again only when the name is taken; everything else either works
    // or falls back to root for this one session, and asks again next time.
    while true {
        guard let username = promptNewUsername() else { return giveUp("setup cancelled") }
        guard let password = promptNewPassword() else { return giveUp("setup cancelled") }

        print("Creating '\(username)'...")
        let (exitCode, output) = runOneShotCommand(
            instance: instance, distro: distro,
            command: LinuxUserSetup.script(username: username, password: password),
            user: "", echo: false
        )
        switch LinuxUserSetup.outcome(exitCode: exitCode, output: output, username: username) {
        case .created(let warning):
            try? LinuxUserSetup.registry().setDefaultUser(username, for: distro)
            print("User '\(username)' created - your login for \(distro.rawValue), and an administrator: sudo asks for this password.")
            if let warning { print("Note: \(warning)") }
            print("")
            return username
        case .alreadyExists:
            print("A user called '\(username)' already exists in \(distro.rawValue). Pick another name.\n")
        case .failed(let message):
            return giveUp("couldn't create '\(username)' (\(message))")
        }
    }
}

/// `nil` on end of input (Ctrl-D) - the old loop spun forever on it.
private func promptNewUsername() -> String? {
    while true {
        print("New UNIX username: ", terminator: "")
        guard let line = readLine() else { print(""); return nil }
        let username = line.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxUserSetup.problem(with: username) {
            print(problem.message)
            continue
        }
        return username
    }
}

private func promptNewPassword() -> String? {
    while true {
        guard let first = readHiddenLine(prompt: "New password: ") else { return nil }
        guard let second = readHiddenLine(prompt: "Retype new password: ") else { return nil }
        if let problem = LinuxUserSetup.passwordProblem(first, confirmation: second) {
            print("\(problem) Try again.")
            continue
        }
        return first
    }
}

/// Best-effort: launches XQuartz if it isn't already running (waiting,
/// bounded, for its X11 socket to appear), and disables its X11 access
/// control - both previously manual prerequisites for `msl gui`
/// (`open -a XQuartz` + `xhost +`), now folded into the command itself so
/// there's exactly one step. `xhost +` is a real, deliberate
/// simplification for this experimental skeleton (see `References-
/// READMES/msl-vgpu.md`'s "Open Questions") - a shippable version would
/// share a proper MIT-MAGIC-COOKIE over the vsock channel instead of
/// blanket-disabling access control on the host's X server. `/opt/X11/
/// bin/` is XQuartz's own standard install location, confirmed live on
/// this machine rather than assumed.
func ensureXQuartzRunning() {
    let socketPath = "/tmp/.X11-unix/X0"
    if !FileManager.default.fileExists(atPath: socketPath) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "XQuartz"]
        try? open.run()
        open.waitUntilExit()

        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        if !FileManager.default.fileExists(atPath: socketPath) {
            FileHandle.standardError.write("msl: XQuartz didn't come up within 15s - is it installed? (`brew install --cask xquartz`)\n".data(using: .utf8)!)
        }
    }

    let xhost = Process()
    xhost.executableURL = URL(fileURLWithPath: "/opt/X11/bin/xhost")
    xhost.arguments = ["+"]
    try? xhost.run()
    xhost.waitUntilExit()
}

// MARK: - Argument parsing

// `--distro <name>` only matters when it creates a brand-new instance (see
// `runShellSession`'s doc comment) - pull it out of the positional args
// wherever it appears rather than treating it as a subcommand-specific
// flag, since the shell-session path (`msl <instance>`) has no subcommand
// keyword to attach it to.
/// Every subcommand `msl` dispatches on, for the near-miss check in the
/// fallback branch. Kept beside the switch it mirrors - a command missing
/// from here is only a missed suggestion, never a wrong one, so drift
/// degrades gracefully.
///
/// The test-only entries are deliberately included: `cage-input-test` is
/// exactly the kind of long name that gets mistyped.
let mslCommands = [
    "apps", "cage-bridge-test", "cage-input-test", "cage-view", "gui",
    "gui-native", "help", "hibernate", "images", "install", "install-tools",
    "doctor", "instances", "keyboard", "list", "ls", "new", "power-test", "remove", "remove-distro", "resume", "files",
    "snapshot", "ssh", "status", "storage", "suspend", "uninstall", "resources", "config",
]

// This CLI forwards a command line into the guest, so it must stop looking
// for its own options where the guest's command starts - see
// `ArgumentSplitter`, which is where the rule and its tests live. Scanning
// the whole argument list (as this used to) made `msl work echo -d /tmp`
// die with "unknown distro '/tmp'" and quietly ate the `-u 1000` out of
// `msl work docker run -u 1000 img`.
let splitArguments = ArgumentSplitter.split(
    Array(CommandLine.arguments.dropFirst()), knownCommands: Set(mslCommands))

// `explicitDistro` (vs. a plain default) matters for the WSL-like
// ergonomic below: `msl fedora` should just work, no `--distro fedora`
// needed, by treating an instance name that happens to match a known
// distro as implying that distro - but only when the user hasn't already
// said otherwise with `--distro`/`-d`.
var explicitDistro: GuestDistro?
if let requested = splitArguments.distro {
    guard let parsed = GuestDistro(rawValue: requested) else {
        FileHandle.standardError.write("msl: unknown distro '\(requested)' - one of: \(GuestDistro.allCases.map(\.rawValue).joined(separator: ", ")), or custom:<image> for a custom image (see `msl images`)\n".data(using: .utf8)!)
        exit(1)
    }
    explicitDistro = parsed
}

// Only meaningful for `msl install` - overrides where the manifest is
// fetched from, same idea as OIS's own OIS_GITHUB_BASE test override.
let manifestURLOverride: String? = splitArguments.manifest

// `-u`/`--user <name>` - which guest user a shell session or one-shot
// command runs as (default: root, unchanged).
let requestedUser = splitArguments.user ?? ""

var rawArgs = splitArguments.remainder
let args = rawArgs
let defaultInstance = InstanceRegistry.defaultInstanceName

/// `msl fedora` and `msl fedora --distro fedora` are equivalent - an
/// instance name matching a known distro implies that distro, so a fresh
/// install is exactly "fetch the image, type `msl <distro>`" with nothing
/// else to remember. `distro` only actually takes effect the first time
/// this name is registered (see `InstanceRegistry.ensureRegistered`) -
/// naming an *existing*, differently-provisioned instance "fedora" would
/// just use whatever it already was, same as always.
func resolvedDistro(forInstance name: String) -> GuestDistro {
    explicitDistro ?? GuestDistro(rawValue: name) ?? .alpine
}

/// Read-only client-side handle onto the same registry file the daemon
/// owns - used for lookups that don't need a round-trip through `mslhd`
/// (last-used instance, an existing instance's real distro). Never writes
/// through this - all registration/mutation stays server-side in
/// `DaemonServer`.
let registryForLookup = InstanceRegistry(path: URL(fileURLWithPath: DaemonProtocol.defaultInstanceRegistryPath()))

/// Plain `msl` (no instance named): picks up the most recently used
/// instance, once more than one is installed, instead of always landing on
/// a fixed default - see `InstanceRegistry.recordLastUsed`. Falls back to
/// `defaultInstance` on a first-ever run, or if the last-used instance was
/// since `remove`d.
///
/// When the last-used instance is gone, an instance that still exists wins
/// over the built-in default. Before, removing `meow` and creating `work`
/// meant plain `msl` greeted the user with an account prompt for an Alpine
/// that was never installed (2026-09-16).
func startupInstance() -> String {
    if let last = registryForLookup.lastUsed(), registryForLookup.distro(for: last) != nil {
        return last
    }
    let existing = registryForLookup.entries().sorted { $0.key < $1.key }
    if let installed = existing.first(where: { $0.value.isCustom || DistroInstallation.isInstalled($0.value) }) {
        return installed.key
    }
    return existing.first?.key ?? defaultInstance
}

/// `msl` on a Mac with nothing installed: every distro that can be
/// downloaded, with its release and download size, from the live manifest.
func printAvailableDistros() {
    var out = "msl: no installed distros and no created instances.\n\n"
    let manifestURL = DistroInstaller.resolveManifestURLString(override: manifestURLOverride)
    if let manifest = DistroCatalog.fetch(from: manifestURL) {
        let entries = DistroCatalog.entries(from: manifest)
        let nameWidth = entries.map { $0.distro.count }.max() ?? 8
        let titleWidth = entries.map { "\($0.name) \($0.release)".count }.max() ?? 20
        out += "Available distros:\n"
        for entry in entries {
            let title = "\(entry.name) \(entry.release)"
            out += "  " + entry.distro.padding(toLength: nameWidth + 3, withPad: " ", startingAt: 0)
                + title.padding(toLength: titleWidth + 3, withPad: " ", startingAt: 0)
                + DiskStorage.format(entry.downloadBytes) + " download\n"
        }
    } else {
        let names = GuestDistro.allCases.filter { !$0.isCustom }.map(\.rawValue).joined(separator: ", ")
        out += "Available distros: \(names)\n(couldn't reach the image catalog for versions - are you online?)\n"
    }
    out += "\nInstall one with msl install <distro>, for example:\n\n    msl install debian\n"
    FileHandle.standardError.write(out.data(using: .utf8)!)
}

/// Stops before a session on a distro whose image isn't on this Mac, with the
/// command that fixes it - rather than asking for a Linux account on a disk
/// that doesn't exist.
func requireInstalled(instance: String, distro: GuestDistro) {
    guard !distro.isCustom, !DistroInstallation.isInstalled(distro) else { return }
    // A brand-new Mac: nothing to open, so show what can be installed rather
    // than naming one distro (plain `msl` used to say "alpine isn't installed
    // yet", as if Alpine were required).
    let anythingInstalled = GuestDistro.allCases.contains { !$0.isCustom && DistroInstallation.isInstalled($0) }
    if registryForLookup.entries().isEmpty, !anythingInstalled {
        printAvailableDistros()
        exit(1)
    }
    var message = "msl: \(distro.rawValue) isn't installed yet. Install it with:\n\n    msl install \(distro.rawValue)\n"
    let ready = registryForLookup.entries()
        .filter { $0.key != instance && ($0.value.isCustom || DistroInstallation.isInstalled($0.value)) }
        .map(\.key).sorted()
    if !ready.isEmpty {
        message += "\nor open one you already have: " + ready.map { "msl \($0)" }.joined(separator: ", ") + "\n"
    }
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(1)
}

/// The distro a session against `name` should register as / already is.
/// For an existing instance, uses whatever it's actually registered as -
/// `resolvedDistro`'s name-matching heuristic only applies at *creation*
/// time and would otherwise guess wrong for an existing custom-named
/// instance of a non-Alpine distro (e.g. `work` running Debian, invoked as
/// plain `msl work` with no `--distro` repeated). Falls back to that same
/// heuristic only for a genuinely new name, since there's nothing
/// registered yet for a registry lookup to find.
func effectiveDistro(forInstance name: String) -> GuestDistro {
    registryForLookup.distro(for: name) ?? resolvedDistro(forInstance: name)
}

/// Resolves which guest user a session should run as. An explicit `-u`/
/// `--user` always wins; otherwise `distro`'s remembered default user (see
/// `DefaultUserRegistry`) is used if one exists - even for a one-shot
/// command, matching `ssh`-like expectations once a default is set.
/// Failing that, a genuinely interactive session (empty `command`, a real
/// TTY on both ends) runs the first-run setup wizard; anything else (a
/// one-shot command, or a piped/scripted/non-interactive invocation with
/// nothing remembered yet) falls back to root, unchanged.
func resolveUser(instance: String, distro: GuestDistro, command: String) -> String {
    requireInstalled(instance: instance, distro: distro)
    if !requestedUser.isEmpty { return requestedUser }
    let userRegistry = DefaultUserRegistry(path: defaultUsersRegistryURL)
    if let remembered = userRegistry.defaultUser(for: distro) { return remembered }
    guard command.isEmpty, isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return "" }
    return runFirstUserSetupIfNeeded(instance: instance, distro: distro) ?? ""
}

/// `msl --shutdown` / `msl --shutdown <instance>`: gracefully powers the
/// guest(s) off entirely, rather than just pausing/saving state the way
/// `suspend`/`hibernate` do - matching `wsl --shutdown`'s "actually shut
/// down." Runs `poweroff` inside the guest over the shell channel first
/// (so its filesystem gets a clean unmount/flush - see the disk-corruption
/// story in `VMManager.stopAfterGuestShutdown`'s doc comment) rather than
/// just yanking the VM process, reports how many processes were running
/// there first (informational only - a real shutdown proceeds either way,
/// same as `shutdown`/`wsl --shutdown` do), then tells the daemon to
/// finish tearing the VM process down once the guest has had a moment to
/// actually go through with it. `instances` empty means "every registered
/// instance," matching `wsl --shutdown` affecting the whole VM, not just
/// one distro.
func performShutdown(instances: [String]) {
    let targets = instances.isEmpty ? registryForLookup.list() : instances
    let running = targets.filter { name in
        guard let line = sendControlRequest(.status(instance: name)) else { return false }
        return line == "OK running" || line == "OK paused"
    }
    guard !running.isEmpty else {
        print("msl: nothing running")
        return
    }
    for instance in running {
        let distro = effectiveDistro(forInstance: instance)
        let (_, psOutput) = runOneShotCommand(instance: instance, distro: distro, command: "ps -e 2>/dev/null", user: "", echo: false)
        let processCount = max(0, psOutput.split(separator: "\n").count - 1) // -1 for ps's own header line
        if processCount > 0 {
            print("msl: \(instance): \(processCount) process(es) running - shutting down gracefully")
        }
        print("msl: shutting down \(instance)...")
        // The connection is expected to just drop as the guest actually
        // powers off (not a clean EXIT frame) - that's success here, not a
        // failure, so the exit code is deliberately ignored.
        runOneShotCommand(instance: instance, distro: distro, command: "poweroff 2>/dev/null || halt 2>/dev/null || reboot 2>/dev/null", user: "", echo: false)
        // Fixed grace period for the guest to actually finish unmounting/
        // flushing before the host side tears the VM process down - no
        // console-marker synchronization for this, same pragmatic
        // trade-off `VMManager.afterColdStart` already makes for
        // `.persistentDisk`'s boot wait.
        Thread.sleep(forTimeInterval: 3)
        if let line = sendControlRequest(.shutdown(instance: instance)) {
            print(line.hasPrefix("OK") ? "msl: \(instance) shut down" : "msl: \(instance): \(line)")
        }
    }
}

func usageAndExit() -> Never {
    FileHandle.standardError.write(CLIHelp.render(width: CLIHelp.terminalWidth(STDERR_FILENO),
                                                  styled: isatty(STDERR_FILENO) != 0).data(using: .utf8)!)
    exit(1)
}

/// Asks one setup question; Return keeps `defaultValue`. Nil on end of input.
func ask(_ question: String, default defaultValue: String) -> String? {
    print("  \(question) [\(defaultValue)]: ", terminator: "")
    fflush(stdout)
    guard let line = readLine() else { return nil }
    let answer = line.trimmingCharacters(in: .whitespaces)
    return answer.isEmpty ? defaultValue : answer
}

/// Right after `msl install`: the first instance's name, CPUs, memory and
/// disk - the same choices the app's first-run guide gives. Before this, a
/// terminal user got an instance named after the distro with default sizes,
/// and the only way to change them was the app (2026-09-16).
///
/// Every answer is checked as it's given and asked again if it's refused, so
/// nothing is registered until all of them are good. Returns the instance to
/// open, or nil when input ended.
func runInstallSetup(for distro: GuestDistro) -> String? {
    let bold = "\u{1B}[1m", reset = "\u{1B}[0m"
    print("\n\(bold)Set up your \(distro.rawValue) instance\(reset) - press Return to keep what's in [brackets].")

    var name = distro.rawValue
    while true {
        guard let answer = ask("Instance name", default: name) else { return nil }
        let taken = registryForLookup.distro(for: answer)
        if !InstanceRegistry.isValidName(answer) {
            print("    Use letters, numbers, - and _ (up to 32 characters).")
        } else if mslCommands.contains(answer) {
            print("    \(answer) is an msl command - pick another name.")
        } else if let taken, taken != distro {
            print("    \(answer) is already a \(taken.rawValue) instance - pick another name.")
        } else {
            name = answer
            break
        }
    }

    var options = InstanceSetupOptions()
    let policy = ResourcePolicyStore.load(instance: name)

    let cpuDefault = String(policy.resolvedCPUCount())
    while true {
        guard let answer = ask("CPUs (1-\(InstanceSetup.maximumCPUs))", default: cpuDefault) else { return nil }
        guard answer != cpuDefault else { break }
        guard let cpus = Int(answer), cpus >= 1 else { print("    A whole number, like 4."); continue }
        do {
            _ = try InstanceSetup.validate(InstanceSetupOptions(cpus: cpus))
            options.cpus = cpus
            break
        } catch { print("    \(error)") }
    }

    let memoryDefault = InstanceSetup.describe(policy.resolvedMemory())
        .replacingOccurrences(of: " fixed", with: "").replacingOccurrences(of: " dynamic", with: "")
    while true {
        guard let answer = ask("Memory - a size like 6G, or 2G-8G to grow and shrink with use", default: memoryDefault) else { return nil }
        guard answer != memoryDefault else { break }
        do {
            let parsed = try InstanceSetupOptions.parse(["--memory", answer]).options
            for warning in try InstanceSetup.validate(parsed) { print("    note: \(warning)") }
            options.memory = parsed.memory
            break
        } catch { print("    \(error)") }
    }

    let boot = distro.bootFiles()
    let current = DiskStorage.policy(forImageNamed: boot.storageKey, path: boot.disk.path)
    let currentGB = (max(current.size, DiskStorage.capacity(of: boot.disk.path)) + (1 << 30) - 1) >> 30
    let others = registryForLookup.entries().filter { $0.value == distro && $0.key != name }.map(\.key).sorted()
    if !others.isEmpty {
        print("    (the disk is shared with \(others.joined(separator: ", ")))")
    }
    var diskSize: UInt64?
    while true {
        guard let answer = ask("Disk size", default: "\(currentGB)G") else { return nil }
        guard answer != "\(currentGB)G" else { break }
        do {
            let parsed = try InstanceSetupOptions.parse(["--disk", answer]).options
            _ = try InstanceSetup.validate(parsed)
            guard let size = parsed.disk?.size, size >= DiskStorage.capacity(of: boot.disk.path) else {
                print("    A disk can't be made smaller - it's already \(currentGB)G."); continue
            }
            diskSize = size
            break
        } catch { print("    \(error)") }
    }
    let fixedDefault = current.mode == .fixed ? "y" : "n"
    guard let reserve = ask("Reserve that space on your Mac now? Slower, but guaranteed (y/n)", default: fixedDefault) else { return nil }
    let fixed = reserve.lowercased().hasPrefix("y")
    if diskSize != nil || fixed != (current.mode == .fixed) {
        let size = diskSize ?? UInt64(currentGB) << 30
        options.disk = StoragePolicy(mode: fixed ? .fixed : .dynamic, size: size, autoGrow: !fixed)
    }

    do {
        _ = try registryForLookup.ensureRegistered(name, distro: distro)
    } catch {
        FileHandle.standardError.write("msl: could not create \(name) - \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    if !options.isEmpty {
        do {
            _ = try InstanceSetup.apply(options, instance: name, distro: distro, isRunning: false,
                                        diskInUseBy: runningInstances(using: distro),
                                        reservationProgress: reservationMeter())
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    print("")
    InstanceSetup.summary(instance: name, distro: distro).forEach { print("  " + $0) }
    print("\nChange these any time: msl resources \(name) --cpus 4 --memory 2G-8G --disk 64G")
    return name
}

/// Opens a window of MSL.app through its `msl://` URL scheme, launching the
/// app if it isn't running. Falls back to just opening the app when nothing
/// has registered the scheme yet.
func openInApp(_ url: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    if process.terminationStatus == 0 { return true }
    let fallback = Process()
    fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    fallback.arguments = ["-b", "com.msl.app"]
    fallback.standardError = FileHandle.nullDevice
    guard (try? fallback.run()) != nil else { return false }
    fallback.waitUntilExit()
    return fallback.terminationStatus == 0
}


switch args.first {
case nil:
    let instance = startupInstance()
    let distro = effectiveDistro(forInstance: instance)
    let user = resolveUser(instance: instance, distro: distro, command: "")
    runShellSession(instance: instance, distro: distro, command: "", user: user)

case "--":
    // `msl -- ls -la`: one-shot command against the most recently used
    // instance (or the default, on a first run), with no need to know/
    // spell out its actual name.
    let instance = startupInstance()
    let distro = effectiveDistro(forInstance: instance)
    let command = args.dropFirst().joined(separator: " ")
    let user = resolveUser(instance: instance, distro: distro, command: command)
    runShellSession(instance: instance, distro: distro, command: command, user: user)

case "install":
    let installNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    let skipSetup = args.contains("--no-setup")
    guard installNames.count == 1, args.count == (skipSetup ? 3 : 2),
          let distroToInstall = GuestDistro(rawValue: installNames[0]) else {
        usageAndExit()
    }
    let manifestURLString = DistroInstaller.resolveManifestURLString(override: manifestURLOverride)
    let appSupport = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MSL")
    do {
        try DistroInstaller.install(distro: distroToInstall, manifestURLString: manifestURLString, appSupportDir: appSupport) { message in
            FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        }
        print("OK installed \(distroToInstall.rawValue)")
        // Asked only of a person at a terminal; scripts and pipes get the
        // old behaviour, and --no-setup skips it.
        guard !skipSetup, isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0,
              let setUp = runInstallSetup(for: distroToInstall) else {
            print("run `msl \(distroToInstall.rawValue)` to start it")
            exit(0)
        }
        print("")
        guard let open = ask("Open \(setUp) now? (y/n)", default: "y"), open.lowercased().hasPrefix("y") else {
            print("Start it any time: msl \(setUp)")
            exit(0)
        }
        let user = resolveUser(instance: setUp, distro: distroToInstall, command: "")
        runShellSession(instance: setUp, distro: distroToInstall, command: "", user: user)
    } catch {
        FileHandle.standardError.write("msl: install failed - \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "suspend":
    runControl(.suspend(instance: args.count > 1 ? args[1] : defaultInstance))

case "resume":
    runControl(.resume(instance: args.count > 1 ? args[1] : defaultInstance))

case "hibernate":
    runControl(.hibernate(instance: args.count > 1 ? args[1] : defaultInstance))

case "--hibernate":
    // Unlike the `hibernate` subcommand (which always targets one
    // instance, defaulting to `defaultInstance`), the top-level `--`
    // flag form matches `--shutdown`'s "every running instance if none
    // is named" - both read as "affect the whole VM," not "one distro."
    let targets = args.count > 1 ? [args[1]] : registryForLookup.list()
    for instance in targets {
        guard let line = sendControlRequest(.status(instance: instance)),
              line == "OK running" || line == "OK paused" else { continue }
        if let result = sendControlRequest(.hibernate(instance: instance)) {
            print(result.hasPrefix("OK") ? "msl: \(instance) hibernated" : "msl: \(instance): \(result)")
        }
    }
    exit(0)

case "--shutdown":
    performShutdown(instances: args.count > 1 ? [args[1]] : [])
    exit(0)

case "gui":
    // Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 1)
    // - starts the host-side X11-over-vsock tunnel (`DisplayBridge`) and
    // the guest-side one (`x11tunnel`). `msl gui <instance>` alone just
    // gets the tunnel ready; `msl gui <instance> <app...>` also launches
    // an X app through it directly and waits on it (Ctrl-C to kill it
    // early), same as any other one-shot command.
    guard args.count >= 2 else { usageAndExit() }
    let guiInstance = args[1]
    let guiDistro = effectiveDistro(forInstance: guiInstance)
    let guiAppArgs = args.dropFirst(2)

    ensureXQuartzRunning()

    guard let guiResponse = sendControlRequest(.startGui(instance: guiInstance)) else {
        FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    guard guiResponse.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: \(guiResponse)\n".data(using: .utf8)!)
        exit(1)
    }

    // `setsid` + redirecting ALL THREE standard fds (not just stdout/
    // stderr) is required, not cosmetic - confirmed live that a plain
    // `nohup x11tunnel >log 2>&1 &` still leaves the backgrounded
    // x11tunnel holding this one-shot session's own pty SLAVE open via
    // inherited stdin. Since x11tunnel never exits (an accept loop),
    // shellinit.c's relay loop - which only sends the EXIT frame once
    // `read(master_fd)` finally returns EOF - never sees that EOF, because
    // the pty's slave-side reference count never reaches zero while
    // x11tunnel keeps running. The result: this ENTIRE one-shot command
    // session hangs forever, not just the backgrounded job - reproduced
    // live (traced it to exactly this) before adding `setsid </dev/null`
    // here, after which it returns in a fraction of a second like any
    // other one-shot command should.
    // A PID file, not `pgrep -f 'x11tunnel 0 5002'` - confirmed live that
    // pattern is a real footgun: `pgrep -f` matches against every
    // process's FULL command line, and this one-shot command's own
    // enclosing `sh -c "..."` argv literally CONTAINS the text
    // "x11tunnel 0 5002" (it's sitting right there in the command being
    // run) - so pgrep matched the shell running this script against
    // itself, "found" a false positive, and the `||` short-circuited
    // right past ever actually starting x11tunnel. A liveness check via
    // `kill -0` on a remembered PID has no such self-matching hazard.
    // Confirmed live: backgrounding with no delay afterward races the
    // one-shot session's own teardown - the moment this script's last line
    // finishes, shellinit's relay loop sees the pty go EOF and tears the
    // session down, which can hang up the just-forked child before it's
    // finished calling `setsid()` to actually detach (its pty redirection
    // happens first, but the syscall detach itself still needs a scheduler
    // tick it doesn't reliably get under load) - x11tunnel would silently
    // die seconds after being "started" with no error anywhere. Sleeping
    // briefly then re-checking with `kill -0` before this script - and so
    // the whole one-shot session - is allowed to end confirms it actually
    // survived detachment, not just that `setsid` was invoked.
    let (startExit, _) = runOneShotCommand(
        instance: guiInstance, distro: guiDistro,
        command: "kill -0 $(cat /tmp/x11tunnel-0-5002.pid 2>/dev/null) 2>/dev/null || (setsid sh -c 'exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; exec /usr/local/bin/x11tunnel 0 5002' </dev/null >/tmp/x11tunnel.log 2>&1 & echo $! > /tmp/x11tunnel-0-5002.pid; sleep 1; kill -0 $(cat /tmp/x11tunnel-0-5002.pid) 2>/dev/null || (echo 'x11tunnel died immediately after starting - see /tmp/x11tunnel.log' >&2; exit 1))",
        user: "", echo: false
    )
    guard startExit == 0 else {
        FileHandle.standardError.write("msl: failed to start x11tunnel in \(guiInstance)\n".data(using: .utf8)!)
        exit(1)
    }

    if guiAppArgs.isEmpty {
        print("msl: GUI ready for \(guiInstance) - launch an X app with `msl gui \(guiInstance) <app>` or `msl \(guiInstance) -- 'DISPLAY=:0 <app>'`")
        exit(0)
    }
    let guiCommand = "DISPLAY=:0 " + guiAppArgs.joined(separator: " ")
    let guiUser = resolveUser(instance: guiInstance, distro: guiDistro, command: guiCommand)
    runShellSession(instance: guiInstance, distro: guiDistro, command: guiCommand, user: guiUser)

case "gui-native":
    // Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 2)
    // - same shape as `gui` above, but starts `X11Server` ("mslgd", this
    // project's own from-scratch X11 implementation) instead of the
    // XQuartz-tunnel path, on a SEPARATE guest display (`:1`, port 5003)
    // so both can be used side by side without colliding. No XQuartz
    // prerequisite here - `X11Server` bootstraps its own minimal
    // `NSApplication` lazily, see its doc comment.
    guard args.count >= 2 else { usageAndExit() }
    let nativeInstance = args[1]
    let nativeDistro = effectiveDistro(forInstance: nativeInstance)
    let nativeAppArgs = args.dropFirst(2)

    guard let nativeResponse = sendControlRequest(.startNativeGui(instance: nativeInstance)) else {
        FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    guard nativeResponse.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: \(nativeResponse)\n".data(using: .utf8)!)
        exit(1)
    }

    // Same PID-file liveness check as `gui` above, not `pgrep -f` - see
    // its comment for why that self-matches this very one-shot command's
    // own invocation and silently skips ever starting x11tunnel. Same
    // post-background sleep+reverify as `gui` too - see its comment for
    // the detach-vs-teardown race this closes.
    let (nativeStartExit, _) = runOneShotCommand(
        instance: nativeInstance, distro: nativeDistro,
        command: "kill -0 $(cat /tmp/x11tunnel-1-5003.pid 2>/dev/null) 2>/dev/null || (setsid sh -c 'exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; exec /usr/local/bin/x11tunnel 1 5003 --announce' </dev/null >/tmp/x11tunnel-native.log 2>&1 & echo $! > /tmp/x11tunnel-1-5003.pid; sleep 1; kill -0 $(cat /tmp/x11tunnel-1-5003.pid) 2>/dev/null || (echo 'x11tunnel died immediately after starting - see /tmp/x11tunnel-native.log' >&2; exit 1))",
        user: "", echo: false
    )
    guard nativeStartExit == 0 else {
        FileHandle.standardError.write("msl: failed to start x11tunnel in \(nativeInstance)\n".data(using: .utf8)!)
        exit(1)
    }

    if nativeAppArgs.isEmpty {
        print("msl: native GUI ready for \(nativeInstance) - launch an X app with `msl gui-native \(nativeInstance) <app>` or `msl \(nativeInstance) -- 'DISPLAY=:1 <app>'`")
        exit(0)
    }
    let nativeCommand = "DISPLAY=:1 " + nativeAppArgs.joined(separator: " ")
    let nativeUser = resolveUser(instance: nativeInstance, distro: nativeDistro, command: nativeCommand)
    runShellSession(instance: nativeInstance, distro: nativeDistro, command: nativeCommand, user: nativeUser)

case "cage-bridge-test":
    // Ultra-experimental (see cage-planning.md's Phase 3 STATUS section) -
    // debug-only command proving the guest cage bridge
    // (`Guest/init/wayland-tests/cagebridge.c`) can stream real frames to
    // the host's `CageBridge` listener over vsock. NOT a real feature yet
    // (no NSWindow, just raw dumps to /tmp/cageframe_*.raw for byte-level
    // inspection) - Phase 4's visual integration replaces this sink, not
    // the plumbing this proves out.
    guard args.count >= 2 else { usageAndExit() }
    let cageInstance = args[1]
    let cageDistro = effectiveDistro(forInstance: cageInstance)
    let cageNumFrames = args.count > 2 ? args[2] : "10"

    guard let cageResponse = sendControlRequest(.startCageBridge(instance: cageInstance, maxFrames: Int(cageNumFrames) ?? 10)) else {
        FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    guard cageResponse.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: \(cageResponse)\n".data(using: .utf8)!)
        exit(1)
    }

    // Same reasoning as Scripts/cage-test.sh's own harness (see its header
    // comment): one compound guest script in ONE session, not several
    // separate `msl --`-style round trips with gaps between them - avoids
    // both the 3-second idle-suspend debounce and the separate, never-
    // fully-root-caused cross-session backgrounded-process-death gotcha.
    let cwd = FileManager.default.currentDirectoryPath
    let home = NSHomeDirectory()
    let guestRepo = cwd.hasPrefix(home) ? "/mnt/mac" + cwd.dropFirst(home.count) : cwd
    let testDir = "\(guestRepo)/Guest/init/wayland-tests"
    let cageScript = """
    set -e
    apk add --no-cache cage wlroots0.20 wlroots0.20-dev wlr-protocols wayland-dev wayland-protocols libxkbcommon-dev gcc musl-dev >/tmp/cagebridge_ensure.log 2>&1
    wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell-client-protocol.h
    wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell-protocol.c
    wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-unstable-v1-client-protocol.h
    wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-protocol.c
    gcc -O2 -Wall -I/tmp -o /tmp/cagetest_01_static_frame '\(testDir)/01_static_frame.c' /tmp/xdg-shell-protocol.c -lwayland-client
    gcc -O2 -Wall -I/tmp -o /tmp/cagebridge '\(testDir)/cagebridge.c' /tmp/wlr-screencopy-protocol.c -lwayland-client
    mkdir -p /tmp/xdg-runtime && chmod 700 /tmp/xdg-runtime
    pkill -9 cage 2>/dev/null || true
    rm -f /tmp/xdg-runtime/wayland-0*
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime WLR_BACKENDS=headless WLR_RENDERER=pixman \\
        cage -D -- /tmp/cagetest_01_static_frame >/tmp/cagebridge_cage.log 2>&1 &
    CAGEPID=$!
    sleep 1.5
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime /tmp/cagebridge \(cageNumFrames) >/tmp/cagebridge_run.log 2>&1
    BRIDGEEXIT=$?
    kill $CAGEPID 2>/dev/null || true
    cat /tmp/cagebridge_run.log >&2
    exit $BRIDGEEXIT
    """
    let (cageExit, _) = runOneShotCommand(instance: cageInstance, distro: cageDistro, command: cageScript, user: "", echo: true)
    if cageExit == 0 {
        print("msl: cage-bridge-test OK - check /tmp/cageframe_*.raw on the host")
    } else {
        FileHandle.standardError.write("msl: cage-bridge-test failed (exit \(cageExit))\n".data(using: .utf8)!)
    }
    exit(cageExit)

case "cage-input-test":
    // Ultra-experimental (see cage-planning.md's Phase 3 step 3) -
    // debug-only command proving REAL host->guest input injection into a
    // LIVE, continuously-streaming cage/Wayland session: cage wraps
    // `02_input_roundtrip.c` (already renders solid BLACK, switches to
    // solid WHITE on any real `wl_keyboard` key event - reused verbatim,
    // no new fixture needed), `cagebridge` streams frames to the host
    // UNBOUNDED (num_frames=0) the whole time, and `cageinput` sits
    // ready on its own connection. Meanwhile this process injects a
    // synthetic keypress through `CageInputBridge` mid-stream and
    // confirms the round-trip via a REAL captured pixel change (black
    // frame before, white frame after) - the same "confirm via changed
    // content, not just absence of an error" standard Phase 2 and this
    // whole project already hold themselves to.
    guard args.count >= 2 else { usageAndExit() }
    let inputInstance = args[1]
    let inputDistro = effectiveDistro(forInstance: inputInstance)

    guard let frameResp = sendControlRequest(.startCageBridge(instance: inputInstance, maxFrames: 0)), frameResp.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: couldn't start cage frame bridge\n".data(using: .utf8)!)
        exit(1)
    }
    guard let inputResp = sendControlRequest(.startCageInputBridge(instance: inputInstance)), inputResp.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: couldn't start cage input bridge\n".data(using: .utf8)!)
        exit(1)
    }

    let cwd2 = FileManager.default.currentDirectoryPath
    let home2 = NSHomeDirectory()
    let guestRepo2 = cwd2.hasPrefix(home2) ? "/mnt/mac" + cwd2.dropFirst(home2.count) : cwd2
    let testDir2 = "\(guestRepo2)/Guest/init/wayland-tests"
    let protoDir2 = "\(guestRepo2)/Guest/init/wayland-protocols"
    // Same "one compound guest script in ONE session" shape as
    // `cage-bridge-test` above - see its own comment for why. The guest
    // side runs for a flat 10s (cage's own kiosk-exits-with-its-app
    // behavior + `02_input_roundtrip`'s 8s wait-for-key + 3s post-redraw
    // sleep bounds how long it can usefully run anyway - see Phase 2's
    // own notes in cage-planning.md), independent of how fast the host
    // side below actually manages to inject its key.
    let inputScript = """
    set -e
    apk add --no-cache cage wlroots0.20 wlroots0.20-dev wlr-protocols wayland-dev wayland-protocols libxkbcommon-dev gcc musl-dev >/tmp/cageinput_ensure.log 2>&1
    wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell-client-protocol.h
    wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell-protocol.c
    wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-unstable-v1-client-protocol.h
    wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-protocol.c
    wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml /tmp/wlr-virtual-pointer-unstable-v1-client-protocol.h
    wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml /tmp/wlr-virtual-pointer-protocol.c
    wayland-scanner client-header '\(protoDir2)/virtual-keyboard-unstable-v1.xml' /tmp/virtual-keyboard-unstable-v1-client-protocol.h
    wayland-scanner private-code '\(protoDir2)/virtual-keyboard-unstable-v1.xml' /tmp/virtual-keyboard-protocol.c
    gcc -O2 -Wall -I/tmp -o /tmp/cagetest_02_input_roundtrip '\(testDir2)/02_input_roundtrip.c' /tmp/xdg-shell-protocol.c -lwayland-client
    gcc -O2 -Wall -I/tmp -o /tmp/cagebridge '\(testDir2)/cagebridge.c' /tmp/wlr-screencopy-protocol.c -lwayland-client
    gcc -O2 -Wall -I/tmp -o /tmp/cageinput '\(testDir2)/cageinput.c' /tmp/virtual-keyboard-protocol.c /tmp/wlr-virtual-pointer-protocol.c -lwayland-client -lxkbcommon
    mkdir -p /tmp/xdg-runtime && chmod 700 /tmp/xdg-runtime
    pkill -9 cage 2>/dev/null || true
    pkill -9 cagebridge 2>/dev/null || true
    pkill -9 cageinput 2>/dev/null || true
    rm -f /tmp/xdg-runtime/wayland-0*
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime WLR_BACKENDS=headless WLR_RENDERER=pixman \\
        cage -D -- /tmp/cagetest_02_input_roundtrip >/tmp/cageinput_cage.log 2>&1 &
    CAGEPID=$!
    sleep 1.5
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime /tmp/cagebridge 0 >/tmp/cageinput_bridge.log 2>&1 &
    BRIDGEPID=$!
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime /tmp/cageinput >/tmp/cageinput_input.log 2>&1 &
    INPUTPID=$!
    sleep 10
    kill $CAGEPID $BRIDGEPID $INPUTPID 2>/dev/null || true
    exit 0
    """

    // The guest script above blocks in ONE session for its whole ~10s
    // run - it has to happen on a background thread so this process can
    // do the actual host->guest injection (and its own before/after
    // frame comparison) concurrently, on the main thread, while it runs.
    let scriptDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = runOneShotCommand(instance: inputInstance, distro: inputDistro, command: inputScript, user: "", echo: false)
        scriptDone.signal()
    }

    func failInputTest(_ message: String) -> Never {
        FileHandle.standardError.write("msl: cage-input-test FAILED - \(message)\n".data(using: .utf8)!)
        _ = scriptDone.wait(timeout: .now() + 15)
        exit(1)
    }

    // `CageBridge`'s unbounded-mode sink (maxFrames == 0, matching this
    // script's `cagebridge 0`) overwrites one file per frame - see its
    // own doc comment for why (a bounded per-index sink would either
    // fill the disk or hit its cap and close the connection, SIGPIPE-
    // killing the guest, under real continuous streaming).
    let framePath = "/tmp/cageframe_latest.raw"
    var waited = 0.0
    while !FileManager.default.fileExists(atPath: framePath) && waited < 10 {
        Thread.sleep(forTimeInterval: 0.2)
        waited += 0.2
    }
    guard FileManager.default.fileExists(atPath: framePath) else {
        failInputTest("no frames received within 10s - check /tmp/cageinput_*.log on the guest")
    }
    Thread.sleep(forTimeInterval: 0.3) // let a couple more frames settle past the very first one
    let beforeData = try? Data(contentsOf: URL(fileURLWithPath: framePath))

    // KEY_A (Linux evdev keycode 30, from linux/input-event-codes.h) -
    // `02_input_roundtrip.c` reacts to ANY key event, so the specific
    // key doesn't matter. Retries because `cageinput` dials out on its
    // own schedule (build + compositor startup + its own connect retry
    // loop) - stops as soon as a write actually lands on a connected
    // guest, rather than guessing a fixed sleep.
    let keyA: UInt32 = 30
    var sent = false
    for _ in 0..<20 {
        if let resp = sendControlRequest(.sendCageKey(instance: inputInstance, keycode: keyA, pressed: true)), resp.hasPrefix("OK") {
            sent = true
            break
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    guard sent else {
        failInputTest("couldn't inject key - no cageinput connection ever appeared")
    }
    Thread.sleep(forTimeInterval: 0.05)
    _ = sendControlRequest(.sendCageKey(instance: inputInstance, keycode: keyA, pressed: false))

    // Give `02_input_roundtrip` time to redraw and `cagebridge` time to
    // stream a few more frames reflecting the new color.
    Thread.sleep(forTimeInterval: 1.5)
    let afterData = try? Data(contentsOf: URL(fileURLWithPath: framePath))

    _ = scriptDone.wait(timeout: .now() + 15)

    // Sampled at (10,10) - well inside `02_input_roundtrip`'s 200x150
    // solid-fill window, which sits at the top-left of the 1280x720
    // headless canvas (stride 5120 = 1280 * 4 bytes/pixel, XRGB8888 -
    // memory order B,G,R,X, confirmed against a known-red pixel in
    // Phase 3 step 2's own verification). A generous +-30/255 tolerance
    // absorbs nothing in particular here (this is a solid fill, not
    // anti-aliased text) - kept only for symmetry with this project's
    // usual pixel-diff tolerance policy.
    func isBlack(_ d: Data?) -> Bool {
        guard let d, d.count > 10 * 5120 + 10 * 4 + 2 else { return false }
        let off = 10 * 5120 + 10 * 4
        return d[off] < 30 && d[off + 1] < 30 && d[off + 2] < 30
    }
    func isWhite(_ d: Data?) -> Bool {
        guard let d, d.count > 10 * 5120 + 10 * 4 + 2 else { return false }
        let off = 10 * 5120 + 10 * 4
        return d[off] > 225 && d[off + 1] > 225 && d[off + 2] > 225
    }

    if isBlack(beforeData) && isWhite(afterData) {
        print("msl: cage-input-test PASS - real host->guest key injection confirmed (black -> white)")
        exit(0)
    } else {
        FileHandle.standardError.write(
            "msl: cage-input-test FAIL - before black=\(isBlack(beforeData)) after white=\(isWhite(afterData)) (see \(framePath))\n".data(using: .utf8)!
        )
        exit(1)
    }

case "cage-view":
    // Ultra-experimental (see cage-planning.md's Phase 4) - opens a REAL,
    // on-screen `NSWindow` mirroring a live cage session, with real
    // mouse/keyboard forwarded back into the guest via `CageCanvasView`
    // (`Sources/MSLCore/CageCanvasView.swift`, living inside `mslhd`
    // itself - see `VMManager.startCageView()`'s doc comment). Defaults
    // to wrapping `weston-simple-shm` (continuously animated) rather
    // than a static test fixture - a moving pattern is the right smoke
    // test for "is this actually a LIVE stream," not just one frame that
    // happened to land; pass a different guest binary path as a second
    // argument for something interactive instead (e.g. a real GTK/Qt
    // app, once one is installed in the guest).
    guard args.count >= 2 else { usageAndExit() }
    let viewInstance = args[1]
    let viewDistro = effectiveDistro(forInstance: viewInstance)
    let viewApp = args.count > 2 ? args[2] : "/usr/bin/weston-simple-shm"

    guard let viewResp = sendControlRequest(.startCageView(instance: viewInstance)) else {
        FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    guard viewResp.hasPrefix("OK") else {
        FileHandle.standardError.write("msl: \(viewResp)\n".data(using: .utf8)!)
        exit(1)
    }

    let cwd3 = FileManager.default.currentDirectoryPath
    let home3 = NSHomeDirectory()
    let guestRepo3 = cwd3.hasPrefix(home3) ? "/mnt/mac" + cwd3.dropFirst(home3.count) : cwd3
    let testDir3 = "\(guestRepo3)/Guest/init/wayland-tests"
    let protoDir3 = "\(guestRepo3)/Guest/init/wayland-protocols"
    // Same one-compound-guest-script shape as `cage-bridge-test`/
    // `cage-input-test` above. Runs for a flat 5 minutes - long enough
    // for a person to actually look at and interact with the window
    // this opens; `msl cage-view` itself blocks for that whole duration
    // (Ctrl-C stops it early, tearing down the guest session with it).
    let viewScript = """
    set -e
    apk add --no-cache cage wlroots0.20 wlroots0.20-dev wlr-protocols wayland-dev wayland-protocols libxkbcommon-dev weston weston-clients gcc musl-dev >/tmp/cageview_ensure.log 2>&1
    wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-unstable-v1-client-protocol.h
    wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml /tmp/wlr-screencopy-protocol.c
    wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml /tmp/wlr-virtual-pointer-unstable-v1-client-protocol.h
    wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml /tmp/wlr-virtual-pointer-protocol.c
    wayland-scanner client-header '\(protoDir3)/virtual-keyboard-unstable-v1.xml' /tmp/virtual-keyboard-unstable-v1-client-protocol.h
    wayland-scanner private-code '\(protoDir3)/virtual-keyboard-unstable-v1.xml' /tmp/virtual-keyboard-protocol.c
    gcc -O2 -Wall -I/tmp -o /tmp/cagebridge '\(testDir3)/cagebridge.c' /tmp/wlr-screencopy-protocol.c -lwayland-client
    gcc -O2 -Wall -I/tmp -o /tmp/cageinput '\(testDir3)/cageinput.c' /tmp/virtual-keyboard-protocol.c /tmp/wlr-virtual-pointer-protocol.c -lwayland-client -lxkbcommon
    mkdir -p /tmp/xdg-runtime && chmod 700 /tmp/xdg-runtime
    pkill -9 cage 2>/dev/null || true
    pkill -9 cagebridge 2>/dev/null || true
    pkill -9 cageinput 2>/dev/null || true
    rm -f /tmp/xdg-runtime/wayland-0*
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime WLR_BACKENDS=headless WLR_RENDERER=pixman \\
        cage -D -- \(viewApp) >/tmp/cageview_cage.log 2>&1 &
    CAGEPID=$!
    sleep 1.5
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime /tmp/cagebridge 0 >/tmp/cageview_bridge.log 2>&1 &
    BRIDGEPID=$!
    WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg-runtime /tmp/cageinput >/tmp/cageview_input.log 2>&1 &
    INPUTPID=$!
    sleep 300
    kill $CAGEPID $BRIDGEPID $INPUTPID 2>/dev/null || true
    exit 0
    """
    print("msl: cage-view starting for \(viewInstance) - a window should appear on screen shortly (wrapping \(viewApp)). Running for up to 5 minutes; Ctrl-C to stop early.")
    let (viewExit, _) = runOneShotCommand(instance: viewInstance, distro: viewDistro, command: viewScript, user: "", echo: false)
    exit(viewExit)

case "ssh":
    // `msl ssh <instance>` connects. Sets access up first if it has not been
    // set up, so there is no separate "configure" step to remember - the
    // whole point is that this is the only command anyone needs.
    //
    // Execs into ssh by default rather than printing, so it is a peer of
    // `msl <instance>`; `--print` emits the command instead, for scripts and
    // for pasting to someone else.
    let sshInstance = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : defaultInstance
    let printOnly = args.contains("--print")
    let sshDistro = effectiveDistro(forInstance: sshInstance)

    // Cheap path: already configured and still answering.
    let sshUser = LinuxUserSetup.defaultUser(for: sshDistro) ?? "msl"
    var result = SSHSetup.verifyExisting(instance: sshInstance, expectedUser: sshUser)
    if result == nil {
        FileHandle.standardError.write("msl: setting up SSH for \(sshInstance) ...\n".data(using: .utf8)!)
        do {
            result = try SSHSetup.configure(instance: sshInstance, distro: sshDistro, user: sshUser)
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    guard let ready = result else { exit(1) }

    if printOnly {
        print(ready.command)
        exit(0)
    }
    if !ready.reachable {
        FileHandle.standardError.write(
            ("msl: \(sshInstance) is set up, but \(ready.host) is not answering on port 22.\n"
             + "msl: if the Sandbox's Network gate is closed, that is why - vsock still works, so `msl \(sshInstance)` does too.\n")
                .data(using: .utf8)!)
        exit(1)
    }
    // exec, not spawn: ssh should own the terminal, and its exit code should
    // be this process's exit code, exactly like `ssh` run directly.
    let sshPath = "/usr/bin/ssh"
    var execArgs: [UnsafeMutablePointer<CChar>?] = [strdup(sshPath), strdup(ready.alias)]
    execArgs.append(nil)
    execv(sshPath, &execArgs)
    FileHandle.standardError.write("msl: couldn't run \(sshPath)\n".data(using: .utf8)!)
    exit(1)

case "keyboard":
    // What mslgd detects about this Mac's keyboard - layout, languages,
    // ANSI/ISO/JIS, repeat rate - and what Linux apps are told about it.
    // Runs entirely on the Mac; no VM needed. See `X11MacKeyboard`.
    print(X11MacKeyboard.report(keysyms: args.contains("--keysyms")))
    exit(0)

case "status":
    runControl(.status(instance: args.count > 1 ? args[1] : defaultInstance))

// `list`/`ls` are aliases because they are what people try first. `msl
// list` used to fall through to "treat it as an instance name" and create
// one called "list" - see `CommandSuggestion`.
case "doctor":
    // Reports the state that no other command surfaces, and deletes only
    // what the user explicitly asks it to. `--fix` is a separate,
    // deliberate invocation rather than a prompt, so it is safe to run
    // `msl doctor` on a whim and read the result first.
    let shouldFix = args.contains("--fix")
    let environment = Diagnostics.Environment(
        appSupport: MSLPaths.appSupport,
        generatedApps: MSLPaths.generatedAppsDirectory,
        binDirectory: MSLPaths.binDirectory,
        instances: registryForLookup.entries(),
        expectedTools: HostToolInstaller.tools,
        daemonRunning: DaemonClient.isRunning())
    let findings = Diagnostics.run(environment)

    for finding in findings {
        print("\(finding.severity.symbol) \(finding.title)")
        if !finding.detail.isEmpty { print("      \(finding.detail)") }
    }

    let removable: [URL] = findings.flatMap { $0.removable }
    if removable.isEmpty {
        print("\nNothing to clean up.")
        exit(findings.contains { $0.severity == Diagnostics.Severity.problem } ? 1 : 0)
    }

    if !shouldFix {
        print("\n\(removable.count) file(s)/folder(s) can be removed. Review them, then run:")
        print("    msl doctor --fix")
        exit(0)
    }

    var removed = 0
    for url in removable {
        do {
            try FileManager.default.removeItem(at: url)
            removed += 1
            print("removed \(url.lastPathComponent)")
        } catch {
            FileHandle.standardError.write("msl: could not remove \(url.path) - \(error)\n".data(using: .utf8)!)
        }
    }
    print("\nCleaned up \(removed) item(s).")
    exit(0)

case "instances", "list", "ls":
    runControl(.instanceList)

case "new":
    // Explicit creation, so the near-miss guard below has something
    // actionable to point at. An instance is created by being used, so
    // this just needs to make the name real.
    // Sized at creation too, so a terminal user gets the same choices the
    // app's Resources and Storage cards give - checked against this Mac
    // before anything is registered, so a refused size leaves nothing behind.
    let newOptions: InstanceSetupOptions
    let newPositional: [String]
    do {
        (newOptions, newPositional) = try InstanceSetupOptions.parse(Array(args.dropFirst()))
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    // `msl new` alone, at a terminal: the same questions `msl install` asks.
    if newPositional.isEmpty, newOptions.isEmpty, isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 {
        let installed = GuestDistro.allCases.filter { !$0.isCustom && DistroInstallation.isInstalled($0) }
        guard let setupDistro = explicitDistro ?? installed.first else {
            FileHandle.standardError.write("msl: no distro is installed yet - msl install debian (or any of: \(GuestDistro.allCases.filter { !$0.isCustom }.map(\.rawValue).joined(separator: ", ")))\n".data(using: .utf8)!)
            exit(1)
        }
        if explicitDistro == nil, installed.count > 1 {
            print("Installed: \(installed.map(\.rawValue).joined(separator: ", ")) - using \(setupDistro.rawValue) (choose with --distro)")
        }
        requireInstalled(instance: "", distro: setupDistro)
        guard let created = runInstallSetup(for: setupDistro) else { exit(1) }
        print("next: msl \(created)")
        exit(0)
    }
    guard newPositional.count == 1 else {
        FileHandle.standardError.write("usage: msl new <name> [--distro <distro>] \(InstanceSetupOptions.usage)\n".data(using: .utf8)!)
        exit(1)
    }
    let newName = newPositional[0]
    let newWarnings: [String]
    do {
        newWarnings = try InstanceSetup.validate(newOptions)
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        _ = try registryForLookup.ensureRegistered(newName, distro: resolvedDistro(forInstance: newName))
    } catch {
        FileHandle.standardError.write("msl: could not create \(newName) - \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    let newDistro = effectiveDistro(forInstance: newName)
    print("OK created \(newName) (\(newDistro.rawValue))")
    for warning in newWarnings { print("msl: note: \(warning)") }
    if !newOptions.isEmpty {
        do {
            for line in try InstanceSetup.apply(newOptions, instance: newName, distro: newDistro, isRunning: false,
                                                diskInUseBy: runningInstances(using: newDistro), reservationProgress: reservationMeter()) {
                print("  \(line)")
            }
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    if !newDistro.isCustom && !DistroInstallation.isInstalled(newDistro) {
        print("next: msl install \(newDistro.rawValue), then msl \(newName)")
    } else {
        print("next: msl \(newName)")
    }
    exit(0)

case "resources", "config":
    // An instance's CPUs, memory and disk - the Overview tab's Resources and
    // Storage cards, from a terminal. No options shows them.
    let resourceOptions: InstanceSetupOptions
    let resourcePositional: [String]
    do {
        (resourceOptions, resourcePositional) = try InstanceSetupOptions.parse(Array(args.dropFirst()))
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    guard resourcePositional.count <= 1 else {
        FileHandle.standardError.write("usage: msl resources [instance] \(InstanceSetupOptions.usage)\n".data(using: .utf8)!)
        exit(1)
    }
    let resourceInstance = resourcePositional.first ?? defaultInstance
    // Never create an instance by asking about one - a typo here should say
    // so, not register a new instance nobody meant to make.
    guard registryForLookup.list().contains(resourceInstance) else {
        FileHandle.standardError.write("msl: there's no instance called \(resourceInstance) - `msl list` shows them, `msl new \(resourceInstance)` makes it\n".data(using: .utf8)!)
        exit(1)
    }
    let resourceDistro = effectiveDistro(forInstance: resourceInstance)
    guard !resourceOptions.isEmpty else {
        InstanceSetup.summary(instance: resourceInstance, distro: resourceDistro).forEach { print($0) }
        print("\nchange with: msl resources \(resourceInstance) \(InstanceSetupOptions.usage)")
        exit(0)
    }
    do {
        let warnings = try InstanceSetup.validate(resourceOptions)
        let state = sendControlRequest(.status(instance: resourceInstance)) ?? ""
        let running = state.contains("running") || state.contains("paused")
        print(resourceInstance)
        for line in try InstanceSetup.apply(resourceOptions, instance: resourceInstance, distro: resourceDistro, isRunning: running,
                                            diskInUseBy: runningInstances(using: resourceDistro), reservationProgress: reservationMeter()) {
            print("  \(line)")
        }
        for warning in warnings { print("msl: note: \(warning)") }
        exit(0)
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "images":
    // Custom images: folders in Custom Images holding their own kernel,
    // initramfs and disk - see `CustomImage`. An instance uses one with
    // `msl new <name> --distro custom:<image>`.
    let imagesAction = args.count > 1 ? args[1] : "list"
    switch imagesAction {
    case "list":
        let images = CustomImage.scan()
        guard !images.isEmpty else {
            print("no custom images yet - `msl images open` shows the folder and how to make one, `msl images new <image> --distro <distro>` starts one from an installed distro")
            exit(0)
        }
        for image in images {
            let status = image.isUsable ? "ok" : "!!"
            print("  \(status)  \(image.distro.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) \(image.name)")
            for problem in image.problems { print("        problem: \(problem)") }
            for warning in image.warnings { print("        note: \(warning)") }
        }
        exit(0)
    case "open":
        do {
            let folder = try CustomImage.prepareFolder()
            print(folder.path)
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = [folder.path]
            try? opener.run()
            opener.waitUntilExit()
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: couldn't prepare Custom Images - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    case "new":
        guard args.count == 3, let source = explicitDistro, !source.isCustom else {
            FileHandle.standardError.write("usage: msl images new <image> --distro <installed distro>\n".data(using: .utf8)!)
            exit(1)
        }
        do {
            try CustomImage.prepareFolder()
            let image = try CustomImage.create(slug: args[2], from: source, name: args[2])
            print("OK created \(image.distro.rawValue) in \(image.folder.path)")
            print("   use it: msl new <name> --distro \(image.distro.rawValue)")
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: couldn't create the image - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    default:
        FileHandle.standardError.write("usage: msl images [list|open|new <image> --distro <distro>]\n".data(using: .utf8)!)
        exit(1)
    }

case "remove":
    let removeOptions = args.dropFirst().filter { $0.hasPrefix("-") }
    let removeNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    guard removeNames.count == 1, removeOptions.allSatisfy({ $0 == "--keep-disk" }) else {
        FileHandle.standardError.write("usage: msl remove <instance> [--keep-disk]\n".data(using: .utf8)!)
        exit(2)
    }
    if removeOptions.isEmpty,
       let removeDistro = registryForLookup.distro(for: removeNames[0]),
       !removeDistro.isCustom, DistroInstallation.isInstalled(removeDistro),
       instances(of: removeDistro).count == 1 {
        print("\(removeNames[0]) is the last \(removeDistro.rawValue) instance, so its disk (\(DiskStorage.format(DistroInstallation.allocatedBytes(for: removeDistro))) on your Mac) is deleted too.")
    }
    runControl(.remove(instance: removeNames[0], keepDisk: !removeOptions.isEmpty))

case "remove-distro":
    let distroNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    guard distroNames.count == 1, let doomed = GuestDistro(rawValue: distroNames[0]) else {
        FileHandle.standardError.write("usage: msl remove-distro <distro> [--yes]\n".data(using: .utf8)!)
        exit(2)
    }
    let doomedInstances = instances(of: doomed)
    print("Deletes \(doomedInstances.isEmpty ? "the" : doomedInstances.joined(separator: ", ") + " and the") \(doomed.rawValue) disk (\(DiskStorage.format(DistroInstallation.allocatedBytes(for: doomed))) on your Mac).")
    if !args.contains("--yes") && !args.contains("-y") {
        print("Type yes to continue: ", terminator: "")
        guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
            print("msl: nothing deleted")
            exit(1)
        }
    }
    runControl(.removeDistro(distro: doomed))

case "uninstall":
    // Removes MSL. Keeps the Linux, unless explicitly told otherwise - see
    // `Uninstaller`, which owns the plan, the order and the safety rules.
    // This is the only implementation; MSL.app's button runs this command.
    var uninstallMode = Uninstaller.Mode.keepLinux
    var uninstallDryRun = false
    var uninstallAssumeYes = false
    for option in args.dropFirst() {
        switch option {
        case "--everything": uninstallMode = .everything
        case "--dry-run", "-n": uninstallDryRun = true
        case "--yes", "-y": uninstallAssumeYes = true
        default:
            FileHandle.standardError.write("msl: unknown option '\(option)' - usage: msl uninstall [--everything] [--dry-run] [--yes]\n".data(using: .utf8)!)
            exit(2)
        }
    }

    let uninstallPlan = Uninstaller.plan(mode: uninstallMode)
    func printItems(_ heading: String, _ items: [Uninstaller.Item]) {
        guard !items.isEmpty else { return }
        print("\n\(heading)")
        for item in items {
            let size = Uninstaller.format(item.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
            print("  \(item.label.padding(toLength: 34, withPad: " ", startingAt: 0))\(size) \(item.note ?? item.path)")
        }
    }
    print("\(MSLVersion.display) - uninstall")
    printItems("Will remove", uninstallPlan.removing)
    printItems("Will keep - your Linux stays exactly as it is", uninstallPlan.keeping)
    if uninstallPlan.removing.isEmpty {
        print("\nmsl: MSL doesn't appear to be installed on this Mac.")
        exit(0)
    }
    for warning in uninstallPlan.warnings { print("\n\(warning)") }
    if uninstallMode == .keepLinux {
        print("\nInstall MSL again later and it picks up exactly where it left off.")
    }

    if !uninstallDryRun && !uninstallAssumeYes {
        if uninstallMode == .everything {
            // A typed word, the same guard `msl remove` uses: this deletes
            // every image and instance and nothing brings them back.
            print("\nType \(RemovalConfirmation.word) to delete all of it, or anything else to stop: ", terminator: "")
        } else {
            print("\nRemove MSL? [y/N] ", terminator: "")
        }
        let typed = readLine() ?? ""
        let agreed = uninstallMode == .everything
            ? RemovalConfirmation.matches(typed)
            : ["y", "yes"].contains(typed.trimmingCharacters(in: .whitespaces).lowercased())
        guard agreed else {
            print("msl: nothing was removed")
            exit(1)
        }
    }

    print("")
    let uninstallReport = Uninstaller.perform(uninstallPlan, dryRun: uninstallDryRun,
                                              log: { print("msl: \($0)") })
    // One command for everything the package installed as root, plus its
    // receipt - so the Mac really is back to never having had MSL.
    let receiptCheck = Process()
    receiptCheck.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    receiptCheck.arguments = ["--pkg-info", "com.msl.app"]
    receiptCheck.standardOutput = FileHandle.nullDevice
    receiptCheck.standardError = FileHandle.nullDevice
    let hasReceipt = !uninstallDryRun && (try? receiptCheck.run()) != nil && { receiptCheck.waitUntilExit(); return receiptCheck.terminationStatus == 0 }()
    if !uninstallReport.needsSudo.isEmpty || hasReceipt {
        var parts: [String] = []
        if !uninstallReport.needsSudo.isEmpty {
            parts.append("sudo rm -rf " + uninstallReport.needsSudo.map { "'\($0)'" }.joined(separator: " "))
        }
        if hasReceipt { parts.append("sudo pkgutil --forget com.msl.app") }
        print("\nmsl: the installer put \(uninstallReport.needsSudo.isEmpty ? "a receipt" : "these") in place as the system, so finishing needs your password:\n    \(parts.joined(separator: " && "))")
    }
    if !uninstallReport.failed.isEmpty {
        print("")
        for failure in uninstallReport.failed {
            FileHandle.standardError.write("msl: couldn't remove \(failure.path): \(failure.reason)\n".data(using: .utf8)!)
        }
        FileHandle.standardError.write("msl: remove what's listed above by hand, or run `msl uninstall` again.\n".data(using: .utf8)!)
        exit(1)
    }
    if uninstallDryRun {
        print("\nmsl: dry run - nothing was changed.")
    } else if uninstallMode == .keepLinux {
        print("\nmsl: MSL is gone. Your Linux is still in \(MSLPaths.appSupport.path).")
    } else if !uninstallReport.needsSudo.isEmpty {
        print("\nmsl: everything MSL stored is gone - run the command above to remove the rest.")
    } else {
        print("\nmsl: MSL and everything it stored are gone.")
    }
    exit(0)

case "snapshot":
    guard args.count >= 2 else { usageAndExit() }
    switch args[1] {
    case "save":
        guard args.count == 4 else { usageAndExit() }
        runControl(.snapshotSave(instance: args[2], name: args[3]))
    case "restore":
        guard args.count == 4 else { usageAndExit() }
        runControl(.snapshotRestore(instance: args[2], name: args[3]))
    case "list":
        runControl(.snapshotList(instance: args.count > 2 ? args[2] : defaultInstance))
    default:
        usageAndExit()
    }

case "power-test":
    // Drives mslhd's real host-power handlers by hand. The machine cannot
    // be made to sleep, shut down or run its battery flat on demand, so
    // this is the only way those paths are exercised at all - see
    // `SystemResilienceMonitor`.
    guard args.count == 2 else {
        FileHandle.standardError.write("lowbattery|shutdown|lowbattery|wake\n".data(using: .utf8)!)
        exit(1)
    }
    runControl(.powerTest(event: args[1]))

case "storage":
    // Show or change how much disk an instance may use. The image is
    // per-distro, not per-instance (see `InstanceRegistry`), so this
    // reports the name of the file it is actually talking about rather
    // than pretending the setting is private to one instance.
    let storageInstance = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : defaultInstance
    let storageDistro = effectiveDistro(forInstance: storageInstance)
    let storageBoot = storageDistro.bootFiles()
    let imageName = storageBoot.storageKey
    let imagePath = storageBoot.disk.path
    let verb = args.count > 2 ? args[2] : "show"

    func showStorage() {
        let policy = DiskStorage.policy(forImageNamed: imageName, path: imagePath)
        let capacity = DiskStorage.capacity(of: imagePath)
        let allocated = DiskStorage.allocatedSize(of: imagePath)
        print("\(storageInstance) (\(storageDistro.rawValue)) - \(imageName)")
        print("  mode        \(policy.mode.rawValue)\(policy.mode == .dynamic && policy.autoGrow ? " (grows automatically)" : "")")
        print("  capacity    \(DiskStorage.format(capacity)) as the guest sees it")
        print("  on your Mac \(DiskStorage.format(allocated))\(DiskStorage.isSparse(imagePath) ? " (sparse - only what's been written)" : " (reserved)")")
        if policy.mode == .dynamic {
            print("  limit       \(DiskStorage.format(policy.size))")
        }
        if let usage = DiskStorage.usage(forImageNamed: imageName) {
            print("  guest usage \(DiskStorage.format(usage.used)) of \(DiskStorage.format(usage.total)) (\(Int(usage.fraction * 100))%), measured \(usage.sampled.formatted(.relative(presentation: .named)))")
        }
        if DiskStorage.filesystemResizeIsPending(forImageNamed: imageName) {
            print("  pending     the guest filesystem will be extended on the next start")
        }
        print("  free space  \(DiskStorage.format(DiskStorage.hostFreeSpace(forImageAt: imagePath))) left on your Mac")
    }

    switch verb {
    case "show":
        showStorage()
        exit(0)

    case "fixed", "dynamic":
        guard args.count >= 4, let size = DiskStorage.parseSize(args[3]) else {
            FileHandle.standardError.write("usage: msl storage <instance> \(verb) <size, e.g. 32G>\n".data(using: .utf8)!)
            exit(1)
        }
        guard size >= StoragePolicy.minimumSize, size <= StoragePolicy.maximumSize else {
            FileHandle.standardError.write("msl: size must be between \(DiskStorage.format(StoragePolicy.minimumSize)) and \(DiskStorage.format(StoragePolicy.maximumSize))\n".data(using: .utf8)!)
            exit(1)
        }
        let mode: StorageMode = verb == "fixed" ? .fixed : .dynamic
        DiskStorage.setPolicy(StoragePolicy(mode: mode, size: size, autoGrow: mode == .dynamic),
                              forImageNamed: imageName)
        print("msl: \(storageInstance) is now \(verb) at \(DiskStorage.format(size))")

        // Applying it needs the VM stopped: a guest's disk capacity is
        // fixed when its attachment is created, so a change made while it
        // runs cannot reach it until the next boot either way.
        let usingDisk = runningInstances(using: storageDistro)
        if !usingDisk.isEmpty {
            print("msl: \(usingDisk.joined(separator: ", ")) \(usingDisk.count == 1 ? "is" : "are") running on this disk - the new size takes effect once \(usingDisk.count == 1 ? "it stops" : "they stop")")
            exit(0)
        }
        do {
            let before = DiskStorage.capacity(of: imagePath)
            let awake = mode == .fixed ? KeepAwake() : nil
            defer { awake?.release() }
            try DiskStorage.setCapacity(of: imagePath, to: size, reserveSpace: mode == .fixed, progress: reservationMeter())
            let after = DiskStorage.capacity(of: imagePath)
            if after > before {
                // Only when the disk actually got bigger. Marking this
                // unconditionally scheduled a `resize2fs` in the guest after
                // a change that resized nothing.
                DiskStorage.markFilesystemResizePending(forImageNamed: imageName)
                print("msl: disk is now \(DiskStorage.format(after)); the guest filesystem is extended on the next start")
            } else {
                print("msl: disk is already \(DiskStorage.format(after)) - nothing to resize")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

    default:
        FileHandle.standardError.write("usage: msl storage [instance] [show|fixed <size>|dynamic <size>]\n".data(using: .utf8)!)
        exit(1)
    }

case "install-tools":
    // Copies this build's host binaries to `MSLPaths.binDirectory` and
    // installs mslhd's LaunchAgent. Everything outside this repository -
    // generated `.app` bundles above all - reaches MSL through that
    // directory, because `.build/...` is not a path anything can depend
    // on. MSLApp does this itself at launch; this is the same thing for
    // people who live in the terminal.
    let toolSource = HostToolInstaller.runningBinaryDirectory
    // Running the *installed* copy would reinstall the install directory
    // onto itself: every file compares identical, every tool reports
    // "installed", and nothing new is deployed. That silently produced a
    // wrong test result once already - a rebuilt daemon that never reached
    // the machine.
    if toolSource.standardizedFileURL == MSLPaths.binDirectory.standardizedFileURL {
        FileHandle.standardError.write("""
        msl: this is the installed copy, so there is nothing new to install.
             Run install-tools from a build instead, e.g.
             .build/arm64-apple-macosx/release/msl install-tools

        """.data(using: .utf8)!)
        exit(1)
    }
    let toolResult = HostToolInstaller.install(from: toolSource)
    for tool in toolResult.installed { print("installed \(tool)") }
    for tool in toolResult.missing { print("missing \(tool) - not in \(HostToolInstaller.runningBinaryDirectory.path)") }
    for (tool, reason) in toolResult.failed { print("failed \(tool): \(reason)") }
    if DaemonClient.installLaunchAgent() {
        print("installed the mslhd LaunchAgent (\(MSLPaths.launchAgentPlist.path))")
    }
    exit(toolResult.isComplete ? 0 : 1)

case "apps":
    // The host-side view of an instance's Linux GUI applications: scan
    // them out of the guest, and turn any of them into a real macOS `.app`
    // in ~/Applications. See `LinuxAppBundle` for what that bundle is and
    // why it is built this way.
    guard args.count >= 2 else { usageAndExit() }
    let appsAction = args[1]
    let appsInstance = args.count > 2 ? args[2] : defaultInstance
    let appsDistro = effectiveDistro(forInstance: appsInstance)

    func loadApps(rescanning: Bool) -> [LinuxApp] {
        if !rescanning {
            let cached = LinuxAppCatalog.cached(instance: appsInstance)
            if !cached.isEmpty { return cached }
        }
        do {
            return try LinuxAppCatalog.scan(instance: appsInstance, distro: appsDistro) { message in
                FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("msl: couldn't scan \(appsInstance) - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    func descriptor(for app: LinuxApp) -> LinuxAppBundle.Descriptor {
        LinuxAppBundle.Descriptor(
            instance: appsInstance, distro: appsDistro, displayName: app.name,
            command: app.command, icon: LinuxAppCatalog.icon(for: app, instance: appsInstance))
    }

    switch appsAction {
    case "list", "scan":
        let apps = loadApps(rescanning: appsAction == "scan")
        let installed = LinuxAppBundle.installedApps(instance: appsInstance)
        guard !apps.isEmpty else {
            print("no GUI applications found in \(appsInstance)")
            exit(0)
        }
        for app in apps {
            let marker = installed.contains(LinuxAppBundle.fileSafeName(app.name)) ? "*" : " "
            let hasIcon = LinuxAppCatalog.hasRealIcon(for: app, instance: appsInstance) ? "icon" : "    "
            print("\(marker) \(hasIcon)  \(app.name.padding(toLength: min(28, max(app.name.count, 28)), withPad: " ", startingAt: 0))  \(app.command)")
        }
        print("\n\(apps.count) applications ('*' = already in ~/Applications)")
        exit(0)

    case "install":
        guard args.count >= 4 else {
            FileHandle.standardError.write("usage: msl apps install <instance> <app name>\n".data(using: .utf8)!)
            exit(1)
        }
        let wanted = args.dropFirst(3).joined(separator: " ")
        let apps = loadApps(rescanning: false)
        guard let app = apps.first(where: { $0.name.lowercased() == wanted.lowercased() })
            ?? apps.first(where: { $0.name.lowercased().contains(wanted.lowercased()) }) else {
            FileHandle.standardError.write("msl: no application matching '\(wanted)' in \(appsInstance)\n".data(using: .utf8)!)
            exit(1)
        }
        do {
            let url = try LinuxAppBundle.generate(descriptor(for: app))
            print("created \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

    case "install-all":
        let apps = loadApps(rescanning: false)
        var created = 0
        for app in apps {
            do {
                _ = try LinuxAppBundle.generate(descriptor(for: app))
                created += 1
            } catch {
                FileHandle.standardError.write("msl: \(app.name): \(error)\n".data(using: .utf8)!)
            }
        }
        print("created \(created) of \(apps.count) applications in \(MSLPaths.generatedAppsDirectory(instance: appsInstance).path)")
        exit(created == apps.count ? 0 : 1)

    case "pin", "unpin":
        // Pinning needs a bundle to point at, so `pin` generates one if the
        // app hasn't been added yet - the same rule the GUI follows.
        guard args.count >= 4 else {
            FileHandle.standardError.write("usage: msl apps \(appsAction) <instance> <app name>\n".data(using: .utf8)!)
            exit(1)
        }
        let wantedPin = args.dropFirst(3).joined(separator: " ")
        let appsForPin = loadApps(rescanning: false)
        guard let app = appsForPin.first(where: { $0.name.lowercased() == wantedPin.lowercased() })
            ?? appsForPin.first(where: { $0.name.lowercased().contains(wantedPin.lowercased()) }) else {
            FileHandle.standardError.write("msl: no application matching '\(wantedPin)' in \(appsInstance)\n".data(using: .utf8)!)
            exit(1)
        }
        let pinDescriptor = descriptor(for: app)
        if appsAction == "pin", !LinuxAppBundle.exists(pinDescriptor) {
            do {
                _ = try LinuxAppBundle.generate(pinDescriptor)
            } catch {
                FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        let pinURL = LinuxAppBundle.bundleURL(for: pinDescriptor)
        let pinned = appsAction == "pin" ? DockPinner.pin(pinURL) : DockPinner.unpin(pinURL)
        DockPinner.invalidateCache()
        guard pinned else {
            FileHandle.standardError.write("msl: couldn't \(appsAction) \(app.name)\n".data(using: .utf8)!)
            exit(1)
        }
        print("\(appsAction == "pin" ? "pinned" : "unpinned") \(app.name)")
        exit(0)

    case "uninstall":
        guard args.count >= 4 else {
            FileHandle.standardError.write("usage: msl apps uninstall <instance> <app name>\n".data(using: .utf8)!)
            exit(1)
        }
        let wanted = args.dropFirst(3).joined(separator: " ")
        let bundle = MSLPaths.generatedAppsDirectory(instance: appsInstance)
            .appendingPathComponent(LinuxAppBundle.fileSafeName(wanted) + ".app")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            FileHandle.standardError.write("msl: '\(wanted)' isn't installed for \(appsInstance)\n".data(using: .utf8)!)
            exit(1)
        }
        do {
            try FileManager.default.removeItem(at: bundle)
            print("removed \(bundle.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

    default:
        usageAndExit()
    }

case "-h", "--help", "help":
    // Printed, then the full guide opened in the app - a terminal user
    // asking for help gets both. Not when piped or with --no-app.
    print(CLIHelp.render(width: CLIHelp.terminalWidth(STDOUT_FILENO), styled: isatty(STDOUT_FILENO) != 0), terminator: "")
    if !args.contains("--no-app"), isatty(STDOUT_FILENO) != 0 {
        if openInApp("msl://help") {
            print("Opened MSL Help in the MSL app.")
        }
    }
    exit(0)

case "files", "--files":
    // The MSL Files window: every instance's Linux filesystem, from the Mac.
    guard openInApp("msl://files") else {
        FileHandle.standardError.write("msl: couldn't open MSL - is MSL.app installed?\n".data(using: .utf8)!)
        exit(1)
    }
    print("Opened MSL Files.")
    exit(0)

case let instanceName?:
    // ...but not if it looks like a fat-fingered subcommand.
    //
    // Order matters, and the two passes above the check are what keep this
    // safe. An instance that already exists is always addressable, whatever
    // it is called; and a bare distro name means `--distro <that>` (see
    // `effectiveDistro`), so `msl fedora` must keep working no matter how
    // close it lands to some future subcommand. Only a name that is neither
    // is a candidate for "did you mean".
    //
    // Refuses rather than prompting: `msl work ls -la` runs in scripts, and
    // a confirmation prompt would hang a non-interactive invocation. An
    // exit code and a suggestion cost a working pipeline nothing.
    if registryForLookup.distro(for: instanceName) == nil,
       GuestDistro(rawValue: instanceName) == nil,
       let suggestion = CommandSuggestion.nearest(instanceName, in: mslCommands) {
        FileHandle.standardError.write("""
        msl: no instance named '\(instanceName)' - did you mean `msl \(suggestion)`?
             If you really want an instance called '\(instanceName)', run:
                 msl new \(instanceName)

        """.data(using: .utf8)!)
        exit(1)
    }

    // Anything else is treated as an instance name - `msl work` alone
    // opens an interactive shell there; any further args are joined
    // (ssh-style) into a single one-shot command instead, e.g.
    // `msl work ls -la` or `msl work git status`. `msl fedora` (a name
    // that happens to match a distro) implies `--distro fedora` with
    // nothing else needed - see `resolvedDistro`.
    let distro = effectiveDistro(forInstance: instanceName)
    let command = args.dropFirst().joined(separator: " ")
    let user = resolveUser(instance: instanceName, distro: distro, command: command)
    runShellSession(instance: instanceName, distro: distro, command: command, user: user)
}
