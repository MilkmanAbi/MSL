import Foundation
import CryptoKit
import MSLCore
import PublicMSL
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
/// Like `runControl`, for a request that legitimately takes minutes.
///
/// The default control timeout is nowhere near enough to copy a
/// multi-gigabyte disk into a container, and a client that gave up
/// half way would report a failure while the daemon carried on - the worst
/// of both, since the operation is the one that moves somebody's only copy
/// of their machine.
func runControlWithTimeout(_ request: DaemonProtocol.ControlRequest,
                           timeout: TimeInterval) -> Never {
    guard let reply = sendControlRequestMultiline(request, timeout: timeout) else {
        FileHandle.standardError.write("msl: no response from mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    print(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    exit(reply.hasPrefix("OK") ? 0 : 1)
}

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

/// The same, but for a reply that has more than one line in it.
///
/// `readLine` stops at the first newline, which quietly truncated every
/// multi-line answer: `msl public keys` showed one key however many were
/// authorized, and the notify list showed nobody at all. It looked like the
/// data was missing rather than like the reply was cut in half, which is
/// why it went unnoticed with a single entry.
///
/// Safe to read to the end because mslhd closes the connection once it has
/// answered these - checked against the running daemon rather than assumed,
/// since reading to EOF on a connection it held open would hang.
func sendControlRequestMultiline(_ request: DaemonProtocol.ControlRequest,
                                 timeout: TimeInterval = 60) -> String? {
    guard let fd = bestEffortConnectToDaemon() else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = request.encode().withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        response.append(contentsOf: buffer[0..<count])
    }
    guard !response.isEmpty else { return nil }
    let text = String(decoding: response, as: UTF8.self)
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
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

/// The live shell connection, shared with the writer thread.
///
/// A reattach replaces the connection underneath a session that is already
/// running, so the writer cannot capture the fd once - it reads this each
/// time round. `-1` means "detached, nothing to write to": input typed
/// while an instance is hibernated is dropped rather than sent into a dead
/// socket, which is what the user sees anyway.
nonisolated(unsafe) var sessionDataFD: Int32 = -1

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
    if ProcessInfo.processInfo.environment["MSL_NO_DISPLAY"] == nil,
       !command.hasPrefix("DISPLAY="), !command.hasPrefix("export DISPLAY=") {
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

    // Tell the guest what this Mac terminal can display (see
    // `TerminalProfile`): without it every guest shell ran with no TERM.
    if let profile = TerminalProfile.detect(environment: ProcessInfo.processInfo.environment,
                                            interactive: isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1) {
        guestCommand = command.isEmpty ? profile.interactiveCommand : profile.exports + "\n" + guestCommand
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

    var dataFD: Int32
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
        // Scrollback and all - see `TerminalClear`. Erasing the screen on
        // its own looked right and was not: Terminal.app pushes what was on
        // screen into the scrollback, so scrolling up after starting a
        // session showed the shell's own "last login", the command line,
        // and a screenful of blank rows above the banner.
        print(TerminalClear.full, terminator: "")
        print("\u{1B}[1;32mmsl\u{1B}[0m@\u{1B}[1;36m\(distro.rawValue)\u{1B}[0m")
        // Dimmed, and never the same twice running - see `Greeter`. Below
        // the banner rather than above it so the line that actually tells
        // you which machine you are on stays first. Whether that is a line,
        // the cat, the cat saying the line, or nothing at all is
        // `PersonalityBanner`'s decision, shared with the app so the
        // preview there is the same thing that prints here.
        let personality = PersonalitySettingsStore.load()
        if let banner = PersonalityBanner.render(settings: personality,
                                                 greeting: Greeter.nextGreeting()?.text,
                                                 columns: Int(currentWindowSize().cols)) {
            print("\u{1B}[2m\(banner)\u{1B}[0m")
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
    // Only an interactive shell is worth reattaching to. A one-shot command
    // has a result the caller is waiting on, and silently waiting out a
    // hibernate instead of returning would hang somebody's script.
    let sessionID = command.isEmpty ? ShellProtocol.newSessionID() : ""
    writeFull(fd: dataFD, bytes: ShellProtocol.encodeExec(command: guestCommand, rows: rows, cols: cols, user: user,
                                            sessionID: sessionID))

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
                if sessionDataFD >= 0 {
                    writeFull(fd: sessionDataFD, bytes: ShellProtocol.encodeResize(rows: r, cols: c))
                }
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
                if sessionDataFD >= 0 { shutdown(sessionDataFD, Int32(SHUT_WR)) }
                break
            }
            if sessionDataFD >= 0 {
                writeFull(fd: sessionDataFD, bytes: ShellProtocol.encodeData(buf[0..<n]))
            }
        }
    }
    sessionDataFD = dataFD
    writer.start()

    // guest -> stdout, until EXIT (normal end of session) or the
    // connection just drops (guest-side crash, VM going away mid-session,
    // etc. - treated as a plain failure exit rather than hanging).
    var exitCode: Int32 = 1
    var sawExit = false
    var sawOutput = false
    /// Set when the guest answers EXEC with a `session` frame, which only a
    /// `shellinit` that understands detachable sessions does. Its absence
    /// is the whole backward-compatibility story: an older guest simply
    /// never sets this and the loop below ends at the first EOF, exactly as
    /// it always did.
    var liveSession: (id: String, port: UInt32)?

    relay: while true {
        while true {
            guard let frame = readShellFrame(fd: dataFD) else { break }
            switch frame.type {
            case .data:
                sawOutput = true
                writeFull(fd: STDOUT_FILENO, bytes: frame.payload)
            case .exit:
                exitCode = Int32(frame.payload.first ?? 1)
                sawExit = true
            case .session:
                liveSession = ShellProtocol.parseSession(frame.payload)
            case .exec, .resize, .attach, .detach:
                break // host->guest-only frame types - shellinit never sends these
            }
        }

        // The shell itself ended, so there is nothing to come back to.
        if sawExit { break relay }

        // The connection went, but the shell did not. A hibernate saves the
        // guest's whole RAM: the shell, its pty and its children are all
        // still there on the other side, and only the vsock died. So wait,
        // and pick the same session back up rather than silently abandoning
        // it - which is what used to happen, leaving a live shell stranded
        // in the guest forever.
        guard let session = liveSession else { break relay }
        switch awaitReattach(instance: instance, session: session, restoring: originalTermios) {
        case .reattached(let next):
            close(dataFD)
            dataFD = next
            sessionDataFD = next
            continue relay
        case .ended:
            // A deliberate end - `poweroff`, or the person pressing q. Not
            // the "connection closed unexpectedly" case, and saying so would
            // turn a normal shutdown into something that looks broken.
            sawExit = true
            exitCode = 0
            break relay
        case .abandoned:
            break relay
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
    if requestedUser.isEmpty, registry.defaultUser(forInstance: instance) == user {
        try? registry.forgetDefaultUser(forInstance: instance)
        message += " MSL remembered it from an earlier \(instance) session and has now forgotten it -"
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
        // A one-shot sends no session id, so `.session` never arrives here.
        case .exec, .resize, .session, .attach, .detach:
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
    let personality = PersonalitySettingsStore.load()
    print("""

    \(personality.kitty ? mslMascot : "")

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
            try? LinuxUserSetup.registry().setDefaultUser(username, forInstance: instance)
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

/// Finds the one app a name means, or explains why it is ambiguous.
///
/// Matching on `name` alone stopped working the moment an instance had the
/// same application from two packaging systems: with a Flatpak Calculator
/// and a Snap Calculator installed, `msl apps install Milk Calculator`
/// silently picked whichever came first, and there was no way to ask for
/// the other one at all. `qualifiedName` ("Calculator (Snap)") is how the
/// app itself distinguishes them, so the CLI accepts that too - and when a
/// name really is ambiguous it says so instead of guessing.
func resolveApp(named wanted: String, in apps: [LinuxApp], instance: String) -> LinuxApp {
    let needle = wanted.lowercased()
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }
    if let exact = apps.first(where: { $0.qualifiedName.lowercased() == needle }) { return exact }

    let byName = apps.filter { $0.name.lowercased() == needle }
    let candidates = byName.isEmpty
        ? apps.filter { $0.name.lowercased().contains(needle) || $0.qualifiedName.lowercased().contains(needle) }
        : byName
    switch candidates.count {
    case 0:
        fail("msl: no application matching '\(wanted)' in \(instance)")
    case 1:
        return candidates[0]
    default:
        let list = candidates.map { "       msl apps ... \($0.qualifiedName)" }.joined(separator: "\n")
        fail("""
        msl: '\(wanted)' matches \(candidates.count) applications in \(instance) - name one exactly:
        \(list)
        """)
    }
}

/// Every command, from `CLICommands` - shared with `ArgumentSplitter` (which
/// needs to know which ones have a guest command after them) and with
/// instance creation (which refuses to name an instance after one).
let mslCommands = CLICommands.sorted

// This CLI forwards a command line into the guest, so it must stop looking
// for its own options where the guest's command starts - see
// `ArgumentSplitter`, which is where the rule and its tests live. Scanning
// the whole argument list (as this used to) made `msl work echo -d /tmp`
// die with "unknown distro '/tmp'" and quietly ate the `-u 1000` out of
// `msl work docker run -u 1000 img`.
let splitArguments = ArgumentSplitter.split(
    Array(CommandLine.arguments.dropFirst()), knownCommands: CLICommands.all)

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
// `let` until the alias pass below, which is the only thing that rewrites it.
var args = rawArgs
// A terminal does not need a picture, but the note it leaves behind is what
// the screen reads if the app is what shows it next.
CrashScreen.install(for: .cli, viewer: "/Applications/MSL.app/Contents/MacOS/MSLApp")

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

// A guessed command (`msl start Milk`) is translated into MSL's own word
// rather than becoming an instance called "start" - see `CommandAliases`.
// Placed here because the registry is what decides it: an instance really
// named `run` outranks the alias, always.
do {
    let resolved = CommandAliases.resolve(args, isTaken: { registryForLookup.distro(for: $0) != nil })
    if resolved.arguments != args {
        args = resolved.arguments
        rawArgs = resolved.arguments
        if let note = resolved.note {
            FileHandle.standardError.write((note + "\n").data(using: .utf8)!)
        }
    }
}

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

/// What `msl update` was asked to do - see the `update` case.
enum UpdateAction { case check, download }

/// `msl update`. The CLI face of the same core the app's update prompt uses.
func runUpdate(_ action: UpdateAction) -> Never {
    let current = UpdateCheck.Version(MSLVersion.marketing)!
    print("\(MSLVersion.display) - checking for updates")

    // A deliberately unthrottled, unsilenced check: somebody who typed the
    // command is asking, and "I checked yesterday" is not an answer to a
    // question asked now. That is the same rule the app's
    // "Check for Updates..." menu item follows.
    let decision = runBlocking { await UpdateCheck.run(current: current, state: UpdateCheck.State()).0 }

    guard let decision else {
        FileHandle.standardError.write("msl: couldn't check just now - try again in a moment\n".data(using: .utf8)!)
        exit(1)
    }
    switch decision.kind {
    case .unknown:
        FileHandle.standardError.write("msl: couldn't reach GitHub - are you online?\n".data(using: .utf8)!)
        exit(1)
    case .upToDate:
        print("You have the newest MSL.")
        for other in decision.alsoAvailable {
            print("  (\(other.tag) exists but needs MSL \(other.minimum?.description ?? "newer") or later)")
        }
        exit(0)
    case .advisory:
        // Nothing installable: this copy is below the release's minimum.
        if let release = decision.release {
            print("MSL \(release.version) is out, but it needs MSL \(release.minimum?.description ?? "newer") or later.")
            print("See \(release.page.absoluteString)")
        }
        exit(0)
    case .suppressed, .update:
        break
    }
    guard let release = decision.release else { exit(0) }

    print("MSL \(release.version) is available\(decision.urgent ? " - unsafe-behaviour patch" : "").")
    if let info = runBlocking({ await UpdateCheck.fetchInfo(for: release.tag) }), !info.isEmpty {
        print("")
        for line in info.split(separator: "\n") { print("  \(line)") }
        print("")
    }

    guard action != .check else {
        print("  msl update --download   put the installer in your Downloads")
        exit(0)
    }

    // The download, always first and always complete before anything is
    // removed - OIS's "a failure anywhere leaves the current install
    // untouched". `msl update --install` that cannot download is a no-op,
    // not a broken Mac.
    let fetched: UpdateDownload.Fetched
    do {
        var lastLine = ""
        fetched = try UpdateDownload.fetch(release, transfer: { progress in
            // One line, rewritten - a progress bar in a pipe is noise.
            guard isatty(STDOUT_FILENO) != 0 else { return }
            let line = "  \(progress.description)"
            guard line != lastLine else { return }
            lastLine = line
            print("\r\(line)", terminator: "")
            fflush(stdout)
        }, log: { line in
            if isatty(STDOUT_FILENO) != 0 { print("\r\u{1B}[K", terminator: "") }
            print("  \(line)")
        })
    } catch {
        FileHandle.standardError.write("msl: \(error.localizedDescription)\n".data(using: .utf8)!)
        FileHandle.standardError.write("     Nothing was changed. \(UpdateCheck.releasesPage.absoluteString)\n".data(using: .utf8)!)
        exit(1)
    }
    if isatty(STDOUT_FILENO) != 0 { print("\r\u{1B}[K", terminator: "") }
    let how = fetched.verification == .checksum
        ? "checksum verified"
        : "verified as MSL \(release.version)"
    print("  \(fetched.url.path)  (\(how))")

    print("\nOpen that package to install it - it closes your instances and replaces MSL in place.")
    exit(0)
}

/// Instances that are actually live right now, for the warning before an
/// update. Empty when the daemon is not running - every VM lives inside it.
func runningInstanceNames() -> [String] {
    guard DaemonClient.isRunning() else { return [] }
    return registryForLookup.entries().map(\.key).sorted().filter { name in
        let status = DaemonClient.send(.status(instance: name), timeout: 10)
        return status == "OK running" || status == "OK paused"
    }
}

/// Runs an async call from this synchronous CLI.
func runBlocking<T>(_ work: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task { result = await work(); semaphore.signal() }
    semaphore.wait()
    return result!
}

/// How many instances exist of each distro, by distro name - the right-hand
/// column of the distro table.
func instanceCountsByDistro() -> [String: Int] {
    var counts: [String: Int] = [:]
    for (_, distro) in registryForLookup.entries() {
        counts[distro.rawValue, default: 0] += 1
    }
    return counts
}

/// `msl distros` and `msl list online`: every distro MSL can install, with a
/// tick against the ones already here.
///
/// Fetches the catalog with a short timeout and only one source, not the
/// install path's two-hosts-twice: this is a listing, and someone who typed
/// it is watching the terminal. The names and what this Mac has are known
/// offline, so a failed fetch costs the releases and sizes, not the table.
func printDistroTable(header: Bool = true) {
    // `fetch` tries the sources in order with this timeout each, so the
    // worst case is both hosts down at 5s apiece - fine for a listing
    // somebody is watching, unlike the install path's two-tries-per-host.
    // Listing is a read, and a refused override must not take the table
    // down with it - MSL's own sources are what `msl distros` is for.
    let listingSources = (try? DistroInstaller.resolveSources(override: manifestURLOverride))
        ?? DistroInstaller.defaultSources
    let catalog = DistroCatalog.fetch(from: listingSources, timeout: 5)
    let rows = DistroListing.rows(catalog: catalog,
                                  instanceCounts: instanceCountsByDistro(),
                                  isInstalled: { DistroInstallation.isInstalled($0) })
    if header { print("Distros MSL can install:") }
    print(DistroListing.table(rows), terminator: "")
    if catalog == nil {
        print("(couldn't reach the image catalog, so no releases or sizes - are you online?)")
    }
    print("\nInstall one with msl install <distro>, for example:\n\n    msl install debian")
}

/// What plain `msl` prints - see `CLIOverview`. Registry only: no daemon
/// connection and no network, so typing `msl` never starts anything.
func printOverview() {
    let entries = registryForLookup.entries()
    // `startupInstance()`, not `lastUsed()`: that is the one `msl run` with
    // no name actually opens, and the two differ whenever the last-used
    // instance has since been removed. Marking the wrong row is worse than
    // marking none - but only mark it when it is a row that exists, since on
    // a first-ever run this is the built-in default and nothing is listed.
    let opens = startupInstance()
    let lines = entries
        .sorted { $0.key < $1.key }
        .map { CLIOverview.InstanceLine(name: $0.key, distro: $0.value.rawValue,
                                        isLastUsed: $0.key == opens) }
    print(CLIOverview.render(instances: lines,
                             styled: isatty(STDOUT_FILENO) != 0,
                             emptyHint: "See them all with msl distros.\n"),
          terminator: "")
}

/// Whether `name` can be opened as an instance, and why not if it can't.
///
/// Guards the two places that open a session by name - `msl run <name>` and
/// the bare-name fallthrough - so neither can register junk. MSL creates an
/// instance by being asked to use one, which is the ergonomic that makes
/// `msl fedora` work on a fresh install; the cost was that **any** word MSL
/// didn't recognise became a real instance with a real disk. `msl about`
/// downloaded Alpine and bootstrapped it (2026-10-01).
///
/// The rule: a name that already exists is always openable, and a name that
/// doesn't is created only when the distro was said out loud - either
/// because the name *is* a distro (`msl fedora`) or because `--distro` was
/// passed (`msl work --distro debian`). Both are documented forms and both
/// keep working. Everything else is a typo until `msl new` says otherwise.
func openableRefusal(_ name: String) -> String? {
    if registryForLookup.distro(for: name) != nil { return nil }
    if let refusal = CLICommands.nameRefusal(name) {
        return refusal
    }
    if GuestDistro(rawValue: name) != nil || explicitDistro != nil { return nil }
    var message = "there's no instance called '\(name)'."
    if let suggestion = CommandSuggestion.nearest(name, in: mslCommands) {
        message += " Did you mean `msl \(suggestion)`?"
    }
    message += """

         Make it:        msl new \(name)
         What you have:  msl list
    """
    return message
}

/// A Mac with nothing installed: what can be downloaded.
///
/// The same table `msl distros` prints - one renderer, since the version that
/// greets an empty Mac and the version someone asks for are the same facts.
func printAvailableDistros() {
    print("Nothing installed yet.\n")
    printDistroTable(header: false)
}

/// Stops before a session on a distro whose image isn't on this Mac, with the
/// command that fixes it - rather than asking for a Linux account on a disk
/// that doesn't exist.
func requireInstalled(instance: String, distro: GuestDistro) {
    // **An instance that already has its own disk is installed**, whatever
    // the distro's base says. Those are two different questions now
    // (`InstanceDisk`): the base is what a *new* instance would be cloned
    // from, and deleting it - which the migration to per-instance disks does
    // - must not strand the instances that were already running.
    // An instance with its own disk has its *filesystem*, which is not the
    // same as being bootable: the kernel and initramfs are shared by every
    // distro and arrive with the first one downloaded. A shipment brings the
    // filesystem and nothing else, so this short-circuit let an installed
    // shipment reach Virtualization and fail with a raw boot-loader error.
    if InstanceDisk.exists(instance: instance) {
        guard let reason = distro.bootFiles(instance: instance).missingDescription(distro: distro)
        else { return }
        FileHandle.standardError.write("msl: \(instance) can't start - \(reason)\n".data(using: .utf8)!)
        exit(1)
    }
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
        .filter { $0.key != instance
                  && (InstanceDisk.exists(instance: $0.key)
                      || $0.value.isCustom || DistroInstallation.isInstalled($0.value)) }
        .map(\.key).sorted()
    if !ready.isEmpty {
        message += "\nor open one you already have: " + ready.map { "msl run \($0)" }.joined(separator: ", ") + "\n"
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
    if let remembered = userRegistry.defaultUser(forInstance: instance) { return remembered }
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

/// Prints to stderr and stops. The existing `fail` is nested inside another
/// command's body, so it is not in scope out here.
func usbFail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// `msl usb list`, aligned into columns here rather than in the daemon -
/// the daemon has no idea how wide this terminal is.
func runUSBList() {
    guard let reply = sendControlRequest(.usbList) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK") else {
        print(reply)
        return
    }
    let body = String(reply.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    let rows = body.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    let headers = ["LOCATION", "ID", "macOS DRIVER", "ATTACHED TO", "DEVICE"]
    let table = [headers] + rows.filter { $0.count == 5 }
    // Last column unpadded: it is the free-text name and nothing follows it.
    var widths = [Int](repeating: 0, count: 5)
    for row in table {
        for (index, cell) in row.enumerated() where index < 4 {
            widths[index] = max(widths[index], cell.count)
        }
    }
    for (number, row) in table.enumerated() {
        var line = ""
        for (index, cell) in row.enumerated() {
            line += index < 4 ? cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0) : cell
        }
        print(number == 0 && isatty(STDOUT_FILENO) != 0 ? "\u{1B}[1m\(line)\u{1B}[0m" : line)
    }
    print("")
    print("A device with no macOS driver is passed through directly.")
    print("One macOS has a driver for is taken from it, which needs your password.")
}

/// `msl usb attach`.
///
/// The whole point of this function is that the person never types `sudo`.
/// It asks the daemon which tier the device needs first: a device macOS has
/// never heard of is attached with no privileges at all and this returns
/// immediately, and only a device macOS owns escalates - with an
/// explanation of why, before the password prompt rather than after it.
func runUSBAttach(device: String, instance: String, forceRelay: Bool = false) {
    // `sudo msl` does not work and must not look as though it half does:
    // every MSL path resolves through NSHomeDirectory(), which under sudo is
    // /var/root - so it would install a second set of tools there, fail to
    // find the daemon, and find no instances. MSL escalates the one small
    // program that needs it, itself.
    if ProcessInfo.processInfo.environment["SUDO_UID"] != nil {
        usbFail("""
        msl: don't run msl with sudo - it would look for your instances in /var/root and find none.

          Run `msl usb attach \(device)` as yourself. If the device needs taking from macOS,
          MSL asks for your password at that point and only the small USB helper runs as root.
        """)
    }

    guard let reply = sendControlRequest(.usbPlan(device: device)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK") else {
        usbFail(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    let fields = String(reply.dropFirst(3)).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 6, let speed = UInt32(fields[2]) else {
        usbFail("msl: mslhd sent a plan this version doesn't understand")
    }
    let (tier, token, driver, holder, name) = (fields[0], fields[1], fields[3], fields[4], fields[5])
    _ = speed

    if holder != "-" {
        usbFail("msl: \(name) is already attached to \(holder) - detach it there first:\n  msl usb detach \(token) \(holder)")
    }

    if tier == "NATIVE", !forceRelay {
        // Nothing on the Mac wants this device, so mslhd can open it itself.
        runControl(.usbAttach(instance: instance, device: token, capture: false))
        return
    }

    if forceRelay {
        print("Driving the privileged path deliberately (--relay), with \(name).")
        print("This is the only way to check the root helper, its handshake socket and the")
        print("relay without real hardware attached.")
    } else {
        // macOS owns it. Say so, name the driver, and say that it goes back.
        print("\(name) is being used by macOS (\(driver)).")
        print("MSL can take it for \(instance), and macOS gets it back when you detach.")
        print("That needs your password - only MSL's small USB helper runs as root, not msl itself.")
        // Taking a disk from macOS's storage driver is a forced unmount, so
        // say that *before* the password rather than after the volume has
        // gone. "Disk not ejected properly" is the single most alarming
        // thing MSL could do without warning.
        if driver.contains("MassStorage") {
            print("")
            print("This is a disk. Taking it unmounts it the hard way - eject it in Finder first,")
            print("or anything still writing to it loses what it had not flushed.")
        }
    }
    print("")

    let relay = sendControlRequest(.usbRelay(instance: instance, device: token))
    guard let relay, relay.hasPrefix("OK ") else {
        usbFail((relay ?? "msl: couldn't reach mslhd")
            .replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    let socketPath = String(relay.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)

    // Never the copy in Application Support: guests get the Mac's home at
    // /mnt/mac read-write, so a Linux process can replace that binary - and
    // this one runs as root. See `USBHelperLocator`.
    let helper: String
    switch USBHelperLocator.trustedHelper() {
    case .success(let found): helper = found
    case .failure(let refusal): usbFail(refusal.description)
    }

    // exec, not spawn - the same reasoning as `msl ssh` above, and here it
    // is not a nicety: Foundation's `Process` puts the child in a new
    // process group, so `sudo` takes SIGTTIN the instant it reads the
    // terminal and stops dead. Measured: `stat T`, with the process group
    // not the terminal's foreground group, and a password prompt that never
    // accepted anything. `msl` has nothing to do afterwards anyway - the
    // attachment lasts exactly as long as the helper, so ^C is the detach -
    // and exec makes the signals, the terminal and the exit status all
    // behave with no extra code.
    //
    // A foreground process rather than a privileged daemon, on purpose:
    // nothing of MSL's runs as root between attaches.
    var arguments = [
        "sudo",
        // A prompt that says what the password is for. `sudo`'s bare
        // "Password:" in the middle of a USB command reads like something
        // has gone wrong, and a prompt nobody understands is one people
        // type into without reading.
        "-p", "Password for MSL to take \(name) from macOS: ",
        helper, "serve-relay", token, "--connect", socketPath,
    ]
    // The synthetic self-test has no hardware to take from anybody, and
    // asking for capture would make the helper refuse for no reason.
    if token == "synthetic" { arguments.append("--no-capture") }
    var execArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    execArgs.append(nil)
    execv("/usr/bin/sudo", &execArgs)
    usbFail("msl: couldn't run /usr/bin/sudo: \(String(cString: strerror(errno)))")
}

/// Prints an endpoint the way somebody would use it.
func printEndpoint(_ fields: [String]) {
    guard fields.count >= 6, let port = UInt16(fields[1]) else {
        print("msl: mslhd sent an endpoint this version doesn't understand")
        return
    }
    let (host, user, key, expiry) = (fields[0], fields[2], fields[3], fields[4])
    print("")
    print("  \(user)@\(host):\(port)")
    print("")
    print("  ssh -i \"\(key)\" -o IdentitiesOnly=yes -p \(port) \(user)@\(host)")
    print("")
    // What to send somebody else. The line above names a file that exists
    // on this Mac and nowhere else, so pasting it to a colleague reads as
    // an instruction they cannot follow.
    print("  To send to someone else:")
    print("  ssh -i path/to/key -o IdentitiesOnly=yes -p \(port) \(user)@\(host)")
    print("")
    if let seconds = Int(expiry), seconds > 0 {
        let minutes = seconds / 60
        print("  This address lasts about \(minutes) minute\(minutes == 1 ? "" : "s") - the free relay ends")
        print("  the session and MSL opens a new one, with a new address. For an address that")
        print("  does not move, publish through a server you control.")
    } else {
        print("  No expiry.")
    }
}

/// Asks before putting a machine on the internet.
///
/// Publishing is not like the rest of `msl`: everything else here changes
/// something on this Mac, and this one makes a machine reachable by
/// strangers. It deserves a deliberate yes, once, with the consequence
/// stated plainly rather than buried in a man page.
///
/// Skipped when there is no terminal to ask - a script that calls this has
/// already decided - and skipped with `--yes`, which is what somebody
/// automating it will reach for.
func confirmPublish(instance: String, force: Bool) {
    if force || isatty(STDIN_FILENO) == 0 { return }
    print("")
    print("  Publishing \(instance) makes its SSH port reachable from the internet.")
    print("  Anyone who gets the address can try to log in. MSL turns password")
    print("  logins off first, so only the keys you authorize will work.")
    print("")
    print("  Worth knowing: your Mac's home folder is inside every instance at")
    print("  /mnt/mac, and they can write to it. Anyone you let in has that too -")
    print("  so this shares those files, not just the Linux machine.")
    print("")
    print("  Keys that can log in afterwards:")
    print("    - one MSL makes for this Mac")
    print("    - any you added with: msl public authorize \(instance) <key.pub>")
    print("")
    print("  Stop it any time with: msl public revoke \(instance)")
    print("")
    FileHandle.standardOutput.write("  Publish \(instance)? [y/N] ".data(using: .utf8)!)
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else {
        print("  Left alone.")
        exit(0)
    }
    print("")
}

/// Turns `user@host:2222` into the token the daemon stores.
///
/// The port is required and deliberately not defaulted: it is the one
/// number somebody else has to know to connect, and guessing it for them
/// would mean publishing on a port they never chose.
func selfHostedToken(_ value: String) -> String {
    let parts = value.split(separator: ":").map(String.init)
    guard parts.count >= 2, let port = UInt16(parts[1]), port > 0 else {
        print("msl: --via needs a server and a port, like --via=root@my.vps:2222")
        print("     The port is the one people will connect to there.")
        print("     Ports below 1024 need root on that server, so pick a higher one.")
        exit(1)
    }
    let sshPort = parts.count >= 3 ? (UInt16(parts[2]) ?? 22) : 22
    return "self-hosted:\(parts[0]):\(port):\(sshPort):"
}

/// `msl public key [instance] [--reveal]`
func runPublicKeyLocation(instance: String, reveal: Bool) {
    guard let reply = sendControlRequest(.publicStatus(instance: instance)),
          reply.hasPrefix("OK ") else {
        print("\(instance) isn't published, so there's no key for it yet.")
        print("Publish it with: msl public expose \(instance)")
        exit(1)
    }
    let fields = String(reply.dropFirst(3)).components(separatedBy: "\t")
    guard fields.count >= 4 else {
        usbFail("msl: mslhd sent an endpoint this version doesn't understand")
    }
    let path = fields[3]
    guard FileManager.default.fileExists(atPath: path) else {
        print("The key for \(instance) isn't on disk.")
        print("Publish it again to make a new one: msl public expose \(instance)")
        exit(1)
    }
    print(path)
    if reveal {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", path]
        try? process.run()
    }
}

/// `msl public tips <instance> [platform]` - the steps for whoever is
/// connecting, in the words that actually work.
func runPublicTips(instance: String, platform: String) {
    let chosen: ConnectionTips.Platform
    switch platform.lowercased() {
    case "windows", "win":      chosen = .windows
    case "linux":               chosen = .linux
    case "freebsd", "bsd":      chosen = .freeBSD
    case "mac", "macos", "osx": chosen = .macOS
    default:
        // Default to the machine asking, which is right far more often
        // than any fixed choice.
        chosen = .macOS
    }
    guard let reply = sendControlRequest(.publicStatus(instance: instance)),
          reply.hasPrefix("OK ") else {
        print("\(instance) isn't published yet, so there is no address to connect to.")
        print("Publish it with: msl public expose \(instance)")
        exit(1)
    }
    let fields = String(reply.dropFirst(3)).components(separatedBy: "\t")
    guard fields.count >= 4, let port = UInt16(fields[1]) else {
        usbFail("msl: mslhd sent an endpoint this version doesn't understand")
    }
    let endpoint = PublicEndpoint(host: fields[0], port: port, user: fields[2],
                                  identityFile: fields[3], expires: nil,
                                  backend: fields.count > 5 ? fields[5] : "")
    print("")
    print("Connecting to \(instance) from \(chosen.title):")
    print("")
    print(ConnectionTips.instructions(for: chosen, instance: instance, endpoint: endpoint))
    print("")
    print(ConnectionTips.identitiesOnlyNote)
}

/// `msl public invite <instance> <name>` - makes somebody a key and prints
/// everything they need, ready to paste into a message.
///
/// For when email is not set up, which is most of the time: emailing needs
/// a domain, and putting it in a chat window does not.
func runPublicInvite(instance: String, label: String) {
    guard let reply = sendControlRequestMultiline(
        .publicMakeKey(instance: instance, label: label)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        usbFail(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    let privateKey = String(reply.dropFirst(3))

    guard let status = sendControlRequest(.publicStatus(instance: instance)),
          status.hasPrefix("OK ") else {
        print("Key made for \(label), but \(instance) isn't published yet.")
        print("Publish it first: msl public expose \(instance)")
        return
    }
    let fields = String(status.dropFirst(3)).components(separatedBy: "\t")
    guard fields.count >= 3, let port = UInt16(fields[1]) else {
        usbFail("msl: mslhd sent an endpoint this version doesn't understand")
    }
    let file = "msl-\(instance.lowercased())-key"

    print("")
    print("Send \(label) everything between the lines.")
    print(String(repeating: "-", count: 68))
    print("Save this as ~/Downloads/\(file), then run:")
    print("")
    print("  chmod 600 ~/Downloads/\(file)")
    print("  ssh -i ~/Downloads/\(file) -o IdentitiesOnly=yes -p \(port) \(fields[2])@\(fields[0])")
    print("")
    print(privateKey.trimmingCharacters(in: .whitespacesAndNewlines))
    print(String(repeating: "-", count: 68))
    print("")
    print("The address changes from time to time - their key does not, so they")
    print("only need this once. Send them the new command when it moves, or set")
    print("up email with: msl public notify setup")
    print("")
    print("Revoke them any time with: msl public deauthorize \(instance) \(label)")
}

/// `msl public notify ...` - who gets emailed the address.
func runPublicNotify(_ args: [String], defaultInstance: String) {
    let verb = args.count > 2 ? args[2] : "list"
    switch verb {
    case "setup":
        runNotifySetup(args)
    case "test":
        let to = args.count > 3 ? args[3] : ""
        guard !to.isEmpty else {
            print("msl public notify test <your-email>")
            exit(1)
        }
        runControl(.publicNotifyTest(to: to))
    case "add":
        guard args.count >= 5 else {
            print("msl public notify add <instance> <email> [name]")
            print("")
            print("They get an email with their own key and the address, and another")
            print("short one whenever the address changes.")
            exit(1)
        }
        runControl(.publicNotifyAdd(instance: args[3], email: args[4],
                                    label: args.count > 5 ? args[5...].joined(separator: " ") : args[4]))
    case "remove":
        guard args.count >= 5 else {
            print("msl public notify remove <instance> <email>")
            exit(1)
        }
        runControl(.publicNotifyRemove(instance: args[3], email: args[4]))
    case "forget":
        runControl(.publicNotifyForget)
    case "list":
        runNotifyList(instance: args.count > 3 ? args[3] : defaultInstance)
    default:
        print("msl public notify setup | add | remove | list | test | forget")
        exit(1)
    }
}

/// Walks somebody through Resend, because the two things that go wrong are
/// both invisible until a send fails.
func runNotifySetup(_ args: [String]) {
    print("")
    print("  MSL can email the address to whoever needs it, so nobody has to ask you")
    print("  for it again. It sends through Resend - free, and a minute to set up.")
    print("")
    print("  1. Make an account at resend.com")
    print("  2. Verify a domain you own at resend.com/domains")
    print("  3. Make an API key at resend.com/api-keys")
    print("")
    print("  A domain is the awkward part, and it is Resend's rule, not MSL's: their")
    print("  free sender can only email YOUR OWN address. With a domain verified you")
    print("  can email anyone. Without one, you can still set this up to email")
    print("  yourself - useful on its own, since you are the one who gets asked.")
    print("")

    // Flags first, so this can be scripted. **Prompting is only ever done
    // at a terminal**: `readLine()` on a pipe that never closes blocks
    // forever, so without the `isatty` check a setup run from a script -
    // or from anything driving `msl` programmatically - hangs with no
    // output and no way to tell why.
    func flag(_ name: String) -> String? {
        for argument in args where argument.hasPrefix("--\(name)=") {
            return String(argument.dropFirst(name.count + 3))
        }
        return nil
    }
    let interactive = isatty(STDIN_FILENO) == 1

    func ask(_ name: String, _ prompt: String, secret: Bool = false) -> String {
        if let given = flag(name) { return given.trimmingCharacters(in: .whitespaces) }
        guard interactive else { return "" }
        FileHandle.standardOutput.write("  \(prompt)".data(using: .utf8)!)
        guard let line = secret ? String(cString: getpass("")) : readLine() else { return "" }
        return line.trimmingCharacters(in: .whitespaces)
    }

    // Not echoed, and never passed as a command-line argument anywhere:
    // `ps` shows those to every process on this Mac.
    var apiKey = flag("key") ?? ""
    if apiKey.isEmpty, args.count > 3, args[3].hasPrefix("re_") { apiKey = args[3] }
    if apiKey.isEmpty { apiKey = ask("key", "Resend API key (not shown): ", secret: true) }
    guard apiKey.hasPrefix("re_") else {
        print("")
        if interactive {
            print("  msl: a Resend API key starts with re_. Make one at resend.com/api-keys")
        } else {
            print("  msl: no terminal to ask on. Pass them as flags instead:")
            print("       msl public notify setup --key=re_... --from=msl@your-domain.com")
        }
        exit(1)
    }
    var from = ask("from", "Send from (e.g. msl@your-domain.com): ")
    if from.isEmpty {
        from = "onboarding@resend.dev"
        print("  Using Resend's test sender - it can only email your own Resend address.")
    }
    let replyTo = ask("reply-to", "Reply-To, so people can answer you (optional): ")

    guard let reply = sendControlRequest(
        .publicNotifySetup(apiKey: apiKey, replyTo: replyTo, from: from)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        usbFail(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    print("")
    print("  Saved to /Users/Shared/MSL, where Linux instances cannot read it.")
    print("")
    print("  Check it works:   msl public notify test <your-email>")
    print("  Then add people:  msl public notify add <instance> <their-email>")
}

func runNotifyList(instance: String) {
    guard let reply = sendControlRequestMultiline(.publicNotifyList(instance: instance)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        print(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
        exit(1)
    }
    let lines = String(reply.dropFirst(3)).split(separator: "\n").map(String.init)
    var people: [String] = []
    for line in lines {
        let fields = line.components(separatedBy: "\t")
        if fields.first == "CONFIGURED" {
            if fields.count >= 3, fields[1] == "true" {
                print("Sending as \(fields[2]).")
            } else {
                print("Email isn't set up yet. Run: msl public notify setup")
            }
            continue
        }
        guard fields.count >= 3 else { continue }
        let waiting = fields[2] == "true" ? "" : "  (will get their key when you publish)"
        people.append("  \(fields[1]) <\(fields[0])>\(waiting)")
    }
    print("")
    if people.isEmpty {
        print("Nobody is emailed about \(instance) yet.")
        print("Add someone with: msl public notify add \(instance) <their-email>")
    } else {
        print("Emailed when \(instance)'s address changes:")
        people.forEach { print($0) }
    }
}

func printAuthorizeHelp(_ instance: String) {
    print("msl public authorize <instance> <public-key-or-file> [label]")
    print("")
    print("Lets another computer log in, using a key that computer already has.")
    print("Nothing secret travels: you copy its *public* key here.")
    print("")
    print("  On the other computer:  cat ~/.ssh/id_ed25519.pub")
    print("  (no key there yet?)     ssh-keygen -t ed25519")
    print("")
    print("  Then here:              msl public authorize \(instance) ~/laptop.pub work-laptop")
}

/// Reads a public key from a file, or takes it literally.
///
/// Both forms are accepted because both are what people have to hand: a
/// path when the file was copied across, and the text itself when it
/// arrived in a message. A *private* key is caught here rather than sent
/// to a guest - it is the single likeliest mistake, and the one worth
/// being loud about.
func readPublicKey(_ input: String) -> String? {
    var text = input
    let expanded = (input as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded),
       let contents = try? String(contentsOfFile: expanded, encoding: .utf8) {
        text = contents
    }
    if text.contains("PRIVATE KEY") {
        print("msl: that is a PRIVATE key. Never send one anywhere.")
        print("     You want the .pub file beside it - the public half.")
        return nil
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runPublicAuthorize(instance: String, keyOrFile: String, label: String) {
    guard let key = readPublicKey(keyOrFile) else { exit(1) }
    // A label defaults to the key's own comment, which is usually
    // `user@machine` - already the right name for it.
    var name = label
    if name.isEmpty {
        let fields = key.split(separator: " ").map(String.init)
        name = fields.count >= 3 ? fields[2...].joined(separator: " ") : "a computer"
    }
    guard let reply = sendControlRequest(
        .publicAuthorize(instance: instance, key: key, label: name)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        usbFail(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    print(String(reply.dropFirst(3)))
    print("")
    print("It can reach \(instance) with its own key now - from here, and over the")
    print("internet too once you run: msl public expose \(instance)")
}

func runPublicKeys(instance: String) {
    guard let reply = sendControlRequestMultiline(.publicKeys(instance: instance)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        print(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
        exit(1)
    }
    let body = String(reply.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
        print("No computers are authorized for \(instance) yet.")
        print("Add one with: msl public authorize \(instance) <their-key.pub>")
        return
    }
    print("Computers authorized for \(instance):")
    for line in body.split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        if fields.count >= 2 {
            print("  \(fields[1])")
            print("    \(fields[0])")
        } else {
            print("  \(line)")
        }
    }
}

func runPublicExpose(instance: String, backend: String) {
    print("Publishing \(instance) beyond this Mac.")
    print("Password logins are turned off first - an open port 22 is found by")
    print("automated guessing within minutes. Keys only, and a key made for this")
    print("instance alone.")
    guard let reply = sendControlRequest(.publicExpose(instance: instance, backend: backend)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        usbFail(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    }
    printEndpoint(String(reply.dropFirst(3)).components(separatedBy: "\t"))
    print("  Stop with: msl public revoke \(instance)")
}

func runPublicStatus(instance: String) {
    guard let reply = sendControlRequest(.publicStatus(instance: instance)) else {
        usbFail("msl: couldn't reach mslhd")
    }
    guard reply.hasPrefix("OK ") else {
        print("\(instance) is not published. Publish it with: msl public expose \(instance)")
        return
    }
    let body = String(reply.dropFirst(3))
    if body.hasPrefix("PENDING") {
        print("\(instance) is published, but the tunnel is not up at the moment -")
        print("either it is still starting or the instance is down.")
        return
    }
    printEndpoint(body.components(separatedBy: "\t"))
}

func usageAndExit() -> Never {
    FileHandle.standardError.write(CLIHelp.render(width: CLIHelp.terminalWidth(STDERR_FILENO),
                                                  styled: isatty(STDERR_FILENO) != 0).data(using: .utf8)!)
    exit(1)
}

/// Waits for a hibernated instance to come back, then reattaches to the
/// same shell.
///
/// A hibernate does not kill anything in the guest: `saveMachineStateTo`
/// writes the whole RAM, so the shell, its pty and its children are all
/// still there - measured, a `sleep 9999` started before one was still
/// running after it. Only the vsock died. So the right answer is to wait
/// and pick the session back up, not to exit and let the next `msl run`
/// strand it.
///
/// Returns the new connection, or nil to end the session (the person said
/// so, or it never came back).
enum ReattachOutcome {
    /// Carry on, on this new connection.
    case reattached(Int32)
    /// The guest shut down, or the person said to stop. Not an error.
    case ended
    /// The connection went and never came back.
    case abandoned
}

/// Dials a session's own vsock port through the daemon. Nil when the session
/// is not there - which is the only reliable way to know, since a guest that
/// is powering off still reports "running" for several seconds.
func tryAttach(instance: String, port: UInt32) -> Int32? {
    guard let controlFD = bestEffortConnectToDaemon() else { return nil }
    defer { close(controlFD) }
    let request = DaemonProtocol.ControlRequest
        .attachSession(instance: instance, port: port).encode()
    _ = request.withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }
    var status: UInt8 = 0
    guard read(controlFD, &status, 1) == 1, status == DaemonProtocol.statusOK,
          let next = try? FileDescriptorPassing.receive(from: controlFD)
    else { return nil }
    // The window may have been resized while this was detached; the guest
    // applies these before replaying its scrollback.
    let (r, c) = currentWindowSize()
    writeFull(fd: next, bytes: ShellProtocol.encodeAttach(rows: r, cols: c))
    return next
}

/// Waits for a hibernated instance to come back, then reattaches to the
/// same shell.
///
/// A hibernate does not kill anything in the guest: `saveMachineStateTo`
/// writes the whole RAM, so the shell, its pty and its children are all
/// still there. Only the vsock died. So the right answer is to wait and
/// pick the session back up, not to exit and let the next `msl run` strand
/// it.
///
/// **A `poweroff` is not that**, and must not be answered with "press r to
/// resume" - that offers to undo a deliberate shutdown. Told apart by
/// *trying the attach*: a session that is still there answers, and one
/// whose guest is halting does not. Inferring it from the instance's state
/// does not work, because a guest on its way down reports "running", then
/// "paused", for several seconds after the connection drops.
func awaitReattach(instance: String, session: (id: String, port: UInt32),
                   restoring termios: termios) -> ReattachOutcome {
    let hibernated = FileManager.default.fileExists(
        atPath: MSLPaths.appSupport.appendingPathComponent("vm-\(instance).state").path)

    // Still running? Then the session either exists or it does not, and the
    // attach says which. This is also the silent path for a connection that
    // dropped for some other reason - mslhd restarting, say - where there is
    // nothing to ask anybody.
    if !hibernated, sendControlRequest(.status(instance: instance)) == "OK running",
       let next = tryAttach(instance: instance, port: session.port) {
        return .reattached(next)
    }

    guard hibernated else {
        restoreMode(termios)
        print("\n\u{1B}[2m\(instance) shut down.\u{1B}[0m")
        return .ended
    }
    guard isatty(STDIN_FILENO) != 0 else { return .abandoned }

    // The terminal goes back to normal while waiting: this is MSL talking,
    // not the guest, and raw mode would eat the keypress below.
    restoreMode(termios)
    defer { _ = setRawMode() }

    let dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    print("\n\(dim)[\(instance) is hibernated]\(reset)   r resume · q quit", terminator: "")
    fflush(stdout)

    let raw = setRawMode()
    defer { restoreMode(raw) }

    var waited = 0
    while waited < 3600 {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 500) > 0, pfd.revents & Int16(POLLIN) != 0 {
            var c: UInt8 = 0
            if read(STDIN_FILENO, &c, 1) == 1 {
                if c == UInt8(ascii: "q") || c == 3 /* ^C */ {
                    print("\r\u{1B}[K", terminator: "")
                    return .ended
                }
                if c == UInt8(ascii: "r") {
                    print("\r\u{1B}[K\(dim)resuming \(instance)…\(reset)", terminator: "")
                    fflush(stdout)
                    _ = sendControlRequest(.resume(instance: instance))
                }
            }
        }
        waited += 1

        // `.status` and nothing else: it is the one request that does not
        // register or start an instance, and anything that did would resume
        // the instance the user just hibernated.
        guard sendControlRequest(.status(instance: instance)) == "OK running" else { continue }
        guard let next = tryAttach(instance: instance, port: session.port) else {
            // Running, but the session is gone - it was shut down rather
            // than resumed.
            print("\r\u{1B}[K\(dim)\(instance)'s session ended.\(reset)")
            return .ended
        }
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
        return .reattached(next)
    }
    print("\r\u{1B}[K\(dim)\(instance) didn't come back.\(reset)")
    return .abandoned
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
        if let refusal = CLICommands.nameRefusal(answer) {
            print("    \(refusal).")
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

    // This instance's own disk. It used to be the distro's, shared with
    // every other instance of it - so this prompt had to warn that the size
    // chosen here applied to them too. Each instance now has its own clone,
    // so the question is simply about this one.
    let boot = distro.bootFiles(instance: name)
    let current = DiskStorage.policy(forImageNamed: boot.storageKey, path: boot.disk.path)
    let currentGB = (max(current.size, DiskStorage.capacity(of: boot.disk.path)) + (1 << 30) - 1) >> 30
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


// `msl <instance> --shipment` - package that instance into a file another
// MSL can install. Handled before the switch below, because by the time an
// instance name reaches it the next step is opening a shell.
if splitArguments.shipment {
    // `msl run work --shipment` names the instance in the second position,
    // the same as `msl work --shipment` does in the first.
    let named = args.first == "run" ? args.dropFirst().first : args.first
    let instance = named ?? startupInstance()
    runShipmentCreate(instance: instance,
                      output: splitArguments.output, note: splitArguments.note)
}

/// `msl <instance> --shipment` - one instance, in one file.
func runShipmentCreate(instance: String, output: String?, note: String?) -> Never {
    guard let distro = registryForLookup.distro(for: instance) else {
        FileHandle.standardError.write("msl: there's no instance called \(instance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    // A live guest's filesystem is caught mid-write, so this refuses rather
    // than shipping something that only looks fine.
    let running = (DaemonClient.send(.status(instance: instance)) ?? "").contains("running")
    let destination = URL(fileURLWithPath: output
        ?? FileManager.default.currentDirectoryPath + "/\(instance).\(Shipment.fileExtension)")
    do {
        try Shipment.create(instance: instance, distro: distro, destination: destination,
                            note: note, isRunning: running) { line in
            FileHandle.standardError.write("msl: \(line)\n".data(using: .utf8)!)
        }
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    let size = DiskStorage.allocatedSize(of: destination.path)
    print("OK shipped \(instance) to \(destination.path) (\(DiskStorage.format(size)))")
    exit(0)
}

/// `msl shipment info|install <file>`.
func runShipmentCommand(_ rest: [String]) -> Never {
    let verb = rest.first ?? "info"
    let paths = rest.dropFirst().filter { !$0.hasPrefix("-") }
    guard let path = paths.first else {
        FileHandle.standardError.write("usage: msl shipment create <instance> [file] | info <file> | install <file> [--name NAME]\n".data(using: .utf8)!)
        exit(2)
    }
    let url = URL(fileURLWithPath: path)
    switch verb {
    case "create", "make":
        // `msl shipment create <instance> [file]`
        //
        // Packing one was only possible from the app, which is the wrong
        // shape for what shipments are *for*: reproducing an environment,
        // building images, handing a machine to somebody. All of those are
        // things people script.
        let instance = path
        guard let distro = registryForLookup.distro(for: instance) else {
            FileHandle.standardError.write("msl: there's no instance called '\(instance)'\n"
                .data(using: .utf8)!)
            exit(1)
        }
        let running = DaemonClient.send(.status(instance: instance), timeout: 10)
        if running == "OK running" || running == "OK paused" {
            FileHandle.standardError.write("""
                msl: stop \(instance) first - a filesystem copied while it is running is a \
                filesystem caught mid-write, which is not a machine anybody can boot.
                  msl stop \(instance)

                """.data(using: .utf8)!)
            exit(1)
        }
        let destination = paths.count > 1
            ? URL(fileURLWithPath: (paths[1] as NSString).expandingTildeInPath)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("\(instance).\(Shipment.fileExtension)")
        var note: String?
        for argument in rest where argument.hasPrefix("--note=") {
            note = String(argument.dropFirst("--note=".count))
        }
        do {
            try Shipment.create(instance: instance, distro: distro, destination: destination,
                                note: note, progress: { print("  \($0)") })
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                        as? NSNumber)??.uint64Value ?? 0
            print("")
            print("\(destination.lastPathComponent) - \(DiskStorage.format(size))")
            print("Anyone with MSL can open it: msl shipment install \(destination.lastPathComponent)")
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)

    case "info":
        do {
            let manifest = try Shipment.info(at: url)
            let formatter = ISO8601DateFormatter()
            print("\(manifest.source.instance) (\(manifest.source.distro))")
            print("  made by     \(manifest.mslVersion) on \(formatter.string(from: manifest.created))")
            if let host = manifest.host {
                print("  made on     \(host.architecture)\(host.macOS.map { ", " + $0 } ?? "")")
            }
            if let id = manifest.id { print("  id          \(id)") }
            // Where this environment is descended from. The whole point of
            // shipments is passing a machine along, so knowing it came from
            // another one is worth a line.
            if let parent = manifest.parent { print("  came from   \(parent)") }
            print("  filesystem  \(DiskStorage.format(manifest.disk.uncompressedSize)) uncompressed")
            if let user = manifest.defaultUser { print("  account     \(user)") }
            if let sandbox = manifest.sandbox, !sandbox.isOpen {
                print("  sandbox     \(sandbox.closedGateCount) gate(s) closed")
            }
            if let apps = manifest.apps, !apps.isEmpty {
                print("  apps        \(apps.prefix(6).joined(separator: ", "))\(apps.count > 6 ? ", …" : "")")
            }
            if let note = manifest.note { print("  note        \(note)") }
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    case "install":
        var name: String?
        if let index = rest.firstIndex(of: "--name"), index + 1 < rest.count { name = rest[index + 1] }
        do {
            let manifest = try Shipment.info(at: url)
            let chosen = name ?? manifest.source.instance
            guard InstanceRegistry.isValidName(chosen) else {
                FileHandle.standardError.write("msl: '\(chosen)' isn't a usable instance name\n".data(using: .utf8)!)
                exit(1)
            }
            let outcomes = try Shipment.install(url, as: chosen,
                                                existingInstances: registryForLookup.entries()) { line in
                FileHandle.standardError.write("msl: \(line)\n".data(using: .utf8)!)
            }
            guard let distro = GuestDistro(rawValue: manifest.source.distro) else {
                FileHandle.standardError.write("msl: unknown distro '\(manifest.source.distro)'\n".data(using: .utf8)!)
                exit(1)
            }
            _ = DaemonClient.send(.createInstance(instance: chosen, distro: distro))
            print("OK installed \(chosen) from \(url.lastPathComponent)")
            // Best effort, said out loud: a setting that could not be
            // honoured here is worth one line, not silence.
            let applied = outcomes.compactMap { if case .applied(let k) = $0 { return k } else { return nil } }
            let skipped = outcomes.compactMap { o -> String? in
                if case .skipped(let k, let why) = o { return "\(k) (\(why))" } else { return nil }
            }
            if !applied.isEmpty { print("   settings kept for this instance: \(applied.joined(separator: ", "))") }
            for line in skipped { print("   not applied: \(line)") }
            print("run `msl \(chosen)` to start it")
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    default:
        FileHandle.standardError.write("msl: unknown shipment command '\(verb)'\n".data(using: .utf8)!)
        exit(2)
    }
    exit(0)
}

switch args.first {
case "shipment":
    runShipmentCommand(Array(args.dropFirst()))

case nil:
    // Orientation, not a shell - see `CLIOverview`. `msl run` is the shell
    // this used to open, and says so in the list it prints.
    printOverview()
    exit(0)

case "run":
    // `msl run <instance> [command...]`, the spelled-out form of
    // `msl <instance> [command...]`. A verbatim-tail command (see
    // `CLICommands.verbatimTail`), so everything after the instance name
    // reaches the guest with its own flags intact.
    //
    // An instance that is literally called `run` wins: the old CLI dropped
    // the word `run` entirely, so plain `msl run` registered an instance by
    // that name, and anyone who hit that must still be able to reach it.
    let runTarget: String
    if args.count > 1 {
        runTarget = args[1]
        // Only a name the user typed is checked. A name that came from
        // `startupInstance()` is MSL's own pick and may legitimately not
        // exist yet - on a first-ever run it is `default`, and
        // `requireInstalled` is what greets an empty Mac properly.
        if let refusal = openableRefusal(runTarget) {
            FileHandle.standardError.write("msl: \(refusal)\n".data(using: .utf8)!)
            exit(1)
        }
    } else if registryForLookup.distro(for: "run") != nil {
        runTarget = "run"
    } else {
        runTarget = startupInstance()
    }
    let runDistro = effectiveDistro(forInstance: runTarget)
    let runCommand = args.dropFirst(2).joined(separator: " ")
    let runUser = resolveUser(instance: runTarget, distro: runDistro, command: runCommand)
    runShellSession(instance: runTarget, distro: runDistro, command: runCommand, user: runUser)

case "update":
    // OIS's `myapp --update`, with MSL's own shape: the check is
    // `UpdateCheck` (unchanged), the download is `UpdateDownload`, and the
    // removal is `msl uninstall` run from a script that outlives this
    // process (`UpdateHandoff`).
    //
    // Three levels, because they have three different consequences:
    //   msl update              say what there is
    //   msl update --download   fetch and verify it into Downloads
    //   msl update --install    ...and then replace this MSL
    //
    // Nothing destructive happens without the word being typed. An update
    // that removes MSL because somebody ran `msl update` to *look* is not a
    // feature.
    var updateWants = UpdateAction.check
    for option in args.dropFirst() {
        switch option {
        case "--download", "-d", "--yes", "-y": updateWants = .download
        case "--check", "-n": updateWants = .check
        default:
            FileHandle.standardError.write("msl: unknown option '\(option)' - usage: msl update [--download]\n".data(using: .utf8)!)
            exit(2)
        }
    }
    runUpdate(updateWants)

case "version", "--version", "-v":
    // `msl about` used to be read as an instance name and quietly downloaded
    // Alpine to make one. The word people reach for needs to exist.
    print(MSLVersion.display)
    exit(0)

case "distros":
    printDistroTable()
    exit(0)

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
    // Every source in turn, which is what the app does too - so a download
    // that works in one does not mysteriously fail in the other. An explicit
    // --manifest narrows this to exactly that one.
    let sources: [DistroInstaller.ImageSource]
    do {
        sources = try DistroInstaller.resolveSources(override: manifestURLOverride)
    } catch {
        FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    let appSupport = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MSL")
    do {
        // `--force` re-fetches a base that is already here, for one that is
        // damaged rather than out of date.
        try DistroInstaller.install(distro: distroToInstall, sources: sources, appSupportDir: appSupport,
                                    force: args.contains("--force")) { message in
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
    // As the user, never root. A tunnel started as root leaves a root-owned
    // socket in the sticky `/tmp/.X11-unix`, which the user then cannot
    // replace - every later launch dies with "bind: Address already in
    // use", and the only cure is a root cleanup. Starting it as the account
    // that will use it avoids the whole situation.
    let (startExit, _) = runOneShotCommand(
        instance: guiInstance, distro: guiDistro,
        command: GuestIntegration.tunnelStartCommand(display: 0, port: 5002, announce: false),
        user: GuestUser.shellUser(instance: guiInstance, distro: guiDistro), echo: false
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
    // As the user - see `gui` above for what a root-owned display socket
    // costs.
    let (nativeStartExit, _) = runOneShotCommand(
        instance: nativeInstance, distro: nativeDistro,
        command: GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true),
        user: GuestUser.shellUser(instance: nativeInstance, distro: nativeDistro), echo: false
    )
    guard nativeStartExit == 0 else {
        FileHandle.standardError.write("msl: failed to start x11tunnel in \(nativeInstance)\n".data(using: .utf8)!)
        exit(1)
    }

    if nativeAppArgs.isEmpty {
        print("msl: native GUI ready for \(nativeInstance) - launch an X app with `msl gui-native \(nativeInstance) <app>` or `msl \(nativeInstance) -- 'DISPLAY=:1 <app>'`")
        exit(0)
    }
    // The same command an app launched from the Applications tab gets, not
    // a bare `DISPLAY=:1 <app>`: this verb is how MSL's own GUI work gets
    // tested, and a test path that skips the menu bridge, the portal, the
    // user scope and the extended PATH proves nothing about the path people
    // actually use (found 2026-09-22, after testing Krita's menus through a
    // launch that could never have had any).
    let nativeCommand = GuestIntegration.launchCommand(
        nativeAppArgs.joined(separator: " "), instance: nativeInstance,
        settings: MSLExperimentalSettingsStore.load())
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
    let sshUser = LinuxUserSetup.defaultUser(forInstance: sshInstance) ?? "msl"
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
case "admin":
    // MSLAP. Phase 1 is read-only on purpose: the catalogue and the
    // resolution are worth having before anything can refuse a request,
    // because they are how the refusals get tested. `status` is also the
    // honest answer to "what is this machine actually locked down to",
    // which an administrator needs before trusting it with anything.
    let adminSub = args.count > 1 ? args[1].lowercased() : "status"
    switch adminSub {
    case "status":
        let instanceFilter = args.count > 2 ? args[2] : nil
        printAdminStatus(instance: instanceFilter)
    case "capabilities", "caps":
        for group in MSLAPCapability.groups {
            print(group)
            for entry in MSLAPCapability.catalogue
            where entry.capability.key.hasPrefix(group + ".") {
                let mark = entry.enforced ? " "
                    : entry.unavailable ? " (no such action in this version)"
                    : " (not yet enforced)"
                print("  \(entry.capability.key.padding(toLength: 34, withPad: " ", startingAt: 0))"
                      + "\(entry.tier.label)\(mark)")
            }
        }
    case "keygen":
        // Local admin mode. Weaker than a fleet key and the output says so.
        do {
            let id = try MSLAPKeyStore.createLocalKey()
            print("Created a local signing key and pinned it: \(id)")
            print("  Private key: \(MSLAPKeyStore.directory.path)/mslap-local-key (0600)")
            print("")
            print("  This is LOCAL ADMIN mode. The signing key lives on this Mac, so")
            print("  anyone with root here can re-sign a policy. It still stops the")
            print("  policy being edited casually, which is the point for one person")
            print("  locking down their own Mac. A fleet deployment keeps its private")
            print("  key on another machine and uses `msl admin pin` instead.")
        } catch {
            print("msl admin keygen: \(error)")
            exit(1)
        }

    case "certify", "revoke":
        // An administrator's signed statement about a lineage.
        //
        // **The strong tier, and the only one a local user cannot forge.**
        // Instance identities are signed by a key mslhd can read, so they
        // are tamper-evident. A certificate is signed by the MSLAP key -
        // which a fleet keeps OFF the machine - so nobody holding only
        // this Mac can mint one. See READMES/31 §1.2.
        let certifyRevoking = args[1].lowercased() == "revoke"
        let certifyArgs = Array(args.dropFirst(2))
        func certifyFlag(_ name: String) -> String? {
            for (index, value) in certifyArgs.enumerated() where value == "--\(name)" {
                return index + 1 < certifyArgs.count ? certifyArgs[index + 1] : nil
            }
            for value in certifyArgs where value.hasPrefix("--\(name)=") {
                return String(value.dropFirst(name.count + 3))
            }
            return nil
        }
        let certifyPositional = certifyArgs.filter { !$0.hasPrefix("-") }

        // A lineage, or an instance name - whichever the person has to
        // hand. Looking it up is friendlier than making them paste 26
        // characters of base32 they would have to find first.
        var certifyLineage = certifyPositional.first
        if let given = certifyLineage, given.count != InstanceIdentity.lineageLength {
            guard case .valid(let identity) = InstanceIdentityStore.verdict(for: given) else {
                FileHandle.standardError.write(
                    "msl: '\(given)' is neither a lineage nor an instance with a verified identity\n"
                        .data(using: .utf8)!)
                exit(1)
            }
            certifyLineage = identity.lineage
            print("\(given)'s lineage is \(identity.lineage).")
        }
        guard let certifyLineage else {
            print("usage: msl admin \(certifyRevoking ? "revoke" : "certify") <lineage|instance> "
                  + "[--label \"Acme Image 2026\"]" + (certifyRevoking ? " [--reason \"...\"]" : ""))
            print("")
            print("  Writes a signed statement that this image is yours (or withdrawn).")
            print("  Signed with this Mac's admin key. A FLEET signs on the machine that")
            print("  holds the key and copies the file to /Library/Application Support/MSL/")
            print("  lineages/, where a non-administrator cannot add or remove one.")
            exit(certifyPositional.isEmpty ? 2 : 1)
        }
        guard let certifyKey = MSLAPKeyStore.localPrivateKey() else {
            let why = "msl: there is no admin signing key on this Mac. `msl admin keygen` makes "
                    + "one, or sign on the machine that holds your fleet key and copy the file here.\n"
            FileHandle.standardError.write(why.data(using: .utf8)!)
            exit(1)
        }
        do {
            let certificate = try LineageCertificate(
                lineage: certifyLineage,
                trust: certifyRevoking ? .revoked : .certified,
                label: certifyFlag("label") ?? (certifyRevoking ? "a withdrawn image" : "an administrator's image"),
                issuer: MSLAPPolicyStore.current()?.issuer ?? "this Mac's administrator",
                reason: certifyFlag("reason")).signed(with: certifyKey)
            let written = try LineageCertificateStore.install(certificate)
            print("OK \(certifyRevoking ? "revoked" : "certified") lineage \(certifyLineage)")
            print("   \(written.path)")
            if certifyRevoking {
                print("")
                print("   Every instance of this lineage will now refuse to start, and no")
                print("   capability can set that aside - a revocation that a policy could")
                print("   override would be no revocation at all.")
                print("")
                print("   How strongly it is held depends on where this file is and who owns")
                print("   the signing key - `msl admin status` says which. Signed here with a")
                print("   key on this Mac, anyone with administrator access could re-sign it.")
            } else {
                print("")
                print("   For a fleet, copy this file to each Mac at")
                print("   /Library/Application Support/MSL/lineages/ (needs sudo), where a")
                print("   non-administrator cannot add or remove one.")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

    case "pin":
        // Fleet mode: trust a public key whose private half is elsewhere.
        guard args.count > 2 else {
            print("usage: msl admin pin <base64-public-key>")
            exit(1)
        }
        do {
            let key = try MSLAPSigning.publicKey(fromBase64: args[2])
            let id = try MSLAPKeyStore.pin(key)
            print("Pinned signing key \(id). Policies signed by it will be honoured.")
        } catch {
            print("msl admin pin: \(error)")
            exit(1)
        }

    case "keys":
        let pinned = MSLAPKeyStore.pinned()
        if pinned.isEmpty {
            print("No signing keys are pinned. Any policy will load unsigned, at Advisory strength.")
        } else {
            for (id, key) in pinned.sorted(by: { $0.key < $1.key }) {
                print("\(id)  \(key.rawRepresentation.base64EncodedString())")
            }
            if MSLAPKeyStore.isLocalAdminMode {
                print("")
                print("Local admin mode: the private key for one of these is on this Mac.")
            }
        }

    case "sign":
        guard args.count > 2 else {
            print("usage: msl admin sign <policy.json> [--key <base64-private-key>]")
            print("  With no --key, uses this Mac's local admin key (msl admin keygen).")
            exit(1)
        }
        do {
            let path = args[2]
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let policy = try decoder.decode(MSLAPPolicy.self, from: data)
            let key: Curve25519.Signing.PrivateKey
            if let index = args.firstIndex(of: "--key"), args.count > index + 1 {
                key = try MSLAPSigning.privateKey(fromBase64: args[index + 1])
            } else if let local = MSLAPKeyStore.localPrivateKey() {
                key = local
            } else {
                print("msl admin sign: no key. Run `msl admin keygen`, or pass --key.")
                exit(1)
            }
            let signed = try MSLAPSigning.sign(policy, with: key)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(signed).write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Signed \(path) with key \(signed.signature?.key ?? "?").")
        } catch {
            print("msl admin sign: \(error)")
            exit(1)
        }

    case "enrol", "enroll", "install":
        // Puts the policy where the person using this Mac cannot write it.
        // That single step is the difference between advisory and
        // enforceable, so it is a deliberate command with its own sudo
        // prompt rather than something that happens quietly.
        guard args.count > 2 else {
            print("usage: msl admin enrol <policy.json>")
            print("  Installs to \(MSLAPPolicyStore.systemURL.path) (needs sudo).")
            exit(1)
        }
        do {
            let source = URL(fileURLWithPath: args[2])
            let data = try Data(contentsOf: source)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let policy = try decoder.decode(MSLAPPolicy.self, from: data)

            // What this will change, before changing it. A wall of JSON is
            // not review; a list of what stops working is.
            let denied = MSLAPCapability.catalogue.filter { !policy.allows($0.capability) }
            print("This policy denies \(denied.count) capabilit\(denied.count == 1 ? "y" : "ies"):")
            for entry in denied.prefix(12) { print("  \(entry.capability.key)  \(entry.title)") }
            if denied.count > 12 { print("  ... and \(denied.count - 12) more") }
            let unknown = policy.unknownCapabilities
            if !unknown.isEmpty {
                print("Ignoring \(unknown.count) name(s) this MSL does not know: "
                      + unknown.map(\.key).joined(separator: ", "))
            }
            switch MSLAPSigning.verify(policy, pinned: MSLAPKeyStore.pinned()) {
            case .success(let id): print("Signature: valid, key \(id)")
            case .failure(let problem): print("Signature: \(problem.detail)")
            }

            let target = MSLAPPolicyStore.systemURL
            print("")
            print("Installing to \(target.path) - this needs your Mac password.")
            let script = "mkdir -p '\(target.deletingLastPathComponent().path)' && "
                       + "cp '\(source.path)' '\(target.path)' && "
                       + "chown root:wheel '\(target.path)' && "
                       + "chmod 644 '\(target.path)'"
            let sudo = Process()
            sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            sudo.arguments = ["/bin/sh", "-c", script]
            try sudo.run()
            sudo.waitUntilExit()
            guard sudo.terminationStatus == 0 else {
                print("msl admin enrol: install failed (sudo exited \(sudo.terminationStatus))")
                exit(1)
            }
            print("")
            printAdminStatus(instance: nil)
        } catch {
            print("msl admin enrol: \(error)")
            exit(1)
        }

    case "unenrol", "unenroll":
        // A policy can forbid its own removal. That sounds circular and is
        // not: it is the difference between a deployment an administrator
        // sets up for someone and one that someone can simply walk out of.
        // It binds this account, not root - `sudo rm` still works, and
        // saying so is better than implying otherwise.
        if !MSLAPGate.allows("admin.unenrol", instance: nil) {
            print("msl admin unenrol: "
                  + (MSLAPGate.reason("admin.unenrol", instance: nil)
                     ?? "Not allowed by the MSL Admin Portal"))
            print("  An administrator with sudo can still remove the file directly.")
            exit(1)
        }
        // Removing management is itself an administrative act, and it has
        // to remove the FALLBACK too or the last good policy keeps
        // applying - which would look like MSL ignoring the admin.
        let target = MSLAPPolicyStore.systemURL
        print("Removing \(target.path) and the remembered fallback - this needs your Mac password.")
        let script = "rm -f '\(target.path)' '\(MSLAPPolicyStore.lastGoodURL.path)'"
        let sudo = Process()
        sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudo.arguments = ["/bin/sh", "-c", script]
        try? sudo.run()
        sudo.waitUntilExit()
        try? FileManager.default.removeItem(at: MSLAPPolicyStore.userURL)
        print("")
        printAdminStatus(instance: nil)

    default:
        print("msl admin: unknown subcommand '\(adminSub)'")
        print("  status [instance]    what this Mac is locked down to")
        print("  capabilities         everything a policy can deny")
        print("  keygen               create a local signing key (local admin mode)")
        print("  pin <pubkey>         trust a fleet signing key")
        print("  keys                 list pinned signing keys")
        print("  sign <policy.json>   sign a policy in place")
        print("  enrol <policy.json>  install system-wide (sudo) - makes it enforceable")
        print("  unenrol              remove the policy and its fallback (sudo)")
        exit(1)
    }
    exit(0)

case "doctor":
    if !MSLAPGate.allows("system.doctor", instance: nil) {
        print("msl doctor: " + (MSLAPGate.reason("system.doctor", instance: nil)
                                ?? "Not allowed by the MSL Admin Portal"))
        exit(1)
    }
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
        daemonRunning: DaemonClient.isRunning(),
        // `MSLAPGate.policy`, not `MSLAPPolicyStore.current()`: the gate
        // includes the tamper fallback, so a policy somebody edited is
        // still checked against the last one that verified rather than
        // reported as no policy at all.
        policy: MSLAPGate.policy)
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
    // `msl list` is your instances; `msl list online` is what you could
    // install. WSL spells the second one `--list --online`, so both the bare
    // word and the flag are accepted - nobody should have to remember which.
    switch args.count > 1 ? args[1] : "" {
    case "":
        runControl(.instanceList)
    case "online", "--online", "available", "distros", "--distros":
        printDistroTable()
        exit(0)
    case "installed", "--installed":
        let rows = DistroListing.rows(catalog: nil,
                                      instanceCounts: instanceCountsByDistro(),
                                      isInstalled: { DistroInstallation.isInstalled($0) })
            .filter(\.isInstalled)
        guard !rows.isEmpty else {
            print("No distro images downloaded yet - msl list online shows what there is.")
            exit(0)
        }
        print("Downloaded distros:")
        print(DistroListing.table(rows), terminator: "")
        exit(0)
    case let unknown:
        FileHandle.standardError.write("""
        msl: `msl list \(unknown)` isn't a thing. Try:
             msl list              your instances
             msl list online       every distro you can install
             msl list installed    the distro images already downloaded

        """.data(using: .utf8)!)
        exit(1)
    }

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
        print("next: msl run \(created)")
        exit(0)
    }
    guard newPositional.count == 1 else {
        FileHandle.standardError.write("usage: msl new <name> [--distro <distro>] \(InstanceSetupOptions.usage)\n".data(using: .utf8)!)
        exit(1)
    }
    let newName = newPositional[0]
    // Before the daemon is asked, so a refused name costs nothing and the
    // message is the same one the interactive prompt gives.
    if let refusal = CLICommands.nameRefusal(newName) {
        FileHandle.standardError.write("msl: \(refusal)\n".data(using: .utf8)!)
        exit(1)
    }
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
        print("next: msl install \(newDistro.rawValue), then msl run \(newName)")
    } else {
        print("next: msl run \(newName)")
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

case "vault":
    // Administrator-held container keys. `READMES/32` §4.1.
    let vaultArgs = Array(args.dropFirst())
    let vaultAction = (vaultArgs.first { ["unlock", "lock", "adopt", "status"].contains($0) }
                       ?? "status")
    let vaultNames = vaultArgs.filter {
        !$0.hasPrefix("-") && !["unlock", "lock", "adopt", "status"].contains($0)
    }
    guard let vaultInstance = vaultNames.first else {
        print("usage: msl vault <instance> [status|unlock|lock|adopt]")
        print("")
        print("  status   whether its disk is in a container, and whose key opens it")
        print("  adopt    move the container to a passphrase YOU hold - after this,")
        print("           nothing on this Mac can open it until somebody types it,")
        print("           and there is no recovery if it is lost")
        print("  unlock   supply that passphrase for this session")
        print("  lock     forget it again and close the container")
        exit(vaultNames.isEmpty && vaultArgs.isEmpty ? 2 : 1)
    }
    guard registryForLookup.distro(for: vaultInstance) != nil else {
        FileHandle.standardError.write("msl: there's no instance called \(vaultInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }

    if vaultAction == "status" {
        guard case .valid(let vaultIdentity) = InstanceIdentityStore.verdict(for: vaultInstance) else {
            print("\(vaultInstance): no verified identity, so MSL cannot tell which container is its.")
            exit(0)
        }
        guard InstanceVault.exists(serial: vaultIdentity.serial) else {
            print("\(vaultInstance): its disk is a plain file.")
            print("      `msl protect \(vaultInstance)` moves it into an encrypted container.")
            exit(0)
        }
        // Asked of the daemon: the unwrapped key lives in ITS memory, so
        // this process's own table is always empty and would report every
        // admin-held container as locked.
        let vaultReply = sendControlRequestMultiline(
            .vaultKey(instance: vaultInstance, action: "status", passphrase: ""))
        // **No silent default.** An older daemon, or one that cannot
        // answer, must not be reported as "opened by this Mac's own key" -
        // that is the weaker rung, and claiming it for a container that is
        // actually admin-held would be exactly the wrong way to be wrong.
        guard vaultReply?.hasPrefix("OK") == true,
              case let vaultFields = String(vaultReply!.dropFirst(2))
                  .trimmingCharacters(in: .whitespaces).components(separatedBy: "\t"),
              let vaultMode = VaultKeyMode(rawValue: vaultFields.first ?? "") else {
            print("\(vaultInstance): its disk is in a container, but mslhd could not say whose key")
            print("      opens it. Restart it (`launchctl kickstart -k gui/$UID/com.msl.mslhd`)")
            print("      and try again - an older daemon does not know how to answer.")
            exit(1)
        }
        let vaultOpen = vaultFields.count > 1 && vaultFields[1] == "1"
        switch vaultMode {
        case .machine:
            print("\(vaultInstance): in an encrypted container, opened by this Mac's own key.")
            print("      A copy of the file is useless elsewhere. Someone with administrator")
            print("      access HERE could still reach the key - `msl vault \(vaultInstance) adopt`")
            print("      moves it to a passphrase you hold instead.")
        case .adminHeld:
            print("\(vaultInstance): in an encrypted container, opened by a passphrase you hold.")
            print("      \(vaultOpen ? "Unlocked - it can start until mslhd restarts." : "LOCKED - it will not start until unlocked.")")
            print("      The key is never written down, so a reboot asks again.")
        }
        exit(0)
    }

    // A passphrase is read from the terminal, never taken as an argument:
    // an argument list is world-readable through `ps`.
    var vaultPassphrase = ""
    if vaultAction != "lock" {
        guard isatty(STDIN_FILENO) == 1 else {
            FileHandle.standardError.write(
                "msl: run this at a terminal - the passphrase is typed, never passed as an argument\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        if vaultAction == "adopt" {
            print("Moving \(vaultInstance)'s container to a passphrase you hold.")
            print("")
            print("  After this, NOTHING on this Mac can open it until somebody types that")
            print("  passphrase - including MSL after a reboot. **There is no recovery if it")
            print("  is lost: the disk becomes unreadable permanently.**")
            print("")
        }
        guard let typed = String(validatingCString: getpass("Passphrase: ")), !typed.isEmpty else {
            FileHandle.standardError.write("msl: no passphrase given\n".data(using: .utf8)!)
            exit(1)
        }
        if vaultAction == "adopt" {
            guard let again = String(validatingCString: getpass("Again: ")), again == typed else {
                FileHandle.standardError.write("msl: the two did not match\n".data(using: .utf8)!)
                exit(1)
            }
        }
        vaultPassphrase = typed
    }
    runControl(.vaultKey(instance: vaultInstance, action: vaultAction,
                         passphrase: vaultPassphrase))

case "protect", "unprotect":
    // Moves an instance's disk into an encrypted container, or back out.
    //
    // A real copy of the whole disk - `clonefile` cannot cross into a
    // container - so the size is said BEFORE anything starts rather than
    // discovered as a long silence.
    let protectVerb = args.first ?? "protect"
    let protectNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    guard protectNames.count == 1 else {
        FileHandle.standardError.write("usage: msl \(protectVerb) <instance>\n".data(using: .utf8)!)
        exit(2)
    }
    let protectName = protectNames[0]
    guard registryForLookup.distro(for: protectName) != nil else {
        FileHandle.standardError.write("msl: there's no instance called \(protectName) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    let protectDiskPath = InstanceDisk.url(instance: protectName).path
    let protectSize = DiskStorage.allocatedSize(of: protectDiskPath)
    if protectVerb == "protect" {
        print("Moving \(protectName)'s disk into an encrypted container.")
        print("")
        print("  This is a real copy of \(DiskStorage.format(protectSize)) - MSL's instant")
        print("  clone trick cannot cross into a container - so it takes a few minutes and")
        print("  needs that much free space while it runs. The original is removed only")
        print("  after the copy inside has been read back and checked, so there is no")
        print("  moment where both are gone.")
        print("")
        print("  What it buys: a copy of the file is useless without this Mac. What it does")
        print("  NOT buy: anything inside the instance is still readable to anyone who can")
        print("  open a shell in it.")
    } else {
        print("Moving \(protectName)'s disk back out of its container, as a plain file.")
        print("  \(DiskStorage.format(protectSize)) to copy. After this, a copy of the file")
        print("  is readable by anyone who has it.")
    }
    print("")
    print("Progress is in ~/Library/Logs/MSL/mslhd.log - this command waits.")
    runControlWithTimeout(.protectInstance(instance: protectName,
                                           enable: protectVerb == "protect"),
                          timeout: 3600)

case "identity":
    // **Report before enforce.** Nothing refuses anything on an identity
    // yet, deliberately: this touches the boot path of every instance on
    // every Mac, and a week of a read-only verdict is the only way to find
    // out what real machines say before a refusal can strand anybody.
    // See READMES/31-INSTANCE-IDENTITY.md step 3.
    let identityNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    let identityAccepted = InstanceIdentityKey.accepted()
    let identityAll = InstanceIdentityStore.all(accepting: identityAccepted)
    let identityDuplicates = InstanceIdentityStore.duplicateSerials(accepting: identityAccepted)

    func printIdentity(_ name: String) {
        let verdict = InstanceIdentityStore.verdict(for: name, accepting: identityAccepted)
        switch verdict {
        case .unidentified:
            print("\(name): no identity recorded")
            print("      Made before MSL issued them, or issued on another Mac. Nothing refuses it.")
        case .invalid(let why):
            print("\(name): identity does NOT verify")
            print("      \(why)")
            print("      Somebody edited it, or it was signed by a key this Mac does not accept.")
        case .valid(let identity):
            let what = identity.isClone
                ? "copy \(identity.generation) of its lineage"
                : "an original"
            print("\(name): \(what)")
            print("      lineage   \(identity.lineage)")
            print("      copies    \(identity.depth) (\(identity.generation))")
            print("      born as   \(identity.origin) on machine \(identity.machine)")
            print("      signed by \(identity.issuer)")
            // The administrator's statement about this lineage, if any.
            // Printed with its strength, because a certificate in the
            // user-writable location is a different thing from one a
            // non-administrator cannot touch.
            switch LineageCertificateStore.verdict(for: identity.lineage) {
            case .none:
                break
            case .certified(let label, let certIssuer, let rootOwned):
                print("      certified as \"\(label)\"" + (certIssuer.map { " by \($0)" } ?? ""))
                print("      " + (rootOwned
                    ? "the certificate is root-owned, so a non-administrator cannot change it"
                    : "the certificate is user-writable - advisory only on this Mac"))
            case .revoked(let label, let reason):
                print("      WITHDRAWN: \"\(label)\" has been revoked by its administrator"
                      + (reason.map { " - \($0)" } ?? ""))
                print("      This instance will not start.")
            case .invalid(let why):
                print("      its lineage certificate does NOT verify: \(why)")
            }
            if identity.origin != name {
                // Worth saying out loud: the name it answers to now is not
                // the name a policy scope written at birth would match, and
                // `origin` is the signed field that closes that.
                print("      renamed since (scopes match '\(identity.origin)' too)")
            }
            if let clash = identityDuplicates[identity.serial] {
                print("      ALSO CLAIMED BY \(clash.filter { $0 != name }.joined(separator: ", "))")
                print("      Two instances cannot be the same instance - one of them is a copy.")
            }
        }
    }

    // The way back from a marker that went missing innocently - a disk
    // cleanup, an /etc restore, somebody tidying. MSL will not do this on
    // its own, because rewriting a marker stamps an instance's identity
    // onto whatever disk is actually there; asking for it explicitly is
    // the point.
    if args.dropFirst().contains("--rewrite-marker") {
        guard let one = identityNames.first else {
            FileHandle.standardError.write("usage: msl identity <instance> --rewrite-marker\n".data(using: .utf8)!)
            exit(2)
        }
        print("This tells MSL that \(one)'s disk really is the one it recorded.")
        print("Only do it if you know that is true - if the disk was replaced, this makes")
        print("MSL stop noticing.")
        runControl(.rewriteIdentityMarker(instance: one))
    }

    if let one = identityNames.first {
        guard registryForLookup.distro(for: one) != nil else {
            FileHandle.standardError.write("msl: there's no instance called \(one) - `msl list` shows them\n".data(using: .utf8)!)
            exit(1)
        }
        printIdentity(one)
        exit(0)
    }

    let known = registryForLookup.list()
    guard !known.isEmpty else {
        print("No instances registered.")
        exit(0)
    }
    for name in known { printIdentity(name) }

    // Whether the one-shot pass has run, because it is what decides
    // whether an instance with no identity gets given one - and somebody
    // reading this list deserves to know which regime they are in.
    print("")
    if let record = InstanceIdentityMigration.record() {
        print("Tracking provenance since \(record.completed.formatted(date: .abbreviated, time: .shortened)).")
        if MSLAPGate.policy != nil {
            print("      This Mac is managed, so an instance that turns up without an identity")
            print("      from now on is NOT given one - it appeared after tracking started.")
        } else {
            print("      This Mac is not managed, so an instance without an identity is given one.")
        }
    } else {
        print("Provenance tracking has not started yet - it begins the next time mslhd starts.")
    }
    // State left by an instance that no longer exists - the same class of
    // finding `msl doctor` already reports for app lists and disks.
    let orphanIdentities = identityAll.keys.filter { !known.contains($0) }.sorted()
    if !orphanIdentities.isEmpty {
        print("")
        print("Identities left by removed instances: \(orphanIdentities.joined(separator: ", "))")
        print("      `msl doctor` can clear them.")
    }
    exit(0)

case "forward", "unforward":
    let forwardVerb = args.first ?? "forward"
    let forwardArgs = Array(args.dropFirst())
    let viaSSH = forwardArgs.contains("--ssh")
    let forwardPositional = forwardArgs.filter { !$0.hasPrefix("-") }

    if forwardVerb == "unforward" {
        // Just a port: a host port is unique across this Mac, so naming
        // the instance as well would be noise the user could get wrong.
        guard forwardPositional.count == 1, let port = UInt16(forwardPositional[0]), port > 0 else {
            FileHandle.standardError.write("usage: msl unforward <port on this Mac>\n".data(using: .utf8)!)
            exit(2)
        }
        runControl(.forwardRemove(hostPort: port))
    }

    let forwardInstance = forwardPositional.first ?? startupInstance()
    guard registryForLookup.distro(for: forwardInstance) != nil else {
        FileHandle.standardError.write("msl: there's no instance called \(forwardInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    let forwardPair = forwardPositional.dropFirst().first

    guard let forwardPair, forwardPair != "list" else {
        // No pair, or an explicit `list`: show what is forwarded. Live is
        // reported separately from recorded, because a forward whose
        // listener died is the "looks fine and is not" state and a list
        // that could not tell them apart would be what hides it.
        guard let reply = sendControlRequestMultiline(.forwardList(instance: forwardInstance)) else {
            FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
            exit(1)
        }
        guard reply.hasPrefix("OK") else {
            print(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
            exit(1)
        }
        // Each field trimmed: the reply is `OK <body>`, so dropping two
        // characters leaves the separating space on the first line only -
        // which printed as `localhost: 8080` for the first forward and
        // `localhost:8081` for every other one.
        let rows = String(reply.dropFirst(2)).split(separator: "\n")
            .map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.count >= 4 }
        guard !rows.isEmpty else {
            print("Nothing is forwarded for \(forwardInstance).")
            print("\nForward one: msl forward \(forwardInstance) 8080:3000")
            exit(0)
        }
        print("Forwarded for \(forwardInstance):")
        for row in rows {
            let route = row[2] == "viaSSH" ? " through SSH" : ""
            let live = row[3] == "1" ? "" : "  (not running - starts with the instance)"
            print("  localhost:\(row[0])  ->  \(forwardInstance):\(row[1])\(route)\(live)")
        }
        exit(0)
    }

    guard let ports = PortForward.parsePair(forwardPair) else {
        FileHandle.standardError.write("usage: msl forward <instance> <port on this Mac>:<port in Linux> [--ssh]\n"
            .data(using: .utf8)!)
        exit(2)
    }
    if let note = PortForward.privilegedPortNote(ports.host) {
        FileHandle.standardError.write("msl: \(note)\n".data(using: .utf8)!)
        exit(1)
    }
    // **Multiline, not `runControl`.** `runControl` reads a single line, and
    // the most useful thing this command says - that nothing is listening
    // on the guest side, and which route reaches a loopback-bound server -
    // arrives on the second. Sending it and then truncating it away was
    // worse than never writing it: the forward reported OK and the reason
    // it would not carry traffic was dropped on the floor.
    guard let reply = sendControlRequestMultiline(
        .forwardAdd(instance: forwardInstance, hostPort: ports.host,
                    guestPort: ports.guest, viaSSH: viaSSH)) else {
        FileHandle.standardError.write("msl: couldn't reach mslhd\n".data(using: .utf8)!)
        exit(1)
    }
    print(reply.replacingOccurrences(of: "ERROR ", with: "msl: "))
    exit(reply.hasPrefix("OK") ? 0 : 1)

case "rename", "clone":
    let transferVerb = args.first ?? "rename"
    let transferNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    guard transferNames.count == 2 else {
        FileHandle.standardError.write("usage: msl \(transferVerb) <instance> <new name>\n".data(using: .utf8)!)
        exit(2)
    }
    // Said before it happens, because both have a consequence that is
    // obvious afterwards and not before. A rename leaves the generated
    // app bundles behind (their launch command names the old instance),
    // and a clone's copy shares the original's host keys and machine-id
    // until the guest regenerates them.
    if transferVerb == "rename" {
        print("Renaming \(transferNames[0]) to \(transferNames[1]). Its apps are rescanned the next "
              + "time you open the Applications tab - any Launchpad entries and Dock pins for the old "
              + "name are removed, since a generated app launches an instance by name.")
    } else {
        print("Cloning \(transferNames[0]) to \(transferNames[1]): its disk, accounts, files and "
              + "settings, as a separate instance. The copy keeps the original's SSH host key until "
              + "the guest makes a new one, so `msl ssh` may warn about a changed key.")
    }
    runControl(transferVerb == "rename"
        ? .renameInstance(instance: transferNames[0], newName: transferNames[1])
        : .cloneInstance(instance: transferNames[0], newName: transferNames[1]))

case "dns":
    // Part of the privacy options: who answers this instance's name lookups.
    // Traffic still leaves through the Mac, which the wording says plainly.
    let dnsArgs = Array(args.dropFirst())
    let dnsPositional = dnsArgs.filter { !$0.hasPrefix("-") }
    let dnsInstance = dnsPositional.first.flatMap { registryForLookup.distro(for: $0) != nil ? $0 : nil } ?? startupInstance()
    guard let dnsDistro = registryForLookup.distro(for: dnsInstance) else {
        FileHandle.standardError.write("msl: there's no instance called \(dnsInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    let dnsWanted = dnsPositional.first(where: { $0 != dnsInstance })
    guard let dnsWanted else {
        do {
            let reading = try GuestDNS.read(instance: dnsInstance, distro: dnsDistro)
            switch reading.source {
            case .unknown:
                print("\(dnsInstance) resolves with: whatever the distro decides")
            case .stubOnly:
                // True, and useless on its own: the stub forwards somewhere
                // this read could not see.
                print("\(dnsInstance) resolves through a local stub (\(reading.servers.joined(separator: ", "))) - the distro decides where it forwards")
            case .configured:
                print("\(dnsInstance) is set to resolve with: \(reading.servers.joined(separator: ", "))")
            case .resolved, .resolvConf:
                print("\(dnsInstance) resolves with: \(reading.servers.joined(separator: ", "))")
            }
            print("\nChange it: msl dns \(dnsInstance) auto|cloudflare|google|quad9|<address>")
        } catch {
            FileHandle.standardError.write("msl: couldn't ask \(dnsInstance) - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }
    let dnsChoice: GuestDNS.Choice
    switch dnsWanted.lowercased() {
    case "auto", "automatic", "default": dnsChoice = .automatic
    case "cloudflare": dnsChoice = .cloudflare
    case "google": dnsChoice = .google
    case "quad9": dnsChoice = .quad9
    default:
        let servers = dnsWanted.split(separator: ",").map(String.init)
        guard servers.allSatisfy(GuestDNS.isValidServer) else {
            FileHandle.standardError.write("msl: '\(dnsWanted)' is not an address or a known choice (auto, cloudflare, google, quad9)\n".data(using: .utf8)!)
            exit(2)
        }
        dnsChoice = GuestDNS.Choice(name: "Custom", servers: servers)
    }
    do {
        guard try GuestDNS.apply(dnsChoice, instance: dnsInstance, distro: dnsDistro) else {
            FileHandle.standardError.write("msl: \(dnsInstance) refused the change\n".data(using: .utf8)!)
            exit(1)
        }
        if dnsChoice.servers.isEmpty {
            print("\(dnsInstance) is back to the distro's own DNS.")
        } else {
            print("\(dnsInstance) now resolves with \(dnsChoice.servers.joined(separator: ", ")).")
            print("Lookups are hidden from your local network, not from this Mac: traffic still leaves through it.")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("msl: couldn't change DNS in \(dnsInstance) - \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "vpn":
    // The hide.me client, inside one instance. MSL installs it and reports
    // what it finds; logging in and connecting stay with the user and their
    // own account, which is why this prints commands instead of running
    // them. See `GuestVPN`.
    let vpnArgs = Array(args.dropFirst())
    let vpnPositional = vpnArgs.filter { !$0.hasPrefix("-") }
    let vpnInstance = vpnPositional.first.flatMap { registryForLookup.distro(for: $0) != nil ? $0 : nil } ?? startupInstance()
    guard let vpnDistro = registryForLookup.distro(for: vpnInstance) else {
        FileHandle.standardError.write("msl: there's no instance called \(vpnInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    let vpnAction = vpnPositional.first(where: { $0 != vpnInstance })?.lowercased() ?? "status"
    func printVPNStatus() {
        do {
            let status = try GuestVPN.status(instance: vpnInstance, distro: vpnDistro)
            if status.installed {
                print("The hide.me client is installed in \(vpnInstance).")
            } else {
                print("hide.me is not installed in \(vpnInstance).")
            }
            print("  WireGuard in the kernel: \(status.wireGuard ? "yes" : "no")")
            print("  Logged in: \(status.hasToken ? "yes" : "no")")
            print("  Connected: \(status.connected ? "yes" : "no")")
            if let next = status.nextStep() { print("\n\(next)") }
            if !status.installed { print("Install it: msl vpn \(vpnInstance) install") }
            print("\nThe tunnel is this instance's only. Your Mac's own traffic doesn't go through it.")
        } catch {
            FileHandle.standardError.write("msl: couldn't ask \(vpnInstance) - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    switch vpnAction {
    case "status":
        printVPNStatus()
        exit(0)
    case "install":
        print("Downloading hide.me \(GuestVPN.version) into \(vpnInstance)...")
        do {
            let result = try GuestVPN.install(instance: vpnInstance, distro: vpnDistro)
            print(result.message)
            guard result == .installed else { exit(1) }
            print("You need your own hide.me account - the free servers work with one too.")
            printVPNStatus()
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: install failed in \(vpnInstance) - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    case "remove", "uninstall":
        do {
            try GuestVPN.remove(instance: vpnInstance, distro: vpnDistro)
            print("Removed the hide.me client from \(vpnInstance).")
            exit(0)
        } catch {
            FileHandle.standardError.write("msl: couldn't remove it from \(vpnInstance) - \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    default:
        FileHandle.standardError.write("msl: vpn takes status, install or remove\n".data(using: .utf8)!)
        exit(2)
    }

case "lock":
    // The same switch as the app's Locking card. Enforced by mslhd, so it
    // covers `msl`, the Dock and anything else that can start an instance.
    let lockArgs = Array(args.dropFirst())
    let lockNames = lockArgs.filter { $0 != "on" && $0 != "off" }
    let lockInstance = lockNames.first ?? startupInstance()
    guard registryForLookup.distro(for: lockInstance) != nil else {
        FileHandle.standardError.write("msl: there's no instance called \(lockInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    let wanted = lockArgs.contains("on") ? true : (lockArgs.contains("off") ? false : nil)
    guard let wanted else {
        let locked = InstanceLockStore.load().isLocked(lockInstance)
        print("\(lockInstance) is \(locked ? "locked - starting it asks for Touch ID or your password" : "unlocked").")
        print("Change it: msl lock \(lockInstance) on|off")
        exit(0)
    }
    guard !wanted || BiometricAuth.isAvailable() else {
        FileHandle.standardError.write("msl: this Mac has no Touch ID or password set, so there is nothing to ask for\n".data(using: .utf8)!)
        exit(1)
    }
    guard InstanceLockStore.setLocked(wanted, for: lockInstance) else {
        FileHandle.standardError.write("msl: couldn't save that setting\n".data(using: .utf8)!)
        exit(1)
    }
    print("\(lockInstance) is now \(wanted ? "locked" : "unlocked").")
    if wanted { print("Starting it will ask; while it's running or suspended it won't ask again.") }
    exit(0)

case "kitty":
    // The cat. `msl kitty` shows what a shell opens with; `msl kitty "words"`
    // gives her a cowsay speech bubble instead; `on`/`off` decide whether
    // she turns up at the top of every shell.
    let kittyArgs = Array(args.dropFirst())
    switch kittyArgs.first {
    case "on", "off":
        var settings = PersonalitySettingsStore.load()
        settings.kitty = kittyArgs[0] == "on"
        guard PersonalitySettingsStore.save(settings) else {
            FileHandle.standardError.write("msl: couldn't save that setting\n".data(using: .utf8)!)
            exit(1)
        }
        print("The cat is \(settings.kitty ? "on" : "off") in every shell.")
        exit(0)
    case .none:
        // What a shell would actually show, not the cat in isolation - the
        // whole point of `msl kitty` is to see what you are turning on.
        let preview = PersonalitySettingsStore.load()
        print(PersonalityBanner.render(settings: PersonalitySettings(greeters: preview.greeters, kitty: true),
                                       greeting: Greeter.nextGreeting()?.text,
                                       columns: Int(currentWindowSize().cols)) ?? Kitty.art)
        if !preview.kitty { print("\nShe is off in shells right now: msl kitty on") }
        exit(0)
    default:
        print(Kitty.say(kittyArgs.joined(separator: " ")))
        exit(0)
    }

case "greeter":
    // The line under the msl@distro banner. It prints on every single
    // session, so it deserves a switch.
    let greeterArgs = Array(args.dropFirst())
    switch greeterArgs.first {
    case "on", "off":
        var settings = PersonalitySettingsStore.load()
        settings.greeters = greeterArgs[0] == "on"
        guard PersonalitySettingsStore.save(settings) else {
            FileHandle.standardError.write("msl: couldn't save that setting\n".data(using: .utf8)!)
            exit(1)
        }
        print("Greeters are \(settings.greeters ? "on" : "off").")
        exit(0)
    case .none:
        let settings = PersonalitySettingsStore.load()
        print("Greeters are \(settings.greeters ? "on" : "off"), the cat is \(settings.kitty ? "on" : "off").")
        print("Change either: msl greeter on|off, msl kitty on|off")
        // The same renderer the shell uses, so this is not a description of
        // what happens but the thing itself.
        if let banner = PersonalityBanner.render(settings: settings,
                                                 greeting: Greeter.nextGreeting()?.text,
                                                 columns: Int(currentWindowSize().cols)) {
            print("\nEvery shell opens with:\n")
            print(banner)
        } else {
            print("\nShells open with nothing extra.")
        }
        exit(0)
    default:
        FileHandle.standardError.write("usage: msl greeter [on|off]\n".data(using: .utf8)!)
        exit(2)
    }

case "fix-home":
    // The other half of running apps as the user instead of root: apps that
    // already ran as root left root-owned files in the account's home, and
    // the account cannot edit its own settings until they are handed back.
    let fixNames = args.dropFirst().filter { !$0.hasPrefix("-") }
    let fixDryRun = args.contains("--dry-run") || args.contains("-n")
    let fixInstance = fixNames.first ?? startupInstance()
    guard let fixDistro = registryForLookup.distro(for: fixInstance) else {
        FileHandle.standardError.write("msl: there's no instance called \(fixInstance) - `msl list` shows them\n".data(using: .utf8)!)
        exit(1)
    }
    guard let fixUser = GuestUser.forUserFacingWork(in: fixInstance) else {
        print("\(fixInstance) has no Linux account yet, so there is nothing to hand over.")
        print("Open it once (msl \(fixInstance)) and create your account first.")
        exit(0)
    }
    let fixReport: HomeOwnership.Report?
    do {
        fixReport = try HomeOwnership.scan(instance: fixInstance, distro: fixDistro)
    } catch {
        FileHandle.standardError.write("msl: couldn't check \(fixInstance) - \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    guard let report = fixReport else {
        print("msl: couldn't find \(fixUser)'s home directory in \(fixInstance).")
        exit(1)
    }
    guard report.needsRepair else {
        print("\(report.home) is already \(fixUser)'s. Nothing to do.")
        exit(0)
    }
    print("\(report.wrongCount) file(s) in \(report.home) don't belong to \(fixUser).")
    print("They were made by apps MSL used to run as root.")
    for sample in report.samples.prefix(10) { print("    \(sample)") }
    if report.wrongCount > report.samples.count { print("    ...") }
    if fixDryRun {
        print("\nDry run. To hand them back: msl fix-home \(fixInstance)")
        exit(0)
    }
    print("\nGiving them to \(fixUser)...")
    do {
        let repaired = try HomeOwnership.repair(instance: fixInstance, distro: fixDistro)
        print("OK handed \(repaired) file(s) back to \(fixUser).")
        exit(0)
    } catch {
        FileHandle.standardError.write("msl: couldn't repair \(fixInstance) - \(error)\n".data(using: .utf8)!)
        exit(1)
    }

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
    // A managed Mac can be stopped from having MSL removed from under it.
    // Binds this account, not root - `sudo` still works, and the message
    // says so rather than implying otherwise.
    if !MSLAPGate.allows("system.uninstall", instance: nil) {
        print("msl uninstall: " + (MSLAPGate.reason("system.uninstall", instance: nil)
                                   ?? "Not allowed by the MSL Admin Portal"))
        exit(1)
    }
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
        // **Finish it, rather than handing somebody a `sudo rm -rf` to
        // paste.** That is not an uninstaller finishing; it is an
        // uninstaller stopping. People who will not paste it are left with
        // MSL half-removed and no idea which half, and people who will are
        // being trained to run `sudo rm -rf` from something they read on a
        // screen.
        print("\nmsl: a few parts belong to the system, so macOS will ask for your password.")
        if let why = Uninstaller.finishPrivileged(uninstallReport) {
            print("msl: \(why)")
            print("msl: to finish by hand: \(parts.joined(separator: " && "))")
        } else {
            print("msl: done - nothing of MSL is left on this Mac.")
        }
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

case "public":
    // Reaching an instance from outside this Mac. The verb is deliberately
    // not a flag on `msl ssh`: publishing a machine to the internet should
    // read as its own decision, not as an option on something routine.
    switch args.count > 1 ? args[1] : "status" {
    case "expose", "on":
        var instance = defaultInstance
        var backend = "relay-pinggy"
        var force = false
        for argument in args.dropFirst(2) {
            if argument == "--yes" || argument == "-y" {
                force = true
            } else if argument.hasPrefix("--via=") {
                // `--via=user@host:2222` publishes through a server you own,
                // which is the backend a real mini server wants: the address
                // is yours and nothing expires.
                let value = String(argument.dropFirst("--via=".count))
                if value.hasPrefix("relay-") {
                    backend = value
                } else if value == "tailscale" || value.hasPrefix("tailscale:") {
                    backend = value.contains(":") ? value : "tailscale:2222"
                } else {
                    backend = selfHostedToken(value)
                }
            } else if argument.hasPrefix("relay-") {
                backend = argument
            } else {
                instance = argument
            }
        }
        confirmPublish(instance: instance, force: force)
        runPublicExpose(instance: instance, backend: backend)
    case "revoke", "off":
        runControl(.publicRevoke(instance: args.count > 2 ? args[2] : defaultInstance))
    case "status":
        runPublicStatus(instance: args.count > 2 ? args[2] : defaultInstance)
    case "authorize", "add-key":
        guard args.count >= 4 else {
            printAuthorizeHelp(defaultInstance)
            exit(args.count >= 3 ? 0 : 1)
        }
        runPublicAuthorize(instance: args[2], keyOrFile: args[3],
                           label: args.count > 4 ? args[4] : "")
    case "deauthorize", "remove-key":
        guard args.count >= 4 else {
            print("msl public deauthorize <instance> <label-or-fingerprint>")
            exit(1)
        }
        runControl(.publicDeauthorize(instance: args[2], match: args[3]))
    case "tips", "how":
        // `msl public tips <instance> [windows|mac|linux|freebsd]`
        runPublicTips(instance: args.count > 2 ? args[2] : defaultInstance,
                      platform: args.count > 3 ? args[3] : "")
    case "keys":
        runPublicKeys(instance: args.count > 2 ? args[2] : defaultInstance)
    case "key":
        // Where this Mac's own key is, and a way straight to it. Asked
        // often enough - after a publish, the next thing people want is the
        // file itself - that hunting for a path under /Users/Shared is the
        // wrong answer.
        runPublicKeyLocation(instance: args.count > 2 ? args[2] : defaultInstance,
                             reveal: args.contains("--reveal") || args.contains("-r"))
    case "notify", "email":
        runPublicNotify(args, defaultInstance: defaultInstance)
    case "invite":
        guard args.count >= 4 else {
            print("msl public invite <instance> <name>")
            print("")
            print("Makes them a key and prints everything they need, ready to paste")
            print("into a message. Use this when you have not set up email.")
            exit(1)
        }
        runPublicInvite(instance: args[2], label: args[3...].joined(separator: " "))
    default:
        usageAndExit()
    }

case "usb":
    // `msl usb` with no verb lists, because listing is the only thing that
    // is safe to do by accident.
    switch args.count > 1 ? args[1] : "list" {
    case "list":
        runUSBList()
    case "attach":
        guard args.count >= 3 else { usageAndExit() }
        var device = ""
        var instance = defaultInstance
        for argument in args.dropFirst(2) {
            if argument.hasPrefix("-") { usageAndExit() }
            else if device.isEmpty { device = argument }
            else { instance = argument }
        }
        guard !device.isEmpty else { usageAndExit() }
        runUSBAttach(device: device, instance: instance)
    case "relay":
        // Prints a socket path for a root helper to serve a device on, and
        // exits. `msl usb attach` does this and starts the helper itself;
        // this exposes the halfway point for scripts, for a future USB
        // panel in MSL.app, and for driving the privileged path by hand.
        //
        // Safe to expose: the socket is useless to anything that is not
        // root, because mslhd checks the peer's uid before it will relay a
        // byte.
        guard args.count >= 3 else { usageAndExit() }
        runControl(.usbRelay(instance: args.count > 3 ? args[3] : defaultInstance, device: args[2]))
    case "detach":
        guard args.count >= 3 else { usageAndExit() }
        let instance = args.count > 3 ? args[3] : defaultInstance
        runControl(.usbDetach(instance: instance, device: args[2]))
    case "test":
        // Attaches MSL's synthetic device: proves the whole passthrough
        // path end to end without any hardware plugged in.
        //
        // `--relay` drives the *privileged* half of that path instead - the
        // root helper, the handshake socket, the uid check and the pump -
        // with the same device that needs no hardware. Without it there is
        // no way to verify the capture tier on a Mac with nothing plugged
        // in, which is exactly the Mac this was developed on.
        let relayTest = args.contains("--relay")
        let testInstance = args.dropFirst(2).first { !$0.hasPrefix("-") } ?? defaultInstance
        runUSBAttach(device: "synthetic", instance: testInstance, forceRelay: relayTest)
    default:
        usageAndExit()
    }

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
    // Show or change how much disk an instance may use. Private to that
    // instance since each one has its own disk (`InstanceDisk`); it used to
    // be the distro's image, shared by every instance of it.
    let storageInstance = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : defaultInstance
    let storageDistro = effectiveDistro(forInstance: storageInstance)
    let storageBoot = storageDistro.bootFiles(instance: storageInstance)
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
        // Reported, never assumed: `setPolicy` refuses a change MSLAP
        // forbids, and printing "is now fixed at 32G" over a refusal is
        // worse than the refusal itself.
        guard DiskStorage.setPolicy(StoragePolicy(mode: mode, size: size, autoGrow: mode == .dynamic),
                                    forImageNamed: imageName) else {
            let why = MSLAPGate.reason("resources.disk", instance: storageInstance)
                ?? MSLAPGate.reason("resources.edit", instance: storageInstance)
                ?? "the disk settings could not be saved"
            FileHandle.standardError.write("msl: \(why)\n".data(using: .utf8)!)
            exit(1)
        }
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
    // Generated apps embed a copy of the launcher from the day they were
    // made. MSL.app refreshes them at startup; without this, deploying from
    // the command line left every already-added app running the old copy -
    // which is exactly how a launch fix can look like it did nothing.
    let refreshed = LinuxAppBundle.refreshLaunchers()
    if refreshed > 0 { print("refreshed \(refreshed) generated app(s)") }
    for tool in toolResult.skippedOlder {
        print("kept the newer installed \(tool) - this build's copy is older")
    }
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
        // `qualifiedName`, the same as the app's own descriptor: two
        // packagings of one application (a Flatpak Calculator and a Snap
        // Calculator) both wanted `Calculator.app`, so installing the
        // second silently replaced the first.
        LinuxAppBundle.Descriptor(
            instance: appsInstance, distro: appsDistro, displayName: app.qualifiedName,
            menuName: app.name,
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
            let marker = installed.contains(LinuxAppBundle.fileSafeName(app.qualifiedName)) ? "*" : " "
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
        let app = resolveApp(named: wanted, in: apps, instance: appsInstance)
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
        let app = resolveApp(named: wantedPin, in: appsForPin, instance: appsInstance)
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
    // A word MSL doesn't recognise is an instance name - that is what makes
    // `msl work` open a shell with no ceremony, and `msl fedora` set up a
    // Fedora on a fresh install with nothing else to remember.
    //
    // It was also unguarded. Any word at all became a real instance with a
    // real disk: a leading `-` from a mistyped flag, and `msl about` quietly
    // downloading Alpine to make an instance called "about" (2026-10-01).
    // `openableRefusal` is the whole policy, and it is deliberately narrow -
    // an existing instance always opens, and a new one is created only when
    // the distro was said out loud. Both documented forms survive intact.
    //
    // Refuses rather than prompting: `msl work ls -la` runs in scripts, and
    // a confirmation prompt would hang a non-interactive invocation. An
    // exit code and a suggestion cost a working pipeline nothing.
    if let refusal = openableRefusal(instanceName) {
        FileHandle.standardError.write("msl: \(refusal)\n".data(using: .utf8)!)
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

/// What MSLAP is enforcing on this Mac, and - just as importantly - how
/// much that is worth. An administrator who believes a policy is binding
/// when it sits in a file the user can edit is the failure this prints
/// against, so the strength line is never omitted or softened.
func printAdminStatus(instance: String?) {
    switch MSLAPPolicyStore.load() {
    case .unmanaged:
        print("MSL Admin Portal: not managed")
        print("  No policy is installed, so nothing is restricted.")
        print("  Capabilities a policy could restrict: \(MSLAPCapability.catalogue.count)")
        print("  See them with: msl admin capabilities")

    case .broken(let failure, let fallback):
        // Deliberately not reported as "unmanaged": a policy is present
        // and cannot be honoured, which an administrator must hear about.
        print("MSL Admin Portal: POLICY PRESENT BUT NOT IN FORCE")
        switch failure {
        case .unreadable(let path):
            print("  Cannot read \(path)")
        case .malformed(let path, let detail):
            print("  \(path) is not a valid policy")
            print("  \(detail)")
        case .schemaTooNew(let path, let schema):
            print("  \(path) uses schema \(schema); this MSL understands \(MSLAPPolicy.currentSchema)")
        case .needsNewerMSL(let path, let required):
            print("  \(path) requires MSL \(required); this is \(MSLVersion.marketing)")
        case .signatureInvalid(let path, let detail):
            // The loudest of the lot: this is the one that means somebody
            // edited a managed policy.
            print("  \(path) FAILED ITS SIGNATURE CHECK")
            print("  \(detail)")
        case .none:
            break
        }
        if let fallback {
            // Tampering must never be a way to REMOVE restrictions.
            let denied = MSLAPCapability.catalogue
                .filter { !fallback.allows($0.capability) }.count
            print("  Still enforcing the last policy that verified"
                  + " (\(denied) capabilit\(denied == 1 ? "y" : "ies") denied).")
            if let issuer = fallback.issuer { print("  That policy was issued by \(issuer).") }
        } else {
            print("  Nothing is being enforced. Fix or remove the policy.")
        }

    case .managed(let loaded):
        let policy = loaded.policy
        print("MSL Admin Portal: managed")
        if let issuer = policy.issuer { print("  Issued by:  \(issuer)") }
        if let issued = policy.issued {
            print("  Issued:     \(ISO8601DateFormatter().string(from: issued))")
        }
        print("  Policy:     \(loaded.url.path)")
        print("  Strength:   \(loaded.strength.title)")
        print("              \(loaded.strength.detail)")
        if let signedBy = loaded.signedBy {
            let mode = MSLAPKeyStore.isLocalAdminMode ? "local admin key" : "fleet key"
            print("  Signature:  valid, by \(signedBy) (\(mode))")
            if MSLAPKeyStore.isLocalAdminMode {
                // Said plainly, because it is the difference between
                // "nobody can change this" and "nobody can change this by
                // accident".
                print("              The signing key is on this Mac, so anyone with root can re-sign.")
            }
        } else if let problem = loaded.signatureProblem {
            print("  Signature:  \(problem.detail)")
        }
        if let message = policy.message { print("  Message:    \(message)") }

        let unknown = policy.unknownCapabilities
        if !unknown.isEmpty {
            // Ignored rather than enforced, and said out loud - a policy
            // written for a newer MSL must not look like it is in force.
            print("  Ignored:    \(unknown.count) capability name(s) this MSL does not know")
            for capability in unknown { print("                \(capability.key)") }
        }

        print("")
        if let instance {
            print("  For instance '\(instance)':")
        } else {
            print("  Application-wide (pass an instance name to see its rules):")
        }
        var denied = 0
        for group in MSLAPCapability.groups {
            var lines: [String] = []
            for entry in MSLAPCapability.catalogue
            where entry.capability.key.hasPrefix(group + ".") {
                let decision = policy.decision(for: entry.capability, instance: instance)
                guard !decision.allowed else { continue }
                denied += 1
                var line = "    \(entry.capability.key.padding(toLength: 32, withPad: " ", startingAt: 0))denied"
                if let by = decision.deniedByCapability, by != entry.capability {
                    line += " (by \(by.key))"
                }
                if let reason = decision.deniedBy?.reason { line += " - \(reason)" }
                if entry.unavailable {
                    line += "  [no such action in this version]"
                } else if !entry.enforced {
                    line += "  [not yet enforced]"
                }
                lines.append(line)
            }
            if !lines.isEmpty {
                print("  \(group)")
                lines.forEach { print($0) }
            }
        }
        if denied == 0 { print("    nothing denied") }

        // Protected instances, and whether they really are.
        //
        // Shown here rather than only in `msl doctor` because this is the
        // screen an administrator reads when deciding whether a deployment
        // does what they asked for - and "cloning is denied" reads as
        // finished when it is not. See READMES/32-PROTECTED-INSTANCES.md.
        // Certified lineages. Shown because this is the one tier that
        // holds against a determined local user, so an administrator
        // deciding whether a deployment is sound needs to see it.
        if instance == nil {
            let certificates = LineageCertificateStore.all()
            if !certificates.isEmpty {
                print("")
                print("  Lineage certificates:")
                for (lineage, verdict) in certificates.sorted(by: { $0.key < $1.key }) {
                    switch verdict {
                    case .none:
                        continue
                    case .certified(let label, _, let rootOwned):
                        print("    \(lineage.prefix(8))…  \(label)"
                              + (rootOwned ? "" : "  [user-writable, advisory]"))
                    case .revoked(let label, _):
                        print("    \(lineage.prefix(8))…  \(label)  [WITHDRAWN]")
                    case .invalid(let why):
                        print("    \(lineage.prefix(8))…  does not verify: \(why)")
                    }
                }
            }
        }

        if instance == nil,
           let protection = ProtectedInstance.summary(
               instances: registryForLookup.list(), policy: MSLAPGate.policy) {
            print("")
            print("  Images protected from being copied:")
            print(protection)
            print("")
            print("  `msl doctor` says what to do about any route left open.")
        }
    }
}
