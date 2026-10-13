import Compression
import Foundation

/// The small guest-side kit that makes Linux apps MSL launches hand links,
/// mail and folders to the Mac, and (optionally) show their menus in the
/// Mac's menu bar.
///
/// **Nothing global in the guest changes.** The kit lives in the launching
/// user's `~/.local/share/msl-integration`, and it only takes effect for
/// processes started with `launchCommand`'s environment: its directories go
/// in front of `XDG_DATA_DIRS` and `XDG_CONFIG_DIRS`, where the freedesktop
/// lookups (`gio`, `xdg-open`, `xdg-mime`, D-Bus activation) find its
/// `mimeapps.list`, `.desktop` handlers and D-Bus service before the
/// distro's own. A terminal session, a cron job or an app started any other
/// way sees the guest exactly as it was.
///
/// **The Mac decides, at request time.** Every handler asks `mslhd` over
/// vsock (`HostOpenService`) and does what it says; a "declined" (feature
/// off, instance sandboxed, no MSL Files mount) puts the original
/// environment back and runs the Linux handler instead. That is why the
/// Experimental Features toggles for links and folders apply to apps that
/// are already open, and why the kit is installed regardless of them.
///
/// Installed over the one-shot command channel rather than baked into the
/// image, so images built before this existed get it too. It is re-written
/// only when `stamp` changes.
public enum GuestIntegration {
    /// Where `HostOpenService` listens. 5000-5007 are taken; see
    /// `VMConfiguration`.
    public static let hostOpenPort: UInt32 = 5008

    /// Relative to the guest user's home.
    static let directory = ".local/share/msl-integration"

    struct File: Equatable {
        let path: String
        let contents: String
        let executable: Bool
    }

    /// Every file the kit writes. `@MSLDIR@` is replaced with the kit's
    /// absolute path at install time, since `$HOME` is only known there.
    static let files: [File] = [
        File(path: "bin/msl-open", contents: mslOpenShell, executable: true),
        File(path: "bin/msl_open.py", contents: mslOpenPython, executable: true),
        File(path: "bin/msl_filemanager1.py", contents: fileManager1Python, executable: true),
        File(path: "bin/msl_menubridge.py", contents: menuBridgePython, executable: true),
        File(path: "bin/msl_portal.py", contents: portalPython, executable: true),
        File(path: "bin/msl-file-picker", contents: filePickerShell, executable: true),
        File(path: "bin/msl-firefox-portal", contents: firefoxPortalShell, executable: true),
        // Source, not a binary: see `gtkPickerSource`. `installCommand`
        // compiles it next to itself when the guest has a C compiler.
        File(path: "lib/msl-gtkpicker.c", contents: gtkPickerSource, executable: false),
        File(path: "share/applications/msl-open-url.desktop", contents: openURLDesktop, executable: false),
        File(path: "share/applications/msl-files.desktop", contents: filesDesktop, executable: false),
        // The menu entry's icon. `hicolor/scalable` is the path every icon
        // theme falls back to, so no theme has to know about MSL.
        File(path: "share/icons/hicolor/scalable/apps/msl-files.svg",
             contents: filesIconSVG, executable: false),
        // Both places: gio and current xdg-mime read the config dirs, older
        // xdg-mime only the data dirs.
        File(path: "share/applications/mimeapps.list", contents: mimeApps, executable: false),
        File(path: "config/mimeapps.list", contents: mimeApps, executable: false),
        File(path: "share/dbus-1/services/org.freedesktop.FileManager1.service", contents: fileManager1Service, executable: false),
        File(path: "share/dbus-1/services/org.freedesktop.portal.Desktop.service", contents: portalService, executable: false),
    ]

    /// Changes whenever any file **or any install step** does, so an updated
    /// MSL rewrites the kit on the next launch and an unchanged one costs a
    /// single `cat`.
    ///
    /// **`postInstallSteps` is in the hash for a reason.** It used to cover
    /// only `files`, so a change to what the installer *does* - compiling the
    /// shim, placing the D-Bus service - left the stamp identical, the whole
    /// `if` block skipped, and the new step silently never ran on any guest
    /// that already had the kit. That is a very quiet way to ship nothing
    /// (hit 2026-09-30 with the FileManager1 service).
    static var stamp: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: [UInt8]) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
        }
        for file in files {
            mix(Array(file.path.utf8) + [0] + Array(file.contents.utf8) + [file.executable ? 1 : 0])
        }
        mix(Array(postInstallSteps.utf8))
        return String(hash, radix: 16)
    }

    /// What the installer does once every file is written.
    ///
    /// Separate and named so `stamp` can hash it: these steps are as much
    /// part of "is the kit up to date?" as the files are, and while they were
    /// not hashed, changing one of them refreshed nothing on a guest that
    /// already had the kit.
    static let postInstallSteps = #"""
      # **The D-Bus service file has to live where the *bus* looks, which is
      # not where the kit lives.** A session bus scans
      # $XDG_DATA_HOME/dbus-1/services and whatever was on XDG_DATA_DIRS
      # WHEN THE BUS STARTED. MSL puts its own share directory on
      # XDG_DATA_DIRS for the apps it launches, but the bus is logind's and
      # started at login, long before any of that - so it never saw MSL's
      # copy, org.freedesktop.FileManager1 had no owner, and "show in folder"
      # from a Linux app reached nothing (measured 2026-09-30:
      # NameHasNoOwner). ~/.local/share/dbus-1/services is the canonical
      # per-user spot every session bus scans, and dbus-daemon watches it, so
      # copying there works without restarting the bus or the session.
      # The portal service file goes with it, for a different reason: not to
      # be found at all, but to be found FIRST. See `portalService`.
      msl_services="$HOME/.local/share/dbus-1/services"
      if mkdir -p "$msl_services" 2>/dev/null; then
        for msl_svc in org.freedesktop.FileManager1.service \
                       org.freedesktop.portal.Desktop.service; do
          cp -f "$MSL_D/share/dbus-1/services/$msl_svc" \
                "$msl_services/" 2>/dev/null || true
        done
      fi
      # The GTK file-dialog shim is built here rather than shipped, because
      # the kit is text and MSL has no cross-compiler for every guest it
      # supports. Never fatal: a guest with no `cc` keeps its own GTK
      # dialogs, which is the pre-existing behaviour and a perfectly good
      # one. Stderr is dropped so a failed build cannot put compiler noise in
      # front of someone launching an app - `filePortalLines` only preloads
      # the result if it exists.
      if command -v cc >/dev/null 2>&1; then
        cc -O2 -shared -fPIC -o "$MSL_D/lib/msl-gtkpicker.so.new" \
           "$MSL_D/lib/msl-gtkpicker.c" -ldl >/dev/null 2>&1 \
          && mv -f "$MSL_D/lib/msl-gtkpicker.so.new" "$MSL_D/lib/msl-gtkpicker.so" \
          || rm -f "$MSL_D/lib/msl-gtkpicker.so.new"
      fi
    """#

    /// A shell snippet that installs or refreshes the kit. Never fails the
    /// command it is part of: without the kit, apps simply keep using Linux
    /// handlers.
    /// Deflate with a gzip wrapper, so the guest can `gzip -cd` it.
    ///
    /// Hand-rolled rather than pulled from a library: this is the only
    /// place MSL compresses anything, and a dependency for one call is not
    /// worth it. The wrapper is the 10-byte header, the raw deflate stream,
    /// then CRC32 and the length - exactly what `gzip` expects.
    static func gzipped(_ text: String) -> Data {
        let source = Data(text.utf8)
        var output = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03])
        output.append(deflate(source))
        var crc = crc32(source).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: source.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private static func deflate(_ data: Data) -> Data {
        var result = Data(count: max(64, data.count))
        let written = result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return result.prefix(written)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    public static func installCommand() -> String {
        var lines: [String] = [
            #"MSL_D="$HOME/\#(directory)""#,
            #"if [ "$(cat "$MSL_D/.stamp" 2>/dev/null)" != "\#(stamp)" ]; then"#,
            #"  mkdir -p "$MSL_D/bin" "$MSL_D/lib" "$MSL_D/config" "$MSL_D/share/applications" "$MSL_D/share/icons/hicolor/scalable/apps" "$MSL_D/share/dbus-1/services" && ("#,
        ]
        for file in files {
            // **Compressed, then base64.** The whole kit travels inside one
            // `shellinit` EXEC frame, whose length is a 16-bit field - so
            // the real ceiling is 65535 bytes for the command *and* its
            // shell scaffolding, and base64 alone adds 33% on top of the
            // sources. Gzipping first roughly halves the payload, which is
            // what let the file-chooser portal fit at all
            // (`testInstallCommandFitsOneExecFrame`). `gzip` is in every
            // base image MSL supports; `base64 -d` was already required.
            let encoded = gzipped(file.contents).base64EncodedString()
            var line = #"    printf '%s' '\#(encoded)' | base64 -d | gzip -cd | sed "s|@MSLDIR@|$MSL_D|g" > "$MSL_D/\#(file.path)""#
            if file.executable { line += #" && chmod 755 "$MSL_D/\#(file.path)""# }
            lines.append(line + " &&")
        }
        lines.append(#"    printf '%s' '\#(stamp)' > "$MSL_D/.stamp") || echo "msl: couldn't install the MSL integration kit" >&2"#)
        lines.append(postInstallSteps)
        lines.append("fi")
        return lines.joined(separator: "\n")
    }

    /// The display MSL's own X11 server answers on inside every guest.
    public static let display = ":1"

    /// Makes every shell in the guest find MSL's display, run as root.
    ///
    /// Before this, `DISPLAY` was only ever set on commands MSL launched
    /// itself (`launchCommand`), so typing `gnome-chess` at a prompt - in the
    /// app's Terminal tab or in Terminal.app - failed with "Failed to open
    /// display" even though the X server and the tunnel were both fine.
    /// Measured 2026-09-16: as the user's own account, with `DISPLAY=:1` set,
    /// the same app opened; the socket is world-writable.
    ///
    /// Only sets it when it isn't set, so an `ssh -X` session or someone's
    /// own choice is left alone. `/etc/profile.d` covers login shells, which
    /// is what an interactive `msl` session is; zsh doesn't read
    /// `/etc/profile` on Debian or Ubuntu, so it gets the same line in
    /// `zshenv`. Neither can fail the command it is part of.
    public static func displayProfileCommand() -> String {
        let line = #"[ -n "${DISPLAY-}" ] || export DISPLAY="# + display
        return [
            #"if [ -d /etc/profile.d ] && ! grep -qs 'MSL display' /etc/profile.d/00-msl-display.sh; then"#,
            #"  printf '%s\n' '# MSL display: Linux GUI apps open as windows on your Mac.' '\#(line)' > /etc/profile.d/00-msl-display.sh 2>/dev/null || true"#,
            "fi",
            // Debian, Ubuntu and Arch keep it in /etc/zsh; Fedora and friends in /etc.
            "if command -v zsh >/dev/null 2>&1; then",
            #"  if [ -d /etc/zsh ]; then msl_zshenv=/etc/zsh/zshenv; else msl_zshenv=/etc/zshenv; fi"#,
            #"  grep -qs 'MSL display' "$msl_zshenv" || printf '%s\n' '# MSL display' '\#(line)' >> "$msl_zshenv" 2>/dev/null || true"#,
            "fi",
        ].joined(separator: "\n")
    }

    /// Where the per-user session environment is written, under `$HOME`.
    static let sessionEnvRelativePath = "\(directory)/session-env.sh"

    /// Installs the stub that makes every login shell pick up MSL's session.
    ///
    /// **Must run as root**, which is the whole reason this is separate from
    /// the file it sources. `displayProfileCommand` above writes to
    /// `/etc/profile.d` too, but it is run as the *user* by `startTunnel`,
    /// and every write there ends in `|| true` - so on a guest whose account
    /// is not root it silently wrote nothing at all, and an interactive shell
    /// got no `DISPLAY`, no bus and no runtime directory. Typing `chromium`
    /// at a prompt failed with "Missing X server or $DISPLAY" while the same
    /// app from the Applications tab worked (reported 2026-10-01).
    ///
    /// The stub is deliberately tiny and never changes, so it can be written
    /// once and left alone. Everything that varies - the display, the bus,
    /// the experimental settings - lives in the per-user file it sources,
    /// which `sessionEnvFileCommand` rewrites on every session.
    ///
    /// `$HOME` rather than a fixed path: one guest can have several accounts,
    /// and each gets its own.
    public static func sessionProfileCommand() -> String {
        let stub = #"[ -r "$HOME/\#(sessionEnvRelativePath)" ] && . "$HOME/\#(sessionEnvRelativePath)""#
        return [
            "if [ -d /etc/profile.d ]; then",
            #"  printf '%s\n' '# MSL session: Linux GUI apps open as windows on your Mac.' '\#(stub)' > /etc/profile.d/00-msl-session.sh 2>/dev/null || true"#,
            "fi",
            // zsh does not read /etc/profile on Debian, Ubuntu or Arch.
            "if command -v zsh >/dev/null 2>&1; then",
            #"  if [ -d /etc/zsh ]; then msl_zshenv=/etc/zsh/zshenv; else msl_zshenv=/etc/zshenv; fi"#,
            #"  grep -qs 'MSL session' "$msl_zshenv" || printf '%s\n' '# MSL session' '\#(stub)' >> "$msl_zshenv" 2>/dev/null || true"#,
            "fi",
        ].joined(separator: "\n")
    }

    /// Writes the per-user session environment that shells source.
    ///
    /// Run **as the user**, into their own home, so no privilege is needed
    /// and several accounts on one guest do not share a file. Rewritten on
    /// every session (`startTunnel` calls it), which is what keeps it in step
    /// with the experimental settings - switch the file picker off on the
    /// Mac and the next shell has it off too.
    ///
    /// The body is the same `sessionCoreLines` an application gets, so a
    /// program behaves identically whether it was started from the
    /// Applications tab or typed at a prompt. It is written through a quoted
    /// heredoc, so nothing in it expands while being written.
    public static func sessionEnvFileCommand(settings: MSLExperimentalSettings) -> String {
        let body = (sessionCoreLines(settings: settings) + kitEnvLines(menuBridgeFor: nil)
                    + terminalShellLines())
            .joined(separator: "\n")
        return #"""
        msl_env="$HOME/\#(sessionEnvRelativePath)"
        mkdir -p "$(dirname "$msl_env")" 2>/dev/null || true
        cat > "$msl_env.new" <<'MSL_SESSION_ENV_EOF' 2>/dev/null && mv -f "$msl_env.new" "$msl_env" 2>/dev/null || rm -f "$msl_env.new" 2>/dev/null
        # Written by MSL on every session - edits here are lost.
        # Sourced by /etc/profile.d/00-msl-session.sh so that a Linux app
        # typed at a prompt gets exactly what one started from MSL gets.
        \#(body)
        MSL_SESSION_ENV_EOF
        """#
    }

    /// Shell conveniences for an interactive session, as opposed to things
    /// a program needs.
    ///
    /// ## Why `clear` needs help
    ///
    /// `clear` erases the screen and leaves the scrollback, so scrolling up
    /// shows everything it was supposed to have got rid of. That is not
    /// MSL's bug exactly - it is what the guest's `clear` emits - but it is
    /// wrong for the terminal it lands in. Measured in a guest:
    ///
    /// ```
    /// $ clear | od -c
    /// 0000000 033   [   H 033   [   J
    /// ```
    ///
    /// Home, then erase-in-display with no parameter. Nothing that touches
    /// the scrollback. The sequence for that is `ESC[3J`, which ncurses
    /// sends from the `E3` capability - but on Alpine and every other
    /// busybox distro `clear` is a busybox applet that hardcodes those six
    /// bytes and never reads terminfo at all:
    ///
    /// ```
    /// /usr/bin/clear -> /bin/busybox
    /// ```
    ///
    /// So no terminfo change could fix it there. A shell function can, and
    /// it behaves the same on every distro whether `clear` is busybox or
    /// ncurses.
    ///
    /// ## The order is the whole trick
    ///
    /// `ESC[H ESC[2J ESC[3J` - screen first, scrollback last. ncurses does
    /// the opposite (it sends `E3` *before* the clear), and that order is
    /// wrong for Terminal.app, which is most of MSL's users: its `ESC[2J`
    /// **pushes the visible screen into the scrollback**, so clearing the
    /// scrollback first just means `2J` puts the last screenful straight
    /// back. Measured against Terminal.app's own `history`, with Cmd+K
    /// (its built-in Clear Scrollback) as the reference:
    ///
    /// ```
    /// Cmd+K                     lines=25    numbers left=0
    /// ESC[3J ESC[H ESC[2J       lines=49    numbers left=4   <- ncurses order
    /// ESC[H ESC[2J ESC[3J       lines=25    numbers left=0   <- this one
    /// ESC c (full reset)        lines=303   numbers left=0
    /// ```
    ///
    /// So a distro with proper ncurses `clear` would have left leftovers in
    /// Terminal.app too - this is not only a busybox problem. Putting `3J`
    /// last is correct everywhere: a terminal whose `2J` does not touch the
    /// scrollback is unaffected by the order, and one whose `2J` does needs
    /// exactly this.
    ///
    /// It has to live *here*, in the file a login shell sources, and not in
    /// `TerminalProfile.exports`: those run before `exec "$SHELL" -l`, and
    /// an `exec` keeps exported variables but discards functions. The
    /// variable is how the two halves meet - the Mac side sets
    /// `MSL_CLEAR_SCROLLBACK` only for terminals known to handle `ESC[3J`,
    /// and this reads it back.
    ///
    /// `Ctrl-L` is deliberately left alone. It erases the screen and keeps
    /// the scrollback in Terminal.app too, so matching `clear` to the Mac
    /// while leaving `Ctrl-L` as it is gives the same two behaviours people
    /// already have.
    /// Terminal types that handle `ESC[3J`. Everything xterm-derived does,
    /// which is very nearly everything - but not `linux`, `vt100` or `dumb`,
    /// and those are exactly the ones MSL must not make claims about.
    ///
    /// Consulted as well as `MSL_CLEAR_SCROLLBACK` so that `msl ssh` is
    /// covered too: an ssh session takes `TERM` straight from the Mac's
    /// terminal and never passes through `TerminalProfile`, so the variable
    /// is not there to read.
    static let scrollbackClearingTerms = [
        "xterm*", "screen*", "tmux*", "vte*", "alacritty*", "foot*",
        "ghostty*", "wezterm*", "rxvt-unicode*", "contour*", "kitty*",
    ]

    static func terminalShellLines() -> [String] {
        [
            "# `clear` only erases the screen; ESC[3J is what discards the",
            "# scrollback. See GuestIntegration.terminalShellLines().",
            #"msl_clear_3j="${MSL_CLEAR_SCROLLBACK-}""#,
            #"if [ -z "$msl_clear_3j" ]; then"#,
            #"  case "${TERM-}" in"#,
            "    \(scrollbackClearingTerms.joined(separator: "|"))) msl_clear_3j=1 ;;",
            "  esac",
            "fi",
            #"if [ -n "$msl_clear_3j" ]; then"#,
            // `\033` rather than `\e`: dash and busybox printf do not know
            // `\e`, and this file is sourced by whatever shell the person
            // happens to use.
            "  clear() { printf '\(TerminalClear.shellEscapes)'; }",
            "fi",
            "unset msl_clear_3j",
        ]
    }

    /// The line in front of a one-shot command from `msl <instance> <cmd>`.
    ///
    /// shellinit runs those as `sh -c`, not a login shell, so the profile
    /// line above never runs for them - and `msl debian gnome-chess` is the
    /// most natural way there is to open a Linux app from a Mac terminal.
    public static func oneShotDisplayPrefix() -> String {
        // The same file a login shell sources, so `msl <instance> chromium`
        // and typing `chromium` inside `msl <instance>` behave the same. The
        // two lines after it are the fallback for the moment before the file
        // exists - a very first command, on a guest MSL has not set up yet.
        #"""
        [ -r "$HOME/\#(sessionEnvRelativePath)" ] && . "$HOME/\#(sessionEnvRelativePath)"
        [ -n "${DISPLAY-}" ] || export DISPLAY=\#(display)
        \#(appPathLine)

        """#
    }

    /// Where distros put programs that a non-login `sh -c` can't see.
    ///
    /// Debian and Ubuntu install games in `/usr/games` (gnome-chess,
    /// aisleriot), which only a *login* shell's PATH carries. Apps launched
    /// from MSL run through shellinit's plain `sh -c`, so their `.desktop`
    /// `Exec=gnome-chess` failed with exit 127 while typing the same word at
    /// a prompt worked (2026-09-16). Flatpak and snap export their launchers
    /// to directories that are likewise only on a login PATH.
    /// The kit's own `bin` is on there too, so `msl-file-picker` can be
    /// called by name from a script, a `.desktop` action or an app's "choose
    /// a file" hook. Shipping a command nobody can reach is not shipping it.
    static let appPathLine =
        #"export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:/usr/local/games:/usr/games:/var/lib/flatpak/exports/bin:/snap/bin:$HOME/\#(directory)/bin""#

    /// The full guest command that runs `command` as an MSL-launched app:
    /// on MSL's display, with the kit's handlers in front when the kit is
    /// installed, with the menu bridge already on its session bus when the
    /// global menu bar is on.
    /// Everything a Linux GUI application needs, before the application.
    ///
    /// Shared with the *shell* path on purpose. A terminal inside the guest
    /// used to get only `DISPLAY` - and not even that, see
    /// `sessionProfileCommand` - so `chromium` typed at a prompt died on
    /// "Failed to connect to the bus" and "Missing X server", while the same
    /// app started from the Applications tab worked. Two ways of starting the
    /// same program must not set up two different worlds, so both build their
    /// environment from this one list.
    static func sessionCoreLines(settings: MSLExperimentalSettings) -> [String] {
        [
            "export DISPLAY=\(display)",
            appPathLine,
            runtimeDirLines,
            sessionBusLines,
            portalLines(colorScheme: colorSchemeValue),
            filePortalLines(enabled: settings.preferMSLFiles),
            signInBrowserLines(enabled: settings.signInInLinuxBrowser),
            audioLines,
            softwareRenderingLines,
        ]
    }

    /// The kit's own handlers, when the kit is installed.
    ///
    /// `menuBridgeFor` is the command whose menus should be exported, or nil
    /// for a shell - a shell has no menus of its own, and the bridge is
    /// started per application.
    static func kitEnvLines(menuBridgeFor command: String?) -> [String] {
        var lines: [String] = [
            #"MSL_D="$HOME/\#(directory)""#,
            #"if [ -f "$MSL_D/.stamp" ]; then"#,
            #"  export MSL_ORIG_XDG_DATA_DIRS="${XDG_DATA_DIRS-}" MSL_ORIG_XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS-}""#,
            // Flatpak's own export directories included: without them the
            // guest session cannot see Flatpak apps' icons or desktop
            // entries, which is what `flatpak run` warns about on every
            // launch ("applications installed by Flatpak may not appear").
            #"  export XDG_DATA_DIRS="$MSL_D/share:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}""#,
            #"  export XDG_CONFIG_DIRS="$MSL_D/config:${XDG_CONFIG_DIRS:-/etc/xdg}""#,
        ]
        if let command { lines.append(menuBridgeLines(for: command)) }
        lines.append("fi")
        return lines
    }

    /// Takes the INSTANCE and resolves the app's per-app settings itself.
    ///
    /// Both of those lookups used to happen at the call sites, and when a
    /// custom launch command was added only one of the two sites got it -
    /// so the override worked from MSL.app and was silently ignored by
    /// `msl gui-native`. Resolving here means a new per-app setting cannot
    /// be half-wired: there is one place that turns "this app" into "this
    /// command".
    /// `graphics` is only for callers that already hold a mode (tests, and
    /// anything deciding one itself); left nil it is read from the store
    /// like everything else.
    public static func launchCommand(_ command: String, instance: String,
                                     settings: MSLExperimentalSettings,
                                     graphics: AppGraphicsMode? = nil) -> String {
        // Both keyed by the app's ORIGINAL command, so replacing what runs
        // does not orphan its graphics choice.
        let graphics = graphics ?? AppGraphicsStore.mode(instance: instance, command: command)
        let command = AppCustomCommandStore.effectiveCommand(instance: instance, command: command)
        var lines = sessionCoreLines(settings: settings)
        // GPU acceleration only when the host both wants it and can serve
        // it - otherwise the guest must stay on the CPU path (see
        // `gpuAccelerationLines`). "Wants it" is the app's own choice from
        // its right-click menu, falling back to the Experimental switch.
        if graphics.usesGPU(globalSwitch: settings.gpuAcceleration,
                            rendererInstalled: GPUBridge.locateRenderer() != nil) {
            lines.append(gpuLines(for: command))
        } else if graphics == .cpu {
            // Said outright, so an app someone pinned to the CPU can't be
            // steered onto the GPU by an environment inherited from elsewhere.
            lines.append("export GALLIUM_DRIVER=llvmpipe")
        }
        lines += kitEnvLines(menuBridgeFor: settings.globalMenuBar ? command : nil)
        // Snap's confinement check looks at the launching process's cgroup:
        // started straight from MSL's service it sees
        // "/system.slice/shellinit.service is not a snap cgroup" and
        // refuses. A transient user scope puts the app where a desktop
        // session would have put it. Nothing else depends on it, so a guest
        // without systemd simply runs the command as before.
        lines.append(#"""
        if command -v systemd-run >/dev/null 2>&1 \
           && [ -S "${XDG_RUNTIME_DIR-}/bus" ] \
           && systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
            # The scope starts from the user manager's environment, not
            # from this shell's, so everything set above has to be handed
            # over by name. Found the hard way: the Snap calculator opened
            # a window and drew nothing, because GSK_RENDERER never reached
            # it and GTK4 fell back to a GL renderer that cannot work here.
            exec systemd-run --user --scope --quiet -- env \
                DISPLAY="$DISPLAY" \
                PATH="$PATH" \
                HOME="$HOME" \
                GSK_RENDERER="${GSK_RENDERER-}" \
                QT_QUICK_BACKEND="${QT_QUICK_BACKEND-}" \
                LD_PRELOAD="${LD_PRELOAD-}" \
                XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" \
                DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS-}" \
                XDG_DATA_DIRS="${XDG_DATA_DIRS-}" \
                XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS-}" \
                GTK_MODULES="${GTK_MODULES-}" \
                UBUNTU_MENUPROXY="${UBUNTU_MENUPROXY-}" \
                sh -c \#(shellQuoted(command))
        fi
        """#)
        lines.append(command)
        return lines.joined(separator: "\n")
    }

    /// `XDG_RUNTIME_DIR`, which normally comes from logind and therefore
    /// does not exist here at all.
    ///
    /// Its absence is not cosmetic: GTK, Qt, Flatpak and D-Bus all put
    /// sockets and caches in it, and Flatpak's document portal is mounted
    /// there ("Can't get document portal mount path" is what a Flatpak app
    /// says when it is missing). `/run/user/<uid>` is the conventional
    /// place, but an unprivileged account usually cannot create it, so a
    /// private directory in `/tmp` is the fallback - same guarantees that
    /// matter here (owned by this user, mode 700, survives the session).
    /// The guest's sound device, set up for the whole session rather than
    /// only for apps MSL launches.
    ///
    /// `audioLines` used to run only in front of an app started from MSL, so
    /// after a fresh boot the default sink was PipeWire's `auto_null` - a
    /// dummy that discards everything - and any game typed at a Terminal
    /// prompt (open-syobon-action, mari0) was silent until something was
    /// launched from the app. Run from `startTunnel`, which every `msl`
    /// session goes through. In a subshell and silenced, so it can never
    /// fail or change the environment of the command it rides with.
    public static var sessionAudioCommand: String {
        "( " + runtimeDirLines + "\n" + sessionBusLines + "\n" + audioLines + "\n) >/dev/null 2>&1 || true"
    }

    public static let runtimeDirLines = #"""
    if [ -z "${XDG_RUNTIME_DIR-}" ]; then
      msl_uid=$(id -u 2>/dev/null || echo 0)
      for msl_rt in "/run/user/$msl_uid" "/tmp/msl-run-$msl_uid"; do
        mkdir -p "$msl_rt" 2>/dev/null || continue
        chmod 700 "$msl_rt" 2>/dev/null
        [ -w "$msl_rt" ] || continue
        export XDG_RUNTIME_DIR="$msl_rt"
        break
      done
    fi
    """#

    /// Gives the Linux account a real systemd user session, as root.
    ///
    /// Two things need one. **Snap** refuses to run outside a user slice:
    /// snap-confine checks the launching process's cgroup and says
    /// "/system.slice/shellinit.service is not a snap cgroup", because MSL
    /// starts apps from its own system service. **Portals** (Flatpak's
    /// document portal, file choosers) expect `/run/user/<uid>`, which only
    /// logind creates.
    ///
    /// `enable-linger` is the supported way to have that session exist
    /// without anyone logging in on a console - exactly MSL's situation.
    /// Harmless and idempotent on a guest without logind: it exits saying
    /// so, and everything falls back to the `/tmp` runtime directory.
    public static func userSessionCommand(user: String) -> String {
        let quoted = shellQuoted(user)
        return """
        set -u
        msl_user=\(quoted)
        command -v loginctl >/dev/null 2>&1 || { echo "MSL-SESSION-NONE"; exit 0; }
        id -u "$msl_user" >/dev/null 2>&1 || { echo "MSL-SESSION-NONE"; exit 0; }
        msl_uid=$(id -u "$msl_user")
        # **Wait for the thing success is judged on.** This used to wait for
        # the session bus socket at /run/user/$uid/bus while deciding the
        # outcome from the directory, and the two do not agree: Fedora makes
        # the directory and never that socket - it has dbus-1/ and MSL's own
        # msl-dbus-1001 instead - so every single guest command sat here for
        # the full five seconds and then succeeded anyway. Measured on this
        # Mac: 5.25s per command on Fedora against 0.12s on Alpine, and every
        # app launch from the Applications tab paid it.
        #
        # Nothing needed that socket in any case; MSL supplies the session bus
        # itself. So the wait exists only for the case it was written for - a
        # runtime directory that is not there yet on a first start - and ends
        # the moment it appears.
        if [ ! -d "/run/user/$msl_uid" ]; then
            loginctl enable-linger "$msl_user" >/dev/null 2>&1 || true
            msl_i=0
            while [ $msl_i -lt 25 ] && [ ! -d "/run/user/$msl_uid" ]; do
                sleep 0.2
                msl_i=$((msl_i + 1))
            done
        fi
        if [ -d "/run/user/$msl_uid" ]; then echo "MSL-SESSION-OK"; else echo "MSL-SESSION-NONE"; fi
        """
    }

    /// Toolkits that insist on a GPU, told to draw in software.
    ///
    /// Without GLX/DRI3 a GTK4 app asks for a GL renderer,
    /// is refused, and - inside a Flatpak sandbox especially - exits
    /// immediately rather than falling back. The Flatpak GNOME Calculator
    /// did exactly that: it reached the display, printed nothing useful,
    /// and quit with code 1. With `GSK_RENDERER=cairo` the same command
    /// opens its window.
    ///
    /// Both are set only when unset, so anyone who wants to try the GL
    /// path (or has a reason to) still can. mslgd now has GLX, and with the
    /// `gpuAcceleration` flag on, `gpuAccelerationLines` below routes GL to
    /// the Mac's GPU through `virpipe` - Chromium and Blender then run
    /// accelerated. GTK4 is kept on cairo regardless, on purpose: its GL
    /// path over our young GLX is untested and it does not need it.
    ///
    /// The third line is not a renderer choice but a repair for the one GL
    /// path that does work here: Mesa's software EGL on X11. It seeds a
    /// window surface's height once, when the surface is made, and clamps
    /// every upload to it - and Qt makes its top-level windows at 640x480
    /// before layout, so a Krita window that grows to 912 rows kept
    /// repainting only the first 480 and showed its welcome page underneath
    /// the document forever. `msl-eglsize.so` (Guest/init/msl-eglsize.c)
    /// asks for the surface's size before each swap, which is what makes
    /// Mesa refresh it. It is inert in any process that never swaps an EGL
    /// surface, and only added when the image actually carries it.
    ///
    /// The alternative was pushing Krita onto its software canvas, which
    /// cured the strip and broke the brush outline: that canvas draws it
    /// client-side with an XOR pen, which comes out as a dotted magenta
    /// ring. The GL canvas draws it clean.
    static let softwareRenderingLines = #"""
    [ -n "${GSK_RENDERER-}" ] || export GSK_RENDERER=cairo
    [ -n "${QT_QUICK_BACKEND-}" ] || export QT_QUICK_BACKEND=software
    if [ -r /usr/local/lib/msl-eglsize.so ]; then case ":${LD_PRELOAD-}:" in *:/usr/local/lib/msl-eglsize.so:*) ;; *) export LD_PRELOAD="/usr/local/lib/msl-eglsize.so${LD_PRELOAD:+:$LD_PRELOAD}" ;; esac; fi
    """#

    /// Route Linux GL apps to the Mac's GPU, when it is enabled and safe.
    ///
    /// This turns the `virpipe` Gallium driver on for the launched app, so
    /// its OpenGL goes over vsock to `virgl_test_server` on the Mac (see
    /// `GPUBridge`) instead of the guest's CPU. It is what makes a Chromium
    /// GL window, Blender, or `glxgears` render on the real GPU. GTK4 stays
    /// on `GSK_RENDERER=cairo` deliberately - its GL path over our young
    /// GLX is untested, and the apps that want the GPU (Chromium, Blender)
    /// drive GL directly through GLX/EGL, not through GSK.
    ///
    /// **Two guards, both essential:**
    /// - It is only emitted when the host has the flag on AND a renderer
    ///   installed (`GPUBridge.locateRenderer`), so guest and host never
    ///   disagree - `GALLIUM_DRIVER=virpipe` with nothing listening breaks
    ///   every GL app rather than falling back.
    /// - In the guest it starts the tunnel only if `x11tunnel` understands
    ///   `--socket-path`. An older one would bind a *display* socket
    ///   instead (see `02-IMAGE-REBUILD-SG.md`), so on today's images this
    ///   finds no support, does nothing, and apps stay on llvmpipe - the
    ///   safe pre-existing behaviour. It activates itself once the rebuilt
    ///   images ship the current tunnel.
    /// `gpuAccelerationLines`, skipped for a Snap.
    ///
    /// A strictly confined snap has its own private `/tmp`, so it can never
    /// see `/tmp/.virgl_test`: told to use `virpipe` anyway, its Mesa found no
    /// renderer and aborted ("lost connection to rendering server") before a
    /// window ever opened - mari0 did exactly that. On the CPU it runs.
    static func gpuLines(for command: String) -> String {
        guard let program = programName(in: command) else { return gpuAccelerationLines }
        // A Flatpak is the same trap as a snap and worse, because the
        // launcher is an ordinary `/usr/bin/flatpak` - only what it *runs*
        // is sandboxed. The app inside gets its own /tmp and never sees
        // /tmp/.virgl_test, so `GALLIUM_DRIVER=virpipe` makes Mesa abort
        // before a window ever opens: "lost connection to rendering server",
        // exit 134 (SIGABRT). Reported live for the Flatpak Calculator,
        // 2026-09-28.
        if program == "flatpak" || program.hasSuffix("/flatpak") { return "" }
        return "case \"$(command -v \(shellQuoted(program)) 2>/dev/null)\" in\n"
            + "/snap/*|/var/lib/flatpak/*|*/.local/share/flatpak/*) ;;\n*)\n"
            + gpuAccelerationLines + "\n;;\nesac"
    }

    /// The program a launch command runs: the first word that isn't `env`
    /// or a `NAME=value` assignment, with Exec-style quotes removed.
    static func programName(in command: String) -> String? {
        for word in command.split(whereSeparator: \.isWhitespace) {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if token.isEmpty || token == "env" || token.contains("=") { continue }
            return token
        }
        return nil
    }

    static let gpuAccelerationLines = #"""
    msl_tunnel_bin=$(command -v x11tunnel 2>/dev/null || echo /usr/local/bin/x11tunnel)
    if [ -x "$msl_tunnel_bin" ] && grep -q -- --socket-path "$msl_tunnel_bin" 2>/dev/null; then
        if [ ! -S /tmp/.virgl_test ]; then
            setsid "$msl_tunnel_bin" 0 5011 --socket-path /tmp/.virgl_test </dev/null >/dev/null 2>&1 &
            msl_n=0; while [ ! -S /tmp/.virgl_test ] && [ "$msl_n" -lt 20 ]; do msl_n=$((msl_n+1)); sleep 0.1; done
        fi
        if [ -S /tmp/.virgl_test ]; then
            export GALLIUM_DRIVER=virpipe
            export LIBGL_ALWAYS_SOFTWARE=1
        fi
    fi
    """#

    /// A D-Bus session bus for every launched app, not just the ones using
    /// the menu bridge.
    ///
    /// GTK4, Qt and every Flatpak expect a session bus and try to start one
    /// themselves through `dbus-launch --autolaunch`, which needs an X11
    /// session manager MSL does not run. Amberol (a Flatpak, GTK4) died on
    /// exactly that: "Unable to acquire session bus ... Child process exited
    /// with code 1". `msl-session` already knew how to start a bus, but only
    /// ran when the global menu bar experiment was on, so every other app
    /// was left without one.
    ///
    /// One bus per boot, shared by every app, rather than one each: single-
    /// instance apps, portals and the menu bridge all depend on two apps
    /// agreeing on the same bus. The address is remembered in the runtime
    /// directory and reused while its socket is still there.
    static let sessionBusLines = #"""
    # logind's own user bus, when there is a real user session. Sharing it
    # matters: snap, portals and the menu bridge all expect to find each
    # other on the session's bus, not on a private one MSL started.
    if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && [ -S "/run/user/$(id -u 2>/dev/null || echo 0)/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
    # Whether a session bus address actually answers. Uses whichever client
    # the guest has; with neither, it falls back to trusting the socket file,
    # which is what every guest did before this existed.
    msl_bus_answers() {
      if command -v gdbus >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS="$1" gdbus call --session \
          --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
          --method org.freedesktop.DBus.GetId >/dev/null 2>&1
      elif command -v dbus-send >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS="$1" dbus-send --session \
          --dest=org.freedesktop.DBus --print-reply \
          /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1
      else
        return 0
      fi
    }
    msl_bus_file="${XDG_RUNTIME_DIR:-/tmp}/msl-dbus-$(id -u 2>/dev/null || echo 0)"
    if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && [ -s "$msl_bus_file" ]; then
      msl_bus=$(cat "$msl_bus_file" 2>/dev/null)
      msl_sock=${msl_bus#unix:path=}
      msl_sock=${msl_sock%%,*}
      # **A socket file outlives the daemon that made it.** `-S` says only
      # that the path is a socket, not that anything is listening - so an
      # instance that was suspended, or whose bus died, left this file
      # behind and every launch afterwards adopted an address that answers
      # "Connection refused". Everything built on the session bus then
      # quietly failed: portals, snap, and the menu bridge, which was
      # respawned and died on every single app launch. Same trap as the X11
      # display socket, which can exist, look listening, and refuse
      # everything.
      #
      # So the bus is asked whether it is really there. If it is not, the
      # stale address is thrown away and a fresh daemon is started below.
      if [ -S "$msl_sock" ] && msl_bus_answers "$msl_bus"; then
        export DBUS_SESSION_BUS_ADDRESS="$msl_bus"
      else
        rm -f "$msl_bus_file" 2>/dev/null
      fi
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v dbus-daemon >/dev/null 2>&1; then
      msl_bus=$(dbus-daemon --session --fork --print-address 2>/dev/null)
      if [ -n "$msl_bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="$msl_bus"
        printf '%s' "$msl_bus" > "$msl_bus_file" 2>/dev/null
      fi
    fi
    """#

    /// Gives the session a sound device and a microphone, once.
    ///
    /// The microphone is the same trick reversed: `mslpsd --stream
    /// audio-in` feeds a FIFO that `module-pipe-source` reads, and it feeds
    /// silence whenever the Mac is not sending, so "MSL Microphone" always
    /// delivers audio. Real samples need the person's yes in MSL
    /// Peripherals, which `mslpsd` asks for when it sees an app recording.
    ///
    /// The guest has no sound card - see `READMES/09-MSLPS.md` for why -
    /// so this makes one out of a pipe: `mslpsd` holds a FIFO and carries
    /// whatever lands in it to the Mac, and the audio server is given a
    /// sink that writes there. Applications see an ordinary default sink
    /// called MSL.
    ///
    /// Order matters. `mslpsd` starts first because it creates the FIFO and
    /// keeps a reader on it; a sink whose pipe nobody drains stalls the
    /// application playing into it, which is the one failure worth
    /// designing against here.
    static let audioLines = #"""
    msl_audio_fifo="${XDG_RUNTIME_DIR:-/tmp}/mslps-audio-out"
    msl_audio_pid="${XDG_RUNTIME_DIR:-/tmp}/mslps-audio-out.pid"
    if [ -x /usr/local/bin/mslpsd ] && ! kill -0 "$(cat "$msl_audio_pid" 2>/dev/null)" 2>/dev/null; then
      setsid /usr/local/bin/mslpsd --stream audio-out --fifo "$msl_audio_fifo" </dev/null >/dev/null 2>&1 &
      echo $! > "$msl_audio_pid"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -S "${XDG_RUNTIME_DIR-}/bus" ]; then
      systemctl --user start pipewire pipewire-pulse wireplumber >/dev/null 2>&1
    fi
    if command -v pactl >/dev/null 2>&1 \#
        && [ -x /usr/local/bin/mslpsd ] \#
        && ! pactl list short sinks 2>/dev/null | grep -q "	msl	"; then
      pactl load-module module-pipe-sink file="$msl_audio_fifo" sink_name=msl \#
        sink_properties=device.description=MSL format=s16le rate=48000 channels=2 >/dev/null 2>&1
      pactl set-default-sink msl >/dev/null 2>&1
    fi
    msl_mic_fifo="${XDG_RUNTIME_DIR:-/tmp}/mslps-audio-in"
    msl_mic_pid="${XDG_RUNTIME_DIR:-/tmp}/mslps-audio-in.pid"
    if [ -x /usr/local/bin/mslpsd ] && ! kill -0 "$(cat "$msl_mic_pid" 2>/dev/null)" 2>/dev/null; then
      setsid /usr/local/bin/mslpsd --stream audio-in --fifo "$msl_mic_fifo" </dev/null >/dev/null 2>&1 &
      echo $! > "$msl_mic_pid"
    fi
    if command -v pactl >/dev/null 2>&1 \#
        && [ -x /usr/local/bin/mslpsd ] \#
        && ! pactl list short sources 2>/dev/null | grep -q "	msl_mic	"; then
      pactl load-module module-pipe-source file="$msl_mic_fifo" source_name=msl_mic \#
        source_properties='device.description="MSL Microphone"' format=s16le rate=48000 channels=2 >/dev/null 2>&1
      pactl set-default-source msl_mic >/dev/null 2>&1
    fi
    """#

    /// Starts MSL's Settings portal, once per session.
    ///
    /// Without it every GTK4 app waits out D-Bus's 25-second timeout before
    /// it draws - see `portalPython`. One process per session, tracked by a
    /// pidfile the same way the display tunnel is.
    static func portalLines(colorScheme: Int) -> String {
        #"""
        msl_portal_pid="${XDG_RUNTIME_DIR:-/tmp}/msl-portal-$(id -u 2>/dev/null || echo 0).pid"
        # Left where a D-Bus-activated portal can find it: that one inherits
        # the bus's environment, not this script's, so the variable below
        # never reaches it. See `portalService`.
        printf '%s\n' \#(colorScheme) > "$HOME/\#(directory)/.color-scheme" 2>/dev/null || true
        if [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] \#
            && [ -f "$HOME/\#(directory)/bin/msl_portal.py" ] \#
            && command -v python3 >/dev/null 2>&1 \#
            && ! kill -0 "$(cat "$msl_portal_pid" 2>/dev/null)" 2>/dev/null; then
          MSL_COLOR_SCHEME=\#(colorScheme) setsid python3 "$HOME/\#(directory)/bin/msl_portal.py" \#
            </dev/null >/dev/null 2>&1 &
          echo $! > "$msl_portal_pid"
        fi
        """#
    }

    /// Tells the toolkits to route their file dialogs through the portal.
    ///
    /// **This is the half that is easy to forget.** Implementing
    /// `org.freedesktop.portal.FileChooser` does nothing on its own: a
    /// toolkit only asks a portal when it is sandboxed or explicitly told
    /// to.
    ///
    /// **Four levers, because no single one reaches every toolkit.** Each was
    /// measured against a real app on 2026-09-29:
    ///
    /// - **Flatpaks and snaps** need nothing: they are sandboxed, so their
    ///   toolkits always ask the portal. Verified.
    /// - **Firefox** has its own pref, written by `msl-firefox-portal` below.
    ///   Its default is "only when sandboxed" and MSL's Firefox is not, so
    ///   without it Firefox draws its own GTK dialog whatever the portal
    ///   offers. `MOZ_ENABLE_XDG_PORTAL_FILE_PICKER` is not enough alone.
    /// - **Qt** is solved the supported way, with Qt's own portal platform
    ///   theme. Verified with FeatherPad (Qt6): its Save As opens MSL Files
    ///   and writes a real guest file. It needs
    ///   `qt5-`/`qt6-xdgdesktopportal-platformtheme` installed, which is why
    ///   the variable is only exported when the plugin is actually present -
    ///   naming a platform theme Qt cannot load makes Qt complain on every
    ///   launch. Guests without it keep their own dialogs.
    /// - **GTK** takes both remaining levers, because the toolkit is split:
    ///   `GTK_USE_PORTAL=1` reaches `GtkFileChooserNative` and GTK4's
    ///   `GtkFileDialog`, but **not** `GtkFileChooserDialog`, which builds
    ///   its chooser in process and never speaks to a portal. That older API
    ///   is still the common case here - both GIMP and Mousepad import it -
    ///   so `msl-gtkpicker.so` covers it by interposing `gtk_dialog_run`.
    ///   See `Guest/init/msl-gtkpicker.c`.
    ///
    /// **`GTK_USE_PORTAL=1` was once recorded here as a dead end. That was
    /// wrong.** The measurement behind it - Mousepad starting and exiting
    /// immediately - was taken while the portal itself was half-built, and
    /// the variable was being blamed for the portal's own failure. Retested
    /// against the finished portal, Mousepad starts normally with it set.
    /// The real limit is narrower and is the one above: it never reaches
    /// `GtkFileChooserDialog`.
    ///
    /// All of it is safe only because `MSLFilesPrewarm` keeps MSL Files
    /// running: an app blocks on the reply, and a cold launch took long
    /// enough that Firefox's IPC timed out and it quit.
    /// Carries "sign-in pages open in Linux" into the guest.
    ///
    /// A file rather than an environment variable, because `msl-open` is the
    /// system's http handler and gets run by things MSL never launched - a
    /// link clicked in a terminal, `xdg-open` from a script - which would
    /// carry none of MSL's environment. The kit's own directory is somewhere
    /// every one of those can read.
    static func signInBrowserLines(enabled: Bool) -> String {
        let marker = #""$HOME/\#(directory)/.signin-browser""#
        return enabled
            ? "mkdir -p \"$HOME/\(directory)\" 2>/dev/null && : > \(marker) 2>/dev/null || true"
            : "rm -f \(marker) 2>/dev/null || true"
    }

    static func filePortalLines(enabled: Bool) -> String {
        guard enabled else {
            // Explicitly off rather than merely unset: a stale value in the
            // user's own profile would otherwise keep the portal in play
            // after the toggle was turned off.
            return #"""
            unset GTK_USE_PORTAL MSL_GTK_PICKER 2>/dev/null || true
            "$HOME/\#(directory)/bin/msl-firefox-portal" off >/dev/null 2>&1 || true
            """#
        }
        return #"""
        export GTK_USE_PORTAL=1
        unset MOZ_DISABLE_XDG_PORTAL_FILE_PICKER 2>/dev/null || true
        "$HOME/\#(directory)/bin/msl-firefox-portal" on >/dev/null 2>&1 || true
        # Qt's own portal theme, but only when the plugin is really there:
        # naming a theme Qt cannot load makes it complain on every launch.
        if [ -z "${QT_QPA_PLATFORMTHEME-}" ]; then
            for msl_qt in /usr/lib/*/qt6/plugins/platformthemes/libqxdgdesktopportal.so \
                          /usr/lib/*/qt5/plugins/platformthemes/libqxdgdesktopportal.so \
                          /usr/lib/qt6/plugins/platformthemes/libqxdgdesktopportal.so \
                          /usr/lib/qt5/plugins/platformthemes/libqxdgdesktopportal.so; do
                if [ -r "$msl_qt" ]; then export QT_QPA_PLATFORMTHEME=xdgdesktopportal; break; fi
            done
            unset msl_qt
        fi
        # The GtkFileChooserDialog half, which no portal can reach. Only
        # preloaded when the kit managed to build it - see `installCommand`.
        msl_gtkpick="$HOME/\#(directory)/lib/msl-gtkpicker.so"
        if [ -r "$msl_gtkpick" ]; then
            export MSL_GTK_PICKER=1
            case ":${LD_PRELOAD-}:" in
                *:"$msl_gtkpick":*) ;;
                *) export LD_PRELOAD="$msl_gtkpick${LD_PRELOAD:+:$LD_PRELOAD}" ;;
            esac
        fi
        unset msl_gtkpick
        """#
    }

    /// Starts `x11tunnel` in the guest for `display`, unless it is already
    /// running.
    ///
    /// **Why the paths carry a uid.** The pidfile and log used to be
    /// `/tmp/x11tunnel-1-5003.pid` and `/tmp/x11tunnel-native.log`, fixed
    /// names in a shared directory. MSL used to run everything as root, so
    /// those files are owned by root - including inside the shipped images,
    /// where the build left them behind. From v2 apps run as the user, who
    /// then cannot write either file, and every single launch failed with
    /// "Permission denied" before a window ever appeared. Naming them per
    /// user means the old files are simply irrelevant.
    ///
    /// **Why liveness is not only the pidfile.** A tunnel started by root
    /// (a `-u root` session, or an older MSL) is a perfectly good tunnel -
    /// the display socket is world-writable - but its pidfile is not ours
    /// to read. Starting a second one would fail on the bound socket, so a
    /// process check comes first, and it walks `/proc` matching on each
    /// process's `exe` link. Command-line matching cannot work here: this
    /// script's own text contains the command line it is looking for.
    /// Clears what a dead tunnel left behind, as root.
    ///
    /// `x11tunnel` unlinks its own stale socket before binding, but
    /// `/tmp/.X11-unix` is sticky: a socket left by a tunnel that ran as
    /// root cannot be removed by the user, so the bind fails with "Address
    /// already in use" and no app can start. The shipped images contain
    /// exactly that, left by the build. Only ever run after a start has
    /// already failed: by then the display is known to be unusable, so any
    /// tunnel still holding it is cleared out too rather than protected.
    public static func tunnelCleanupCommand(display: Int, port: Int) -> String {
        """
        msl_kill=""
        for msl_p in /proc/[0-9]*; do
            msl_exe=$(readlink "$msl_p/exe" 2>/dev/null) || continue
            case "$msl_exe" in */x11tunnel) ;; *) continue ;; esac
            msl_args=$(tr '\\0' ' ' < "$msl_p/cmdline" 2>/dev/null)
            case "$msl_args" in *" \(display) \(port) "*) msl_kill="$msl_kill ${msl_p#/proc/}" ;; esac
        done
        # Any tunnel still holding this display goes too. This runs only
        # after a start has already failed, which now means the display is
        # genuinely unusable - a surviving process there is the thing in the
        # way, not something to protect. (It used to bail out on finding
        # one, which left a root-owned dead socket that nobody could clear.)
        [ -n "$msl_kill" ] && kill $msl_kill 2>/dev/null
        rm -f /tmp/.X11-unix/X\(display) /tmp/x11tunnel-\(display)-\(port).pid \
              /tmp/x11tunnel-native.log /tmp/x11tunnel.log 2>/dev/null
        echo "MSL-TUNNEL-CLEARED"
        """
    }

    public static func tunnelStartCommand(display: Int, port: Int, announce: Bool) -> String {
        let flags = announce ? " --announce" : ""
        let tag = "\(display)-\(port)"
        return runtimeDirLines + "\n" + #"""
        msl_tunnel_dir="${XDG_RUNTIME_DIR:-/tmp}"
        msl_pidfile="$msl_tunnel_dir/msl-x11tunnel-$(id -u 2>/dev/null || echo 0)-\#(tag).pid"
        msl_tunnel_log="$msl_tunnel_dir/msl-x11tunnel-$(id -u 2>/dev/null || echo 0)-\#(tag).log"
        msl_tunnel_socket=/tmp/.X11-unix/X\#(display)
        # Leftovers from when MSL ran as root, including the ones the image
        # build itself left in /tmp. Removed when we are allowed to; ignored
        # when we are not.
        rm -f /tmp/x11tunnel-\#(tag).pid /tmp/x11tunnel-native.log /tmp/x11tunnel.log 2>/dev/null

        # Every pid whose /proc/<pid>/exe really is the tunnel for this
        # display. Matching on exe rather than on the command line, because
        # this script's own text names that command line and a command-line
        # search finds itself.
        msl_tunnel_pids() {
            for msl_p in /proc/[0-9]*; do
                msl_exe=$(readlink "$msl_p/exe" 2>/dev/null) || continue
                case "$msl_exe" in */x11tunnel) ;; *) continue ;; esac
                msl_args=$(tr '\0' ' ' < "$msl_p/cmdline" 2>/dev/null)
                case "$msl_args" in *" \#(display) \#(port) "*) echo "${msl_p#/proc/}" ;; esac
            done
        }

        # A running process is not the same as a usable display. A second
        # tunnel started by another MSL path unlinks the socket before
        # binding its own, and if that one then dies the first process is
        # still alive while nothing is listening on the path clients use.
        # That is exactly what "x11tunnel ready" followed by "Failed to
        # open display" was: a liveness check that believed a pid.
        msl_tunnel_usable() {
            [ -S "$msl_tunnel_socket" ] || return 1
            [ -n "$(msl_tunnel_pids)" ] || return 1
            # And the socket at that path has to be the one the live tunnel
            # is listening on. A second tunnel unlinks the path and binds a
            # socket of its own; kill that one and the FILE stays behind,
            # pointing at a dead socket, while the first tunnel is still
            # alive and still listed as listening - on an inode nothing can
            # reach any more. Every check made of a pid, the file, or even
            # /proc/net/unix says "ready"; every client gets ECONNREFUSED
            # ("could not connect to display :1" with a tunnel plainly
            # running, 2026-09-22). Only a connect knows the difference.
            if command -v python3 >/dev/null 2>&1; then
                python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); s.close()' \
                        "$msl_tunnel_socket" 2>/dev/null || return 1
            fi
            return 0
        }

        if ! msl_tunnel_usable; then
            # An orphan holding no socket has to go, or it will keep
            # answering the process check forever.
            msl_orphans=$(msl_tunnel_pids)
            [ -n "$msl_orphans" ] && kill $msl_orphans 2>/dev/null
            # The dead socket too, if this account is allowed to remove it.
            # It usually is; when an earlier tunnel ran as root it is not,
            # and the bind below fails so that the caller can clear it with
            # root's hands (see `tunnelCleanupCommand`).
            rm -f "$msl_tunnel_socket" 2>/dev/null
            setsid sh -c 'exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; exec /usr/local/bin/x11tunnel \#(display) \#(port)\#(flags)' </dev/null >"$msl_tunnel_log" 2>&1 &
            echo $! > "$msl_pidfile"
            msl_tries=0
            while [ $msl_tries -lt 20 ]; do
                msl_tunnel_usable && break
                sleep 0.2
                msl_tries=$((msl_tries + 1))
            done
            if ! msl_tunnel_usable; then
                cat "$msl_tunnel_log" >&2
                echo "x11tunnel did not create $msl_tunnel_socket" >&2
                exit 1
            fi
        fi
        """#
    }

    /// Exposed for the tests, which check that a command with quotes in it
    /// survives every wrapper between MSL and the app.
    public static func shellQuotedForTesting(_ string: String) -> String { shellQuoted(string) }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Handlers

    /// Kept POSIX sh so a guest without python3 still falls through to the
    /// Linux handler rather than failing to open anything.
    static let mslOpenShell = #"""
    #!/bin/sh
    # MSL: hands a link or folder from a Linux app to the Mac.
    # Installed by MSL (GuestIntegration.swift); rewritten on MSL updates.
    if command -v python3 >/dev/null 2>&1; then
        exec python3 "@MSLDIR@/bin/msl_open.py" "$@"
    fi
    shift
    if [ -n "${MSL_ORIG_XDG_DATA_DIRS-}" ]; then export XDG_DATA_DIRS="$MSL_ORIG_XDG_DATA_DIRS"; else unset XDG_DATA_DIRS; fi
    if [ -n "${MSL_ORIG_XDG_CONFIG_DIRS-}" ]; then export XDG_CONFIG_DIRS="$MSL_ORIG_XDG_CONFIG_DIRS"; else unset XDG_CONFIG_DIRS; fi
    exec xdg-open "$1"

    """#

    static let mslOpenPython = #"""
    #!/usr/bin/env python3
    """MSL: asks the Mac to open a link or show a folder.

    usage: msl_open.py url|dir|show TARGET...

    The Mac (mslhd's HostOpenService) answers "ok" when it handled the
    request. Anything else - a "declined", no answer, no vsock - means the
    Linux handler runs instead, with the environment MSL changed put back
    so it cannot land here again.

    Installed by MSL (GuestIntegration.swift); rewritten on MSL updates.
    """
    import json
    import os
    import shutil
    import socket
    import sys
    from urllib.parse import parse_qs, unquote, urlparse

    HOST_CID = 2
    PORT = 5008

    # Written by MSL while "sign-in pages open in Linux" is on.
    SIGNIN_MARKER = "@MSLDIR@/.signin-browser"

    # Checked in order; the first one present wins.
    BROWSERS = ("firefox-esr", "firefox", "chromium", "chromium-browser",
                "google-chrome", "google-chrome-stable", "brave-browser",
                "epiphany", "midori", "falkon")


    def guest_browser():
        """A browser inside Linux, or None."""
        for name in BROWSERS:
            found = shutil.which(name)
            if found:
                return found
        return None


    def looks_like_sign_in(url):
        """Whether this link must finish inside Linux to work at all.

        A sign-in ends by handing its answer back to the machine that
        started it. Opened on the Mac, that answer arrives on the Mac and
        the Linux app waits forever - so these, and only these, stay here.

        Deliberately narrow. Every rule below is something an ordinary link
        never has, because the cost of being wrong is a page opening in the
        guest's browser instead of the person's own.
        """
        try:
            parsed = urlparse(url)
        except ValueError:
            return False
        if parsed.scheme not in ("http", "https"):
            return False
        try:
            query = parse_qs(parsed.query)
        except ValueError:
            return False

        redirect = (query.get("redirect_uri") or query.get("redirect_url") or [""])[0]
        if redirect:
            try:
                back = urlparse(redirect)
            except ValueError:
                back = None
            if back is not None:
                # "Send the answer to this machine's own loopback." The
                # Linux app is listening there; the Mac is not.
                if (back.hostname or "").strip("[]") in ("localhost", "127.0.0.1", "::1"):
                    return True
                # A private scheme (discord://, zoommtg://) is a Linux app
                # saying "hand it back to me". macOS would either find the
                # WRONG app registered for it or nothing at all.
                if back.scheme and back.scheme not in ("http", "https"):
                    return True

        # An OAuth authorisation request, even when the redirect is remote:
        # `client_id` with either a response type or a PKCE challenge is a
        # combination ordinary links do not carry.
        if query.get("client_id") and (query.get("response_type") or query.get("code_challenge")):
            return True
        return False


    def sign_in_stays_in_linux(url):
        """Both halves have to be true, or the Mac opens it as usual."""
        if not os.path.exists(SIGNIN_MARKER):
            return False
        if not looks_like_sign_in(url):
            return False
        # No browser here means the Mac is still the better answer: a page
        # that opens somewhere beats a page that opens nowhere.
        return guest_browser() is not None


    def ask_mac(kind, targets):
        request = {"v": 1, "kind": kind, "targets": targets, "cwd": os.getcwd()}
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            # Attachments are copied before the answer comes back.
            sock.settimeout(120)
            sock.connect((HOST_CID, PORT))
            sock.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n") and len(reply) < 4096:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                reply += chunk
            sock.close()
        except (OSError, AttributeError):
            return False
        return reply.strip() == b"ok"


    def local_path(target):
        if target.startswith("file://"):
            return unquote(urlparse(target).path)
        return target


    def fall_back(kind, targets):
        for name in ("XDG_DATA_DIRS", "XDG_CONFIG_DIRS"):
            original = os.environ.get("MSL_ORIG_" + name, "")
            if original:
                os.environ[name] = original
            else:
                os.environ.pop(name, None)
        target = targets[0]
        if kind == "show":
            # Revealing an item with no file manager to ask: open its folder.
            target = os.path.dirname(local_path(target).rstrip("/")) or "/"
        try:
            os.execvp("xdg-open", ["xdg-open", target])
        except OSError:
            return 1


    def open_here(url):
        """Opens a link in the guest's own browser.

        The browser is run directly rather than through `xdg-open`, because
        MSL *is* this system's http handler: xdg-open would come straight
        back here and the two would bounce a sign-in between them forever.
        """
        browser = guest_browser()
        if not browser:
            return 1
        try:
            os.execv(browser, [browser, url])
        except OSError:
            return 1


    def main(argv):
        if not argv or argv[0] not in ("url", "dir", "show"):
            print("usage: msl_open.py url|dir|show [TARGET...]", file=sys.stderr)
            return 2
        kind, targets = argv[0], argv[1:]
        # `dir` with nothing to open means "start the file manager", which is
        # what the applications-menu entry does: its Exec ends in an optional
        # %u and the menu passes no argument. Landing in the person's Linux
        # home is what every other file manager does from that menu.
        if kind == "dir" and not targets:
            targets = [os.path.expanduser("~") or "/"]
        if not targets:
            print("usage: msl_open.py url|dir|show [TARGET...]", file=sys.stderr)
            return 2
        # A sign-in is asked for before the Mac is, because the Mac cannot
        # finish one - see `looks_like_sign_in`.
        if kind == "url" and sign_in_stays_in_linux(targets[0]):
            return open_here(targets[0])
        if ask_mac(kind, targets):
            return 0
        return fall_back(kind, targets)


    if __name__ == "__main__":
        sys.exit(main(sys.argv[1:]))

    """#

    static let openURLDesktop = #"""
    [Desktop Entry]
    Type=Application
    Name=Open on Mac
    Comment=MSL: opens web and mail links on the Mac
    Exec=@MSLDIR@/bin/msl-open url %u
    NoDisplay=true
    MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/mailto;

    """#

    /// MSL Files as a Linux application in its own right.
    ///
    /// **Not `NoDisplay`.** It used to be hidden, which made MSL Files a
    /// handler rather than an app: it was the default for `inode/directory`,
    /// so "open this folder" reached it, but it was absent from the
    /// applications menu and there was no way to simply *start* the file
    /// manager - the thing every desktop has. MSL Files is the file browser
    /// on both sides of the boundary, so on this side it gets a menu entry
    /// and an icon like any other app.
    ///
    /// `%u` is optional in an Exec line: launched from the menu there is no
    /// argument, and `msl-open dir` with nothing to open now means "my Linux
    /// home", which is where starting a file manager should land you.
    static let filesDesktop = #"""
    [Desktop Entry]
    Type=Application
    Name=MSL Files
    GenericName=File Manager
    Comment=Browse this Linux system and your Mac, in MSL Files
    Exec=@MSLDIR@/bin/msl-open dir %u
    Icon=msl-files
    Terminal=false
    Categories=System;FileManager;Utility;
    MimeType=inode/directory;
    X-MSL-Internal=true

    """#

    /// The menu-entry icon, as SVG because the kit is text.
    ///
    /// The kit travels base64'd inside one `shellinit` EXEC frame, so a real
    /// PNG of the logo (939 KB) could never fit. An SVG is text, every Linux
    /// icon loader reads it, and it scales to whatever size a menu asks for -
    /// so the mark is redrawn here in a few hundred bytes rather than
    /// shipped as pixels.
    static let filesIconSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
      <rect x="4" y="12" width="56" height="44" rx="8" fill="#39b54a"/>
      <path d="M4 20a8 8 0 0 1 8-8h14l6 8H4z" fill="#2d9c3c"/>
      <circle cx="32" cy="36" r="13" fill="#f4f7f2"/>
      <path d="M32 23a13 13 0 0 0-13 13h26a13 13 0 0 0-13-13z" fill="#ff5e5e"/>
      <g fill="#2f3b2f">
        <circle cx="25" cy="31" r="1.4"/><circle cx="32" cy="29.5" r="1.4"/>
        <circle cx="39" cy="31" r="1.4"/>
      </g>
    </svg>

    """#

    static let mimeApps = #"""
    [Default Applications]
    x-scheme-handler/http=msl-open-url.desktop
    x-scheme-handler/https=msl-open-url.desktop
    x-scheme-handler/mailto=msl-open-url.desktop
    inode/directory=msl-files.desktop

    """#

    // MARK: - org.freedesktop.FileManager1

    /// "Open containing folder" in Firefox, Chromium, GTK and KDE apps goes
    /// through this D-Bus interface rather than `xdg-open`, so answering it
    /// is what makes those buttons land in MSL Files.
    static let fileManager1Service = #"""
    [D-BUS Service]
    Name=org.freedesktop.FileManager1
    Exec=/usr/bin/env python3 @MSLDIR@/bin/msl_filemanager1.py

    """#

    /// Makes D-Bus activate *MSL's* portal rather than the distribution's.
    ///
    /// **Seven of the twelve images cannot avoid shipping a portal frontend.**
    /// Measured 2026-09-30 in arm64 containers: arch, fedora, rocky, alma,
    /// centos, oracle and opensuse all pull `xdg-desktop-portal` in with the
    /// desktop tier, and on Fedora it is a *hard* dependency of firefox - so
    /// no combination of `--no-recommends` flags keeps it out, and removing
    /// it would take the browser with it.
    ///
    /// That matters because `portalLines` starts MSL's portal in the
    /// background without waiting for it to claim the name. An app that asks
    /// for `org.freedesktop.portal.Desktop` before it has done so gets the
    /// frontend activated instead, which then owns the name and answers the
    /// file-chooser calls - the "file picker works, except sometimes" shape.
    ///
    /// The fix is to lose the race harmlessly: whoever asks first, the bus
    /// starts this. `$XDG_DATA_HOME` is searched before the system directories
    /// for service files, so this file shadows the distribution's own
    /// (verified against dbus-daemon 2026-09-30; a same-named file in
    /// `~/.local/share` won the activation).
    ///
    /// Shadowing rather than deleting the distribution's file is deliberate:
    /// it survives the package being reinstalled or upgraded, and it protects
    /// the five images that are clean today from whatever a user installs
    /// tomorrow.
    static let portalService = #"""
    [D-BUS Service]
    Name=org.freedesktop.portal.Desktop
    Exec=/usr/bin/env python3 @MSLDIR@/bin/msl_portal.py

    """#

    static let fileManager1Python = #"""
    #!/usr/bin/env python3
    """MSL: org.freedesktop.FileManager1 for Linux apps started by MSL.

    Every call is passed to msl_open.py, which shows the folder in MSL Files
    on the Mac or, when the Mac declines, opens it with the Linux handler.

    Installed by MSL (GuestIntegration.swift); rewritten on MSL updates.
    """
    import os
    import subprocess
    import sys

    try:
        from gi.repository import Gio, GLib
    except ImportError:
        sys.exit(1)

    NAME = "org.freedesktop.FileManager1"
    PATH = "/org/freedesktop/FileManager1"
    HERE = os.path.dirname(os.path.abspath(__file__))
    IDLE_SECONDS = 120

    XML = """
    <node>
      <interface name="org.freedesktop.FileManager1">
        <method name="ShowFolders">
          <arg type="as" name="URIs" direction="in"/>
          <arg type="s" name="StartupId" direction="in"/>
        </method>
        <method name="ShowItems">
          <arg type="as" name="URIs" direction="in"/>
          <arg type="s" name="StartupId" direction="in"/>
        </method>
        <method name="ShowItemProperties">
          <arg type="as" name="URIs" direction="in"/>
          <arg type="s" name="StartupId" direction="in"/>
        </method>
      </interface>
    </node>
    """

    loop = GLib.MainLoop()
    idle_source = [0]


    def rearm_idle_exit():
        if idle_source[0]:
            GLib.source_remove(idle_source[0])
        idle_source[0] = GLib.timeout_add_seconds(IDLE_SECONDS, quit_loop)


    def quit_loop():
        loop.quit()
        return False


    def on_call(connection, sender, path, interface, method, parameters, invocation):
        uris = [uri for uri in parameters.unpack()[0] if uri]
        if uris:
            kind = "dir" if method == "ShowFolders" else "show"
            subprocess.Popen([sys.executable, os.path.join(HERE, "msl_open.py"), kind] + uris)
        invocation.return_value(None)
        rearm_idle_exit()


    def on_bus_acquired(connection, name):
        info = Gio.DBusNodeInfo.new_for_xml(XML)
        connection.register_object(PATH, info.interfaces[0], on_call, None, None)


    Gio.bus_own_name(Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.NONE,
                     on_bus_acquired, None, lambda *_: loop.quit())
    rearm_idle_exit()
    loop.run()

    """#

    // MARK: - Global menu bar

    /// Brings up the menu bridge, once per Linux account, and points GTK 3
    /// at the module that feeds it.
    ///
    /// The bridge is a daemon of its own rather than the app's parent. It
    /// used to be `msl-session`, a wrapper that `exec`ed the app - which
    /// meant the app never reached the transient user scope below it, and
    /// snaps went straight back to refusing to run ("not a snap cgroup").
    /// One long-lived bridge on the user's session bus is also closer to
    /// the truth: it already keys its host connections by application name
    /// and serves any number of them.
    ///
    /// Started before the app and waited for, never fire-and-forget: Qt
    /// asks once, at startup, whether anything owns
    /// `com.canonical.AppMenu.Registrar`, and decides there and then
    /// whether to export its menus at all. Lose that race and the app
    /// keeps its menus in its own window for the rest of its life.
    /// Where the bridge records the applications it has seen export a menu
    /// bar, relative to the kit's own directory.
    public static let menuExportersFile = "state/menu-exporters"

    /// The program `command` runs, as the guest will name the process -
    /// which is how the bridge records an exporter and how a launch looks
    /// one up. Empty when the command starts with something MSL cannot
    /// attribute (a `flatpak run`, an environment assignment); such an app
    /// simply keeps its own menu bar alongside the Mac's.
    static func programName(of command: String) -> String {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !cleaned.isEmpty, !cleaned.contains("="), cleaned != "flatpak", cleaned != "snap" else { return "" }
        return cleaned.split(separator: "/").last.map(String.init) ?? ""
    }

    static func menuBridgeLines(for command: String) -> String {
        let exporterName = programName(of: command)
        return #"""
      msl_menu_dir="${XDG_RUNTIME_DIR:-/tmp}"
      msl_menu_pidfile="$msl_menu_dir/msl-menubridge.pid"
      # Ownership of the name is the real question - the bridge may have
      # been started by an app launched minutes ago, and a pid on its own
      # says nothing about whether it ever reached the bus.
      msl_menu_owned() {
          command -v gdbus >/dev/null 2>&1 || return 1
          gdbus call --session --dest org.freedesktop.DBus \
                --object-path /org/freedesktop/DBus \
                --method org.freedesktop.DBus.NameHasOwner \
                com.canonical.AppMenu.Registrar 2>/dev/null | grep -q true
      }
      msl_menu_alive() {
          msl_menu_pid=$(cat "$msl_menu_pidfile" 2>/dev/null) || return 1
          [ -n "$msl_menu_pid" ] || return 1
          case "$(tr '\0' ' ' < "/proc/$msl_menu_pid/cmdline" 2>/dev/null)" in
              *msl_menubridge.py*) return 0 ;;
          esac
          return 1
      }
      if [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v python3 >/dev/null 2>&1 \
         && [ -f "$MSL_D/bin/msl_menubridge.py" ] \
         && ! msl_menu_owned && ! msl_menu_alive; then
          msl_menu_ready="$msl_menu_dir/msl-menubridge.ready"
          rm -f "$msl_menu_ready"
          # Descriptors 3-9 closed for the same reason the X11 tunnel closes
          # them: a daemon that inherits the launching session's vsock keeps
          # that session open for as long as it lives, and the launch never
          # returns. `exec` keeps $! pointing at the bridge itself.
          setsid sh -c 'exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; exec python3 "$0" --ready-file "$1"' \
                 "$MSL_D/bin/msl_menubridge.py" "$msl_menu_ready" \
                 </dev/null >"$msl_menu_dir/msl-menubridge.log" 2>&1 &
          msl_menu_started=$!
          echo "$msl_menu_started" > "$msl_menu_pidfile"
          msl_menu_tries=0
          while [ $msl_menu_tries -lt 30 ]; do
              [ -e "$msl_menu_ready" ] && break
              msl_menu_owned && break
              # **Stop the moment the bridge is gone.** It exits at once when
              # another bridge already owns the name - "leaving it to that
              # one" - and then neither the ready file nor the ownership
              # check will ever come true, so this waited the full three
              # seconds for a process that was already dead. On Alpine that
              # was every single app launch: 3.42s against Fedora's 0.19s,
              # and 3.24s of it was here.
              #
              # Any early exit means the same thing - a crash, a missing
              # dependency, the name taken - so there is nothing to wait for.
              kill -0 "$msl_menu_started" 2>/dev/null || break
              sleep 0.1
              msl_menu_tries=$((msl_menu_tries + 1))
          done
          rm -f "$msl_menu_ready"
      fi
      # `appmenu-gtk-module` does one thing MSL wants and one it does not.
      # It hides the menu bar inside the app's own window, which is right
      # when the menus are in the Mac's bar instead - and it hides it for
      # apps it cannot export, which leaves them with no menus anywhere.
      # GIMP 3.0.4 is one: loading the module took its File/Edit/Select
      # menus off the screen entirely (2026-09-22).
      #
      # So it is never loaded for an application MSL has not already seen
      # export a menu bar. Nothing is exported BECAUSE of the module - a
      # GTK application publishes `org.gtk.Menus` by itself and the bridge
      # reads it either way. The first launch of such an app shows its
      # menus in both places; from the second on, only in the Mac's. An app
      # that never exports never loses anything.
      if [ -n "\#(exporterName)" ] \
         && grep -qxF "\#(exporterName)" "$MSL_D/\#(menuExportersFile)" 2>/dev/null; then
          for msl_menu_module in /usr/lib/*/gtk-3.0/modules/libappmenu-gtk-module.so \
                                 /usr/lib/gtk-3.0/modules/libappmenu-gtk-module.so; do
              if [ -e "$msl_menu_module" ]; then
                  export GTK_MODULES="${GTK_MODULES:+$GTK_MODULES:}appmenu-gtk-module"
                  export UBUNTU_MENUPROXY=1
                  break
              fi
          done
      fi
    """#
    }


    /// Owns `com.canonical.AppMenu.Registrar`, reads each registered
    /// window's `com.canonical.dbusmenu` tree and streams it to the app's
    /// own macOS process; clicks come back the same way.
    ///
    /// It reaches that process by connecting to mslgd's own X11 port and
    /// announcing itself with `MSLM` plus the app's name, which the host
    /// routes exactly like the app's X11 connection (`MSLA`) - so the menus
    /// land in the same process as the windows. The name is worked out
    /// from the registering process the same way `x11tunnel` works it out
    /// from the X client; the two must agree or the menus go to a
    /// different Dock tile.
    /// The Mac's appearance, in the Settings portal's vocabulary:
    /// 1 = prefer dark, 2 = prefer light. Read from the global domain, so it
    /// works in `msl` and in the app hosts alike (`NSApp` is nil in one of
    /// them).
    public static var colorSchemeValue: Int {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased().contains("dark") == true ? 1 : 2
    }

    /// A minimal `org.freedesktop.portal.Settings` implementation.
    ///
    /// **Why MSL ships one.** Every GTK4 app asks the Settings portal for
    /// the desktop's colour scheme at startup. With a session bus present
    /// and no portal answering, that call sits there for D-Bus's full
    /// 25-second timeout before the app draws anything: GNOME Chess took
    /// 25.9s to show a window from MSL and 0.8s from a plain shell, and the
    /// only difference was the bus. `GTK_USE_PORTAL=0` does not help - GTK4
    /// asks regardless.
    ///
    /// Installing `xdg-desktop-portal` would also answer it, at the cost of
    /// two more packages, a backend to configure, and a service whose own
    /// misconfiguration produces exactly the same 25-second stall. This
    /// answers the one question that is actually being asked, in about
    /// eighty lines, and gets out of the way the moment a real portal
    /// appears: the name is claimed only if nobody else wants it, and given
    /// up if a real portal takes over.
    ///
    /// It carries the Mac's own appearance across, so Linux apps follow
    /// macOS between light and dark.
    /// `msl-file-picker` - the file dialog as a command.
    ///
    /// The portal covers apps that speak D-Bus; this covers everything else.
    /// A script, a `.desktop` action or an app with a "choose a file" hook
    /// runs it, the person picks in MSL Files, and the chosen **guest** paths
    /// are printed one per line.
    ///
    /// Exit codes are the interesting part, because a caller has to tell
    /// three different things apart:
    /// - `0` - picked; the paths are on stdout.
    /// - `1` - the person cancelled. **Do not** then show another dialog.
    /// - `2` - MSL declined (the setting is off, or the instance is
    ///   sandboxed) or could not be reached. Show your own dialog; this
    ///   script tries `zenity` and `kdialog` first so a caller usually gets
    ///   one anyway.
    static let filePickerShell = #"""
    #!/usr/bin/env python3
    """MSL: ask the Mac for a file. Installed by MSL; rewritten on updates.

    usage: msl-file-picker [--save] [--dir] [--multiple] [--name NAME]
                           [--title TITLE] [START-DIRECTORY]
    exit:  0 picked (paths on stdout, one per line), 1 cancelled, 2 unavailable
    """
    import json
    import os
    import shutil
    import socket
    import subprocess
    import sys

    HOST_CID = 2
    HOST_PORT = 5008


    def ask_mac(mode, start, name, multiple, title):
        """Guest paths, [] for cancelled, or None when MSL will not do it.

        No timeout: a file dialog is open for as long as the person needs."""
        request = {"v": 1, "kind": "pick", "targets": [start or os.getcwd()],
                   "cwd": os.getcwd(), "mode": mode, "name": name,
                   "multiple": multiple, "title": title}
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, HOST_PORT))
            sock.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n") and len(reply) < 65536:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                reply += chunk
            sock.close()
        except (OSError, AttributeError) as error:
            note("vsock failed: %s" % error)
            return None
        reply = reply.strip()
        if not reply or reply == b"declined":
            note("declined by the Mac")
            return None
        try:
            answer = json.loads(reply.decode())
        except ValueError:
            return None
        if answer.get("result") != "picked":
            return None
        return [p for p in answer.get("paths", []) if isinstance(p, str)]


    def fall_back(mode, name, title):
        """A Linux dialog, so a caller is not left with nothing."""
        if shutil.which("zenity"):
            argv = ["zenity", "--file-selection", "--title", title or "Choose a file"]
            if mode == "save":
                argv += ["--save", "--confirm-overwrite"]
                if name:
                    argv += ["--filename", name]
            elif mode == "directory":
                argv.append("--directory")
        elif shutil.which("kdialog"):
            which = {"save": "--getsavefilename",
                     "directory": "--getexistingdirectory"}.get(mode, "--getopenfilename")
            argv = ["kdialog", which, name or os.getcwd()]
        else:
            return None
        try:
            done = subprocess.run(argv, capture_output=True, text=True)
        except OSError:
            return None
        if done.returncode != 0:
            return []
        return [line for line in done.stdout.strip().split("\n") if line]


    def main(argv):
        mode, name, title, multiple, start = "open", "", "", False, None
        rest = []
        index = 0
        while index < len(argv):
            token = argv[index]
            if token == "--save":
                mode = "save"
            elif token == "--dir":
                mode = "directory"
            elif token == "--multiple":
                multiple = True
            elif token == "--name" and index + 1 < len(argv):
                index += 1
                name = argv[index]
            elif token == "--title" and index + 1 < len(argv):
                index += 1
                title = argv[index]
            elif token in ("-h", "--help"):
                print(__doc__)
                return 0
            else:
                rest.append(token)
            index += 1
        if rest:
            start = rest[0]

        paths = ask_mac(mode, start, name, multiple, title)
        if paths is None:
            paths = fall_back(mode, name, title)
            if paths is None:
                print("msl-file-picker: no file dialog available", file=sys.stderr)
                return 2
        if not paths:
            return 1
        print("\n".join(paths))
        return 0


    if __name__ == "__main__":
        sys.exit(main(sys.argv[1:]))
    """#

    /// `msl-firefox-portal` - makes Firefox use the portal file picker.
    ///
    /// Firefox has its own switch, `widget.use-xdg-desktop-portal.file-picker`,
    /// and it defaults to **2 (only when sandboxed)**. MSL's Firefox is not
    /// sandboxed, so without this it draws its own GTK dialog no matter what
    /// the portal offers - measured, `MOZ_ENABLE_XDG_PORTAL_FILE_PICKER` is
    /// not enough on its own.
    ///
    /// Written into each profile's `user.js`, which Firefox applies over its
    /// saved prefs on every start. Marked with a comment line so it can be
    /// removed again exactly - turning the setting off takes it back out
    /// rather than leaving Firefox changed behind you.
    static let firefoxPortalShell = #"""
    #!/bin/sh
    # MSL: turn Firefox's portal file picker on ($1 = on) or off.
    # Rewritten by MSL on updates.
    mark="// added by MSL - file dialogs open in MSL Files"
    pref='user_pref("widget.use-xdg-desktop-portal.file-picker", 1);'
    for dir in "$HOME"/.mozilla/firefox/*/ "$HOME"/snap/firefox/common/.mozilla/firefox/*/; do
      [ -d "$dir" ] || continue
      # A profile is one with prefs; the rest are crash reporters and locks.
      [ -f "$dir/prefs.js" ] || [ -f "$dir/times.json" ] || continue
      file="$dir/user.js"
      if [ -f "$file" ]; then
        # Always strip MSL's own lines first, so this is idempotent and so
        # turning it off leaves no trace.
        #
        # The `mv` must NOT be chained to grep's exit status: `grep -v`
        # returns 1 when it prints nothing, which is exactly the case where
        # the file held only MSL's lines. Chaining it meant the strip never
        # happened, so "on" appended the pref again every launch and "off"
        # removed nothing (measured: five copies after three runs).
        grep -v -F -e "$mark" -e "$pref" "$file" > "$file.msl-tmp" 2>/dev/null
        mv "$file.msl-tmp" "$file" 2>/dev/null || rm -f "$file.msl-tmp"
      fi
      if [ "$1" = "on" ]; then
        printf '%s\n%s\n' "$mark" "$pref" >> "$file"
      fi
    done
    exit 0
    """#

    /// MSL's desktop portal: `Settings` and `FileChooser`, on one object.
    ///
    /// `Settings` answers the question every GTK4 app asks at startup - see
    /// `portalLines` for the 25-second stall its absence causes.
    ///
    /// `FileChooser` is what turns a Linux app's Open/Save dialog into the
    /// **Mac's** file panel, which can see the Mac's disk as well as the
    /// guest's. Three things in it are easy to get wrong, and all three are
    /// silent failures:
    ///
    /// 1. **The Request object path.** A client computes
    ///    `/org/freedesktop/portal/desktop/request/<sender>/<token>` itself
    ///    (sender = its unique name, leading `:` dropped, `.` to `_`) and
    ///    subscribes to it *before* calling. A different path shows the
    ///    panel and then leaves the app waiting forever for a signal.
    /// 2. **The panel must not block the main loop.** It runs on a worker
    ///    thread, because D-Bus has to keep being served while a dialog is
    ///    open - which can be minutes. Nothing above it may impose a
    ///    timeout for the same reason.
    /// 3. **There must always be a dialog.** When the Mac declines (the
    ///    setting is off, the instance is sandboxed) or the vsock call
    ///    fails, the request is forwarded to `xdg-desktop-portal-gtk`'s
    ///    `org.freedesktop.impl.portal.FileChooser`. No dialog at all is a
    ///    far worse outcome than the Linux one.
    ///
    /// Comments here are deliberately terse: this file is shipped to the
    /// guest inside a single `exec` frame with a hard size budget (see
    /// `testInstallCommandFitsOneExecFrame`), so the "why" lives here.
    static let portalPython = #"""
    #!/usr/bin/env python3
    """MSL's portal: Settings (appearance) and FileChooser (the Mac's panel).

    Installed by MSL (GuestIntegration.swift); rewritten on MSL updates.
    """
    import json
    import os
    import socket
    import subprocess
    import sys
    import threading

    from gi.repository import Gio, GLib

    # The kit's own directory, substituted at install time, so the portal can
    # reach `msl-open` without depending on PATH.
    KIT = "@MSLDIR@"

    # 0 = no preference, 1 = prefer dark, 2 = prefer light. The host passes
    # the Mac's current appearance in MSL_COLOR_SCHEME.
    #
    # The file is the same value, and exists because this portal has two ways
    # of being started. The session script passes the environment variable;
    # D-Bus activation (see `portalService`) passes nothing, and a portal
    # started that way would answer "light" to every GTK4 app on a dark Mac.
    # The session script writes the file, so the activated portal can read
    # what the session would have told it.
    def color_scheme():
        """The Mac's current appearance, read fresh on every request.

        **Not cached, and the file is not a nicety.** This portal has two ways
        of being started. The session script passes MSL_COLOR_SCHEME; D-Bus
        activation (see `portalService`) passes nothing at all, because an
        activated service inherits the *bus's* environment. A portal activated
        before any session script has run would otherwise answer "light" to
        every GTK4 app on a dark Mac, for as long as it lived - and it lives
        as long as the session, because it holds the name and the session
        script's own portal then loses the race and exits.

        Reading per call also means a change of appearance is picked up
        without restarting anything: the session script rewrites the file.
        """
        raw = os.environ.get("MSL_COLOR_SCHEME")
        if raw is None:
            try:
                with open(os.path.join(KIT, ".color-scheme")) as handle:
                    raw = handle.read().strip()
            except OSError:
                raw = "0"
        try:
            value = int(raw)
        except ValueError:
            return 0
        return value if value in (0, 1, 2) else 0

    NAMESPACE = "org.freedesktop.appearance"

    HOST_CID = 2
    HOST_PORT = 5008

    # /dev/null hides every failure as "the app hung" - see portalLines.
    LOG = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "msl-portal.log")


    def note(message):
        try:
            with open(LOG, "a") as handle:
                handle.write("%s\n" % message)
        except OSError:
            pass

    FILECHOOSER_XML = """
    <node>
    <interface name="org.freedesktop.portal.FileChooser">
    <method name="OpenFile">
    <arg type="s" direction="in"/>
    <arg type="s" direction="in"/>
    <arg type="a{sv}" direction="in"/>
    <arg type="o" direction="out"/>
    </method>
    <method name="SaveFile">
    <arg type="s" direction="in"/>
    <arg type="s" direction="in"/>
    <arg type="a{sv}" direction="in"/>
    <arg type="o" direction="out"/>
    </method>
    <property name="version" type="u" access="read"/>
    </interface>
    </node>
    """

    REQUEST_XML = """
    <node>
    <interface name="org.freedesktop.portal.Request">
    <method name="Close"/>
    <signal name="Response">
    <arg type="u"/>
    <arg type="a{sv}"/>
    </signal>
    </interface>
    </node>
    """

    OPENURI_XML = """
    <node>
    <interface name="org.freedesktop.portal.OpenURI">
    <method name="OpenURI">
    <arg type="s" direction="in"/>
    <arg type="s" direction="in"/>
    <arg type="a{sv}" direction="in"/>
    <arg type="o" direction="out"/>
    </method>
    <method name="OpenFile">
    <arg type="s" direction="in"/>
    <arg type="h" direction="in"/>
    <arg type="a{sv}" direction="in"/>
    <arg type="o" direction="out"/>
    </method>
    <method name="OpenDirectory">
    <arg type="s" direction="in"/>
    <arg type="h" direction="in"/>
    <arg type="a{sv}" direction="in"/>
    <arg type="o" direction="out"/>
    </method>
    <property name="version" type="u" access="read"/>
    </interface>
    </node>
    """

    XML = """
    <node>
      <interface name="org.freedesktop.portal.Settings">
        <method name="ReadAll">
          <arg type="as" direction="in"/>
          <arg type="a{sa{sv}}" direction="out"/>
        </method>
        <method name="Read">
          <arg type="s" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="v" direction="out"/>
        </method>
        <method name="ReadOne">
          <arg type="s" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="v" direction="out"/>
        </method>
        <signal name="SettingChanged">
          <arg type="s"/>
          <arg type="s"/>
          <arg type="v"/>
        </signal>
        <property name="version" type="u" access="read"/>
      </interface>
    </node>
    """

    def settings():
        return {NAMESPACE: {"color-scheme": GLib.Variant("u", color_scheme()),
                            "contrast": GLib.Variant("u", 0)}}

    def matches(namespaces):
        # An empty list, or "*", means everything.
        if not namespaces:
            return True
        for pattern in namespaces:
            if pattern in ("", "*", NAMESPACE) or NAMESPACE.startswith(pattern.rstrip("*")):
                return True
        return False

    def handle_call(_conn, _sender, _path, _iface, method, params, invocation):
        if method == "ReadAll":
            wanted = settings() if matches(params[0]) else {}
            body = GLib.Variant("(a{sa{sv}})", (wanted,))
            invocation.return_value(body)
        elif method in ("Read", "ReadOne"):
            namespace, key = params[0], params[1]
            value = settings().get(namespace, {}).get(key)
            if value is None:
                invocation.return_dbus_error("org.freedesktop.portal.Error.NotFound",
                                             "no such setting")
            elif method == "Read":
                # `Read` wraps the value in a *second* variant. That is a
                # known mistake in the portal's own history, kept for
                # compatibility - and what version 2's `ReadOne` exists to
                # correct. Returning it singly wrapped made GTK4 call
                # g_variant_get(value, "v") on a plain uint32, fail its
                # assertion and segfault: MSL's portal crashed the very apps
                # it was there to speed up.
                invocation.return_value(GLib.Variant("(v)", (GLib.Variant("v", value),)))
            else:
                invocation.return_value(GLib.Variant("(v)", (value,)))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def handle_get(_conn, _sender, _path, _iface, prop):
        # 2, because `ReadOne` is implemented. A client that sees 1 uses
        # `Read` and unwraps twice; one that sees 2 uses `ReadOne`. Both are
        # answered correctly, so either is safe.
        return GLib.Variant("u", 2) if prop == "version" else None

    def request_path(sender, token):
        """The path the client already subscribed to. Exact or the app hangs."""
        clean = sender.lstrip(":").replace(".", "_")
        return "/org/freedesktop/portal/desktop/request/%s/%s" % (clean, token)


    def ask_mac_to_pick(mode, start, name, multiple, title):
        """Guest paths, or None to fall back. No timeout - dialogs stay open."""
        note("pick: %s" % mode)
        request = {"v": 1, "kind": "pick", "targets": [start or "/"],
                   "cwd": "/", "mode": mode, "name": name or "",
                   "multiple": bool(multiple), "title": title or ""}
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, HOST_PORT))
            sock.sendall((json.dumps(request) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n") and len(reply) < 65536:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                reply += chunk
            sock.close()
        except (OSError, AttributeError):
            return None
        reply = reply.strip()
        if reply == b"declined" or not reply:
            return None
        try:
            answer = json.loads(reply.decode())
        except ValueError:
            note("pick reply was not JSON")
            return None
        if answer.get("result") != "picked":
            note("pick reply result=%r" % answer.get("result"))
            return None
        return [p for p in answer.get("paths", []) if isinstance(p, str)]


    def forward_to_linux(bus, method, parent, title, options_variant):
        """The Linux chooser instead - no dialog at all is worse than this one."""
        try:
            args = GLib.Variant.new_tuple(
                GLib.Variant("s", ""), GLib.Variant("s", parent),
                GLib.Variant("s", title), options_variant)
            return bus.call_sync(
                "org.freedesktop.impl.portal.desktop.gtk",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.impl.portal.FileChooser", method, args,
                GLib.VariantType("(ua{sv})"), Gio.DBusCallFlags.NONE, -1, None)
        except (GLib.Error, TypeError, ValueError) as error:
            note("forward failed: %s" % error)
            return None


    def run_chooser(bus, sender, method, parent, title, options, options_variant, path):
        """The panel, then the Response signal."""
        mode = "save" if method == "SaveFile" else "open"
        if options.get("directory"):
            mode = "directory"
        # `current_folder` is a D-Bus `ay` - a BYTE ARRAY, which GLib unpacks
        # to a list of ints, not to bytes. Passing that straight on sent a
        # list where a path belonged and the Mac rejected the whole request
        # as malformed, silently (measured 2026-09-29). It is also NUL
        # terminated, by the portal spec.
        start = options.get("current_folder")
        if isinstance(start, (list, tuple)):
            start = bytes(bytearray(start))
        if isinstance(start, (bytes, bytearray)):
            start = bytes(start).rstrip(b"\x00").decode("utf-8", "replace")
        if not isinstance(start, str) or not start:
            # An app that names no folder should land in the person's Linux
            # home, not at the filesystem root: a picker opening on /bin and
            # /proc is useless, and the home is where their files are. Only
            # the guest knows what that path is.
            start = os.path.expanduser("~") or None
        name = options.get("current_name")
        paths = ask_mac_to_pick(mode, start, name if isinstance(name, str) else "",
                                bool(options.get("multiple")), title)
        if paths is None:
            forwarded = forward_to_linux(bus, method, parent, title, options_variant)
            if forwarded is not None:
                response, results = forwarded.unpack()
            else:
                response, results = 2, {}   # 2 = "ended some other way"
        elif not paths:
            response, results = 1, {}       # 1 = the person cancelled
        else:
            response = 0
            results = {"uris": GLib.Variant("as", ["file://" + p for p in paths])}

        # **`uris` must be present on EVERY response, including a cancel.**
        # GTK's own portal client reads it before it looks at the response
        # code - `g_variant_lookup (response_data, "uris", "^a&s", &uris)`
        # and then walks `uris[i]` - and `g_variant_lookup` leaves that
        # pointer UNINITIALISED when the key is missing. So a cancel with an
        # empty `a{sv}` made GTK iterate a garbage pointer and segfault
        # inside the D-Bus signal callback, taking the whole app with it.
        #
        # Found 2026-09-30 from a gdb backtrace: SIGSEGV in libgtk-3, called
        # from libgio's signal dispatch, when cancelling Firefox's Save As.
        # Firefox uses GTK's portal client rather than its own, so this was
        # never Firefox's bug to fix - and "the person pressed Cancel" is the
        # one path where an app has done nothing wrong at all.
        if not isinstance(results, dict):
            results = {}
        if "uris" not in results:
            results["uris"] = GLib.Variant("as", [])
        try:
            bus.emit_signal(sender, path, "org.freedesktop.portal.Request",
                            "Response",
                            GLib.Variant("(ua{sv})", (response, results)))
        except GLib.Error:
            pass


    def handle_openuri(connection, sender, path, interface, method, params, invocation):
        """org.freedesktop.portal.OpenURI - "open this link/file for me".

        **Not optional, and not only needed because of GTK_USE_PORTAL.** Any
        sandboxed app - every Flatpak and snap - already asks the portal to
        open a link rather than running a handler itself, and until this
        existed MSL's portal answered UnknownMethod, so those links went
        nowhere. Exporting GTK_USE_PORTAL widened that to GTK3's
        gtk_show_uri_on_window, which is most "click a link in a Linux app".

        It hands the URI to `msl-open`, which is the same path MSL's
        xdg-open/mimeapps integration already uses, so a link opens in the
        Mac's browser and a file opens in the Mac app that claims it.
        """
        parent, target, options = params.unpack()
        token = options.get("handle_token") or "msl"
        request_object = request_path(sender, token)
        node = Gio.DBusNodeInfo.new_for_xml(REQUEST_XML)
        try:
            registration = connection.register_object(
                request_object, node.interfaces[0],
                lambda *a: a[-1].return_value(None), None, None)
        except GLib.Error:
            registration = 0

        uri = None
        if method == "OpenURI":
            uri = target if isinstance(target, str) else None
        else:
            # OpenFile/OpenDirectory pass a file *descriptor*, not a path:
            # the whole point is that a sandboxed app may hold an open file
            # it cannot name. The fd travels beside the message, so it comes
            # from the message's fd list and `target` is only an index into
            # it. /proc resolves it back to a path this side of the sandbox.
            try:
                fd_list = invocation.get_message().get_unix_fd_list()
                fd = fd_list.get(target) if fd_list is not None else -1
                if fd >= 0:
                    uri = os.readlink("/proc/self/fd/%d" % fd)
                    os.close(fd)
            except (OSError, GLib.Error, TypeError) as error:
                note("openuri: could not resolve fd: %s" % error)

        invocation.return_value(GLib.Variant("(o)", (request_object,)))

        def work():
            response = 2
            try:
                if uri:
                    # `msl-open` takes a kind first (url|dir|show); a bare
                    # URI would be rejected as a usage error.
                    kind = "dir" if method == "OpenDirectory" else "url"
                    opener = os.path.join(KIT, "bin", "msl-open")
                    if os.access(opener, os.X_OK):
                        command = [opener, kind, uri]
                    else:
                        command = ["xdg-open", uri]
                    response = 0 if subprocess.call(
                        command,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL) == 0 else 2
            except Exception as error:
                note("openuri failed: %s" % error)
            finally:
                try:
                    connection.emit_signal(
                        sender, request_object, "org.freedesktop.portal.Request",
                        "Response", GLib.Variant("(ua{sv})", (response, {})))
                except GLib.Error:
                    pass
                if registration:
                    connection.unregister_object(registration)
        threading.Thread(target=work, daemon=True).start()


    def handle_filechooser(connection, sender, path, interface, method, params, invocation):
        parent, title, options = params.unpack()
        # unpack() gives plain Python; GLib cannot rebuild a{sv} from it.
        options_variant = params.get_child_value(2)
        token = options.get("handle_token") or "msl"
        request_object = request_path(sender, token)
        # Must exist before the handle is returned: the client may Close it.
        node = Gio.DBusNodeInfo.new_for_xml(REQUEST_XML)
        try:
            registration = connection.register_object(
                request_object, node.interfaces[0],
                lambda *a: a[-1].return_value(None), None, None)
        except GLib.Error:
            registration = 0
        invocation.return_value(GLib.Variant("(o)", (request_object,)))
        # Threaded: the main loop must keep serving D-Bus while the panel is up.
        def work():
            try:
                run_chooser(connection, sender, method, parent, title,
                            options, options_variant, request_object)
            except Exception as error:
                # Silence here = the app waits for a signal forever.
                note("chooser failed: %s" % error)
                try:
                    connection.emit_signal(
                        sender, request_object, "org.freedesktop.portal.Request",
                        "Response", GLib.Variant("(ua{sv})", (2, {})))
                except GLib.Error:
                    pass
            finally:
                if registration:
                    connection.unregister_object(registration)
        threading.Thread(target=work, daemon=True).start()


    def main():
        loop = GLib.MainLoop()
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        bus.register_object("/org/freedesktop/portal/desktop", node.interfaces[0],
                            handle_call, handle_get, None)
        chooser = Gio.DBusNodeInfo.new_for_xml(FILECHOOSER_XML)
        bus.register_object("/org/freedesktop/portal/desktop", chooser.interfaces[0],
                            handle_filechooser,
                            lambda *_a: GLib.Variant("u", 3), None)
        opener = Gio.DBusNodeInfo.new_for_xml(OPENURI_XML)
        bus.register_object("/org/freedesktop/portal/desktop", opener.interfaces[0],
                            handle_openuri,
                            lambda *_a: GLib.Variant("u", 3), None)

        def lost(*_args):
            # A real portal has taken over, or claimed the name first.
            loop.quit()

        Gio.bus_own_name_on_connection(
            bus, "org.freedesktop.portal.Desktop",
            Gio.BusNameOwnerFlags.DO_NOT_QUEUE, None, lost)
        loop.run()

    if __name__ == "__main__":
        try:
            main()
        except Exception as error:  # a portal that crashes must not take an app with it
            print("msl-portal: %s" % error, file=sys.stderr)
            sys.exit(1)
    """#

    static let menuBridgePython = #"""
    #!/usr/bin/env python3
    """MSL: moves Linux app menus into the Mac's menu bar.

    Installed by MSL (GuestIntegration.swift); rewritten on MSL updates.
    """
    import json
    import os
    import socket
    import sys
    import threading

    from gi.repository import Gio, GLib

    HOST_CID = 2
    X11_PORT = 5003
    HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    # Applications seen to export a menu bar. Read by the launcher, which
    # loads `appmenu-gtk-module` only for these - see `menuBridgeLines`.
    EXPORTERS = os.path.join(HERE, "state", "menu-exporters")
    # Everything here goes to the bridge's own log (msl-menubridge.log in
    # the user's runtime directory). A menu bar that stays in the app's
    # window has three possible causes - the app never registered, the
    # bridge could not reach the app's macOS process, or the tree came back
    # empty - and they are indistinguishable without this.
    VERBOSE = os.environ.get("MSL_MENU_DEBUG") != "0"


    def log(message):
        if VERBOSE:
            print("msl-menubridge: %s" % message, file=sys.stderr, flush=True)


    def remember_exporter(name):
        """Records that `name`'s menus reached the Mac.

        The next launch of it can then hide the copy inside its own window,
        which MSL will not do to an application on spec - see
        `menuBridgeLines`.
        """
        if not name:
            return
        try:
            os.makedirs(os.path.dirname(EXPORTERS), exist_ok=True)
            known = set()
            if os.path.exists(EXPORTERS):
                with open(EXPORTERS) as handle:
                    known = {line.strip() for line in handle if line.strip()}
            if name in known:
                return
            known.add(name)
            with open(EXPORTERS + ".new", "w") as handle:
                handle.write("\n".join(sorted(known)) + "\n")
            os.replace(EXPORTERS + ".new", EXPORTERS)
            log("%s exports its menus - its next launch can drop the copy in its window" % name)
        except OSError as error:
            log("cannot record %s as an exporter: %s" % (name, error))
    REGISTRAR = "com.canonical.AppMenu.Registrar"
    REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar"
    DBUSMENU = "com.canonical.dbusmenu"

    # GTK does not use dbusmenu at all. A GTK application publishes its
    # menus as a GMenuModel over `org.gtk.Menus` and its actions over
    # `org.gtk.Actions`, and only CHECKS for the registrar above to decide
    # whether a global menu bar exists at all. That is why every GTK app
    # under MSL lost the menu bar from its own window and showed nothing in
    # the Mac's: `appmenu-gtk3-module` saw the registrar, took the menus out
    # of the window, and published them in a language the bridge could not
    # read (2026-09-22).
    GTK_MENUS = "org.gtk.Menus"
    GTK_ACTIONS = "org.gtk.Actions"

    # Bus names that are never an application's menus. Everything else is
    # tried, because an application's name is its own (org.xfce.mousepad,
    # org.gimp.GIMP) and there is no list of them.
    SKIP_NAME_PREFIXES = ("org.freedesktop.", "org.gtk.vfs", "ca.desrt.", "org.a11y.",
                          "org.pulseaudio.", "com.canonical.", "org.kde.StatusNotifier")

    # Synthetic window ids for GTK menus. A GTK application says nothing
    # about which X11 window its menu bar belongs to - the mapping lives in
    # a window property MSL's host reads, not on the bus - but each macOS
    # host process serves exactly one application, so "this app's menus" is
    # all the host needs. Kept well clear of real X11 window ids.
    GTK_WINDOW_BASE = 0x40000000


    def gtk_base_paths(name):
        """Where an application with this bus name might have its menus.

        Usually the object path is the bus name with dots turned into
        slashes. Not always: GIMP owns `org.gimp.GIMP.UI` and exports at
        `/org/gimp/GIMP`, because the name it takes on the bus is not its
        application id. So the trailing components are dropped one at a
        time as well - three paths at most, each one cheap to ask about.
        """
        parts = name.replace("-", "_").split(".")
        paths = []
        while len(parts) >= 2 and len(paths) < 3:
            paths.append("/" + "/".join(parts))
            parts = parts[:-1]
        return paths

    XML = """
    <node>
      <interface name="com.canonical.AppMenu.Registrar">
        <method name="RegisterWindow">
          <arg type="u" name="windowId" direction="in"/>
          <arg type="o" name="menuObjectPath" direction="in"/>
        </method>
        <method name="UnregisterWindow">
          <arg type="u" name="windowId" direction="in"/>
        </method>
        <method name="GetMenuForWindow">
          <arg type="u" name="windowId" direction="in"/>
          <arg type="s" name="service" direction="out"/>
          <arg type="o" name="menuObjectPath" direction="out"/>
        </method>
        <signal name="WindowRegistered">
          <arg type="u" name="windowId"/>
          <arg type="s" name="service"/>
          <arg type="o" name="menuObjectPath"/>
        </signal>
        <signal name="WindowUnregistered">
          <arg type="u" name="windowId"/>
        </signal>
      </interface>
    </node>
    """


    def app_name(pid):
        """The name x11tunnel announces for the same process."""
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                raw = f.read(255)
        except OSError:
            return None
        name = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
        if " " in name:
            try:
                name = os.readlink("/proc/%d/exe" % pid)
                deleted = name.find(" (deleted)")
                if deleted >= 0:
                    name = name[:deleted]
            except OSError:
                name = name.split(" ", 1)[0]
        name = name.rsplit("/", 1)[-1]
        if not name or len(name.encode()) > 200:
            return None
        return name


    class HostLink:
        """One connection to the app's macOS process."""

        def __init__(self, name, on_message):
            self.name = name
            self.lock = threading.Lock()
            self.sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            self.sock.connect((HOST_CID, X11_PORT))
            encoded = name.encode()[:200]
            self.sock.sendall(b"MSLM" + bytes([len(encoded)]) + encoded)
            self.alive = True
            self.on_message = on_message
            threading.Thread(target=self.read_loop, daemon=True).start()

        def send(self, message):
            data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
            with self.lock:
                if not self.alive:
                    return
                try:
                    self.sock.sendall(data)
                except OSError:
                    self.alive = False

        def read_loop(self):
            buffer = b""
            while True:
                try:
                    chunk = self.sock.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    self.alive = False
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    GLib.idle_add(self.on_message, message)


    def plain(value):
        if isinstance(value, GLib.Variant):
            return plain(value.unpack())
        if isinstance(value, (list, tuple)):
            return [plain(v) for v in value]
        if isinstance(value, dict):
            return {k: plain(v) for k, v in value.items()}
        return value


    def convert(node):
        item_id, props, children = node
        props = plain(props)
        return {
            "id": item_id,
            "label": props.get("label", ""),
            "enabled": props.get("enabled", True),
            "visible": props.get("visible", True),
            "type": props.get("type", "standard"),
            "toggle": props.get("toggle-type", ""),
            "state": props.get("toggle-state", -1),
            "submenu": props.get("children-display", "") == "submenu",
            "shortcut": props.get("shortcut", []),
            "children": [convert(plain(child)) for child in children],
        }


    class Bridge:
        def __init__(self, ready_file):
            self.ready_file = ready_file
            self.bus = None
            self.windows = {}      # window id -> dict(sender, path, link, subs, pending)
            self.links = {}        # app name -> HostLink
            self.gtk = {}          # bus name -> GTK application state
            self.gtk_windows = {}  # synthetic window id -> bus name
            self.next_gtk_window = GTK_WINDOW_BASE
            self.loop = GLib.MainLoop()

        def run(self):
            Gio.bus_own_name(Gio.BusType.SESSION, REGISTRAR, Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
                             self.on_bus_acquired, self.on_name_acquired, self.on_name_lost)
            self.loop.run()

        def on_bus_acquired(self, connection, name):
            self.bus = connection
            info = Gio.DBusNodeInfo.new_for_xml(XML)
            connection.register_object(REGISTRAR_PATH, info.interfaces[0], self.on_call, None, None)
            connection.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                                        "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE,
                                        self.on_name_owner_changed)

        def on_name_acquired(self, connection, name):
            log("owning %s" % name)
            if self.ready_file:
                open(self.ready_file, "w").close()
            # Applications already running when the bridge starts - the
            # bridge outlives any one app, and is started by whichever app
            # comes first.
            self.scan_gtk_apps()

        def on_name_lost(self, connection, name):
            log("another bridge already owns %s - leaving it to that one" % name)
            self.loop.quit()

        def on_call(self, connection, sender, path, interface, method, parameters, invocation):
            args = parameters.unpack()
            if method == "RegisterWindow":
                self.register(sender, args[0], args[1])
                invocation.return_value(None)
            elif method == "UnregisterWindow":
                self.unregister(args[0])
                invocation.return_value(None)
            elif method == "GetMenuForWindow":
                window = self.windows.get(args[0])
                if window:
                    invocation.return_value(GLib.Variant("(so)", (window["sender"], window["path"])))
                else:
                    invocation.return_value(GLib.Variant("(so)", ("", "/")))

        def link_for(self, sender):
            try:
                reply = self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                           "GetConnectionUnixProcessID", GLib.Variant("(s)", (sender,)),
                                           GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 2000, None)
                name = app_name(reply.unpack()[0])
            except GLib.Error:
                name = None
            if not name:
                log("no application name for %s - menus have nowhere to go" % sender)
                return None
            link = self.links.get(name)
            if link is None or not link.alive:
                try:
                    link = HostLink(name, self.on_host_message)
                except OSError as error:
                    log("cannot reach the macOS process for %s: %s" % (name, error))
                    return None
                self.links[name] = link
                for window_id, window in self.windows.items():
                    if window["link"] is not None and not window["link"].alive:
                        window["link"] = link
                        self.schedule_refresh(window_id)
            return link

        def register(self, sender, window_id, path):
            self.unregister(window_id, notify_host=False)
            link = self.link_for(sender)
            log("register window=%s sender=%s path=%s app=%s"
                % (window_id, sender, path, link.name if link else "<no host link>"))
            subs = []
            for signal in ("LayoutUpdated", "ItemsPropertiesUpdated"):
                subs.append(self.bus.signal_subscribe(sender, DBUSMENU, signal, path, None,
                                                      Gio.DBusSignalFlags.NONE,
                                                      lambda *_a, w=window_id: self.schedule_refresh(w)))
            self.windows[window_id] = {"sender": sender, "path": path, "link": link, "subs": subs, "pending": 0}
            self.bus.emit_signal(None, REGISTRAR_PATH, REGISTRAR, "WindowRegistered",
                                 GLib.Variant("(uso)", (window_id, sender, path)))
            self.schedule_refresh(window_id)

        def unregister(self, window_id, notify_host=True):
            window = self.windows.pop(window_id, None)
            if window is None:
                return
            for sub in window["subs"]:
                self.bus.signal_unsubscribe(sub)
            if window["pending"]:
                GLib.source_remove(window["pending"])
            if notify_host and window["link"] is not None:
                window["link"].send({"t": "remove", "window": window_id})
            if notify_host:
                self.bus.emit_signal(None, REGISTRAR_PATH, REGISTRAR, "WindowUnregistered",
                                     GLib.Variant("(u)", (window_id,)))

        def on_name_owner_changed(self, connection, sender, path, interface, signal, parameters):
            name, old_owner, new_owner = parameters.unpack()
            if not name.startswith(":"):
                # A GTK application takes its own well-known name as it
                # registers. The menus are exported around the same moment
                # rather than before it, so this looks again shortly after
                # rather than deciding on the first glance.
                if new_owner:
                    for delay in (200, 1200, 4000):
                        GLib.timeout_add(delay, self.consider_gtk, name)
                else:
                    self.drop_gtk(name)
                return
            if new_owner:
                return
            for window_id in [w for w, info in self.windows.items() if info["sender"] == name]:
                self.unregister(window_id)

        def schedule_refresh(self, window_id):
            window = self.windows.get(window_id)
            if window is None or window["pending"]:
                return
            window["pending"] = GLib.timeout_add(60, self.refresh, window_id)

        def refresh(self, window_id):
            window = self.windows.get(window_id)
            if window is None:
                return False
            window["pending"] = 0
            self.bus.call(window["sender"], window["path"], DBUSMENU, "GetLayout",
                          GLib.Variant("(iias)", (0, -1, [])), GLib.VariantType("(u(ia{sv}av))"),
                          Gio.DBusCallFlags.NONE, 5000, None, self.on_layout, window_id)
            return False

        def on_layout(self, bus, result, window_id):
            window = self.windows.get(window_id)
            if window is None:
                return
            try:
                revision, layout = bus.call_finish(result).unpack()
            except GLib.Error as error:
                log("window %s would not give up its menus: %s" % (window_id, error))
                return
            if window["link"] is None or not window["link"].alive:
                window["link"] = self.link_for(window["sender"])
            if window["link"] is None:
                log("window %s has menus but no macOS process to show them in" % window_id)
                return
            menu = convert(plain(layout))
            remember_exporter(window["link"].name)
            log("window %s sent %d top-level menus to %s"
                % (window_id, len(menu["children"]), window["link"].name))
            window["link"].send({"t": "menu", "window": window_id, "menu": menu})

        def menu_event(self, window_id, item_id, event):
            window = self.windows.get(window_id)
            if window is None:
                return
            self.bus.call(window["sender"], window["path"], DBUSMENU, "Event",
                          GLib.Variant("(isvu)", (item_id, event, GLib.Variant("i", 0), 0)),
                          None, Gio.DBusCallFlags.NONE, 5000, None, None, None)

        def on_host_message(self, message):
            kind = message.get("t")
            window_id = message.get("window")
            item_id = message.get("id")
            if not isinstance(window_id, int) or not isinstance(item_id, int):
                return False
            if window_id in self.gtk_windows:
                if kind == "activate":
                    self.gtk_activate(self.gtk_windows[window_id], item_id)
                return False
            if kind == "activate":
                self.menu_event(window_id, item_id, "clicked")
            elif kind == "opening":
                self.menu_event(window_id, item_id, "opened")
                window = self.windows.get(window_id)
                if window is not None:
                    self.bus.call(window["sender"], window["path"], DBUSMENU, "AboutToShow",
                                  GLib.Variant("(i)", (item_id,)), GLib.VariantType("(b)"),
                                  Gio.DBusCallFlags.NONE, 5000, None, self.on_about_to_show, window_id)
            elif kind == "closed":
                self.menu_event(window_id, item_id, "closed")
            return False

        # MARK: GTK applications (org.gtk.Menus)

        def scan_gtk_apps(self):
            try:
                names = self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                           "org.freedesktop.DBus", "ListNames", None,
                                           GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE,
                                           2000, None).unpack()[0]
            except GLib.Error as error:
                log("cannot list bus names: %s" % error)
                return
            for name in names:
                self.consider_gtk(name)

        def consider_gtk(self, name):
            """Adopt `name` if it is an application exporting a menu bar."""
            if name.startswith(":") or name.startswith(SKIP_NAME_PREFIXES) or name in self.gtk:
                return False
            app = None
            for base in gtk_base_paths(name):
                candidate = {"name": name, "base": base, "menubar": base + "/menus/menubar",
                             "groups": {}, "subscribed": set(), "items": {}, "actions": {},
                             "window_paths": None, "link": None, "subs": [], "pending": 0,
                             "sent": None, "window": self.next_gtk_window}
                try:
                    self.gtk_start(candidate, [0])
                except GLib.Error:
                    continue
                if candidate["groups"].get(0, {}).get(0):
                    app = candidate
                    break
            if app is None:
                return False

            self.next_gtk_window += 1
            self.gtk[name] = app
            self.gtk_windows[app["window"]] = name
            log("GTK application %s exports a menu bar at %s" % (name, app["menubar"]))
            app["subs"].append(self.bus.signal_subscribe(
                name, GTK_MENUS, "Changed", app["menubar"], None, Gio.DBusSignalFlags.NONE,
                lambda *_a, n=name: self.schedule_gtk(n)))
            app["subs"].append(self.bus.signal_subscribe(
                name, GTK_ACTIONS, "Changed", None, None, Gio.DBusSignalFlags.NONE,
                lambda *_a, n=name: self.schedule_gtk(n)))
            self.gtk_send(name)
            return False

        def drop_gtk(self, name):
            app = self.gtk.pop(name, None)
            if app is None:
                return
            for sub in app["subs"]:
                self.bus.signal_unsubscribe(sub)
            if app["pending"]:
                GLib.source_remove(app["pending"])
            self.gtk_windows.pop(app["window"], None)
            if app["link"] is not None:
                app["link"].send({"t": "remove", "window": app["window"]})

        def gtk_start(self, app, groups):
            """Subscribes to menu `groups` and remembers what they contain."""
            wanted = [group for group in groups if group not in app["subscribed"]]
            if not wanted:
                return
            reply = self.bus.call_sync(app["name"], app["menubar"], GTK_MENUS, "Start",
                                       GLib.Variant("(au)", (wanted,)),
                                       GLib.VariantType("(a(uuaa{sv}))"),
                                       Gio.DBusCallFlags.NONE, 3000, None)
            app["subscribed"].update(wanted)
            for group, menu, items in plain(reply)[0]:
                app["groups"].setdefault(group, {})[menu] = items

        def gtk_items(self, app, group, menu):
            if group not in app["subscribed"]:
                try:
                    self.gtk_start(app, [group])
                except GLib.Error:
                    return []
            return app["groups"].get(group, {}).get(menu, [])

        def gtk_window_paths(self, app):
            """Where the application's per-window actions live.

            A GtkApplicationWindow exports its own action group under
            `<base>/window/<n>`, and every `win.` action in the menus is
            answered there rather than by the application itself.
            """
            if app["window_paths"] is not None:
                return app["window_paths"]
            paths = []
            try:
                xml = self.bus.call_sync(app["name"], app["base"] + "/window",
                                         "org.freedesktop.DBus.Introspectable", "Introspect", None,
                                         GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE,
                                         3000, None).unpack()[0]
                for node in Gio.DBusNodeInfo.new_for_xml(xml).nodes:
                    paths.append(app["base"] + "/window/" + node.path)
            except GLib.Error:
                paths = []
            app["window_paths"] = paths
            return paths

        def gtk_describe(self, app):
            """Every action's enabled state, parameter type and value.

            The menu model carries none of this - an item names an action
            and nothing more - so a menu built without it would show every
            item enabled and no checkmarks.
            """
            actions = {}
            for prefix, path in [("app.", app["base"])] + \
                                [("win.", p) for p in self.gtk_window_paths(app)]:
                try:
                    described = self.bus.call_sync(app["name"], path, GTK_ACTIONS, "DescribeAll", None,
                                                   GLib.VariantType("(a{s(bgav)})"),
                                                   Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]
                except GLib.Error:
                    continue
                for action, (enabled, signature, state) in described.items():
                    actions[prefix + action] = {"enabled": enabled, "signature": signature,
                                                "state": state[0] if state else None,
                                                "path": path, "short": action}
            app["actions"] = actions
            return actions

        def gtk_node(self, app, item, counter):
            action = item.get("action")
            target = item.get("target")
            described = app["actions"].get(action, {}) if action else {}
            node = {"id": counter[0], "label": item.get("label", ""),
                    "enabled": described.get("enabled", True) if action else True,
                    "visible": True, "type": "standard", "toggle": "", "state": -1,
                    "submenu": False, "shortcut": [], "children": []}
            counter[0] += 1
            app["items"][node["id"]] = (action, target)

            state = described.get("state")
            if isinstance(state, bool):
                node["toggle"] = "checkmark"
                node["state"] = 1 if state else 0
            elif target is not None and state is not None:
                node["toggle"] = "radio"
                node["state"] = 1 if state == target else 0
            return node

        def gtk_tree(self, app, group, menu, counter, depth=0):
            """One menu, flattened the way a Mac menu wants it.

            A GMenu's sections are nested menus that are drawn inline with a
            separator between them, not submenus - so they are flattened
            here and a separator put between them, which is exactly what
            `NSMenu` expects.
            """
            nodes = []
            if depth > 8:
                return nodes
            for item in self.gtk_items(app, group, menu):
                if ":section" in item:
                    section = self.gtk_tree(app, item[":section"][0], item[":section"][1],
                                            counter, depth + 1)
                    if not section:
                        continue
                    if nodes:
                        nodes.append({"id": counter[0], "label": "", "enabled": False,
                                      "visible": True, "type": "separator", "toggle": "",
                                      "state": -1, "submenu": False, "shortcut": [],
                                      "children": []})
                        counter[0] += 1
                    nodes.extend(section)
                    continue
                node = self.gtk_node(app, item, counter)
                if ":submenu" in item:
                    node["submenu"] = True
                    node["children"] = self.gtk_tree(app, item[":submenu"][0], item[":submenu"][1],
                                                     counter, depth + 1)
                nodes.append(node)
            return nodes

        def schedule_gtk(self, name):
            app = self.gtk.get(name)
            if app is None or app["pending"]:
                return
            app["pending"] = GLib.timeout_add(120, self.gtk_send, name)

        def gtk_send(self, name):
            app = self.gtk.get(name)
            if app is None:
                return False
            app["pending"] = 0
            # Rebuilt rather than patched: an application that changes its
            # menus renumbers nothing, and a stale item id would activate
            # the wrong action.
            app["groups"] = {}
            app["subscribed"] = set()
            app["items"] = {}
            app["window_paths"] = None
            self.gtk_describe(app)
            counter = [1]
            try:
                children = self.gtk_tree(app, 0, 0, counter)
            except GLib.Error as error:
                log("%s would not give up its menus: %s" % (name, error))
                return False
            if app["link"] is None or not app["link"].alive:
                app["link"] = self.link_for(name)
            if app["link"] is None:
                log("%s has menus but no macOS process to show them in" % name)
                return False

            menu = {"id": 0, "label": "", "enabled": True, "visible": True,
                    "type": "standard", "toggle": "", "state": -1,
                    "submenu": True, "shortcut": [], "children": children}
            # `org.gtk.Actions.Changed` fires for any action on any object -
            # `win.edit.undo` flips the moment someone types a character -
            # and rebuilding is cheap only compared to sending. An unchanged
            # tree is not worth a vsock round trip or a menu bar rebuild on
            # the Mac, and a burst of typing would otherwise send one per
            # keystroke.
            signature = json.dumps(menu, separators=(",", ":"), sort_keys=True)
            if signature == app["sent"]:
                return False
            app["sent"] = signature
            remember_exporter(app["link"].name)
            log("%s sent %d top-level menus to %s" % (name, len(children), app["link"].name))
            app["link"].send({"t": "menu", "window": app["window"], "menu": menu})
            return False

        def gtk_activate(self, name, item_id):
            app = self.gtk.get(name)
            if app is None:
                return
            action, target = app["items"].get(item_id, (None, None))
            if not action:
                return
            described = app["actions"].get(action)
            if described is None:
                log("%s has no action %s" % (name, action))
                return
            arguments = []
            if target is not None and described["signature"]:
                try:
                    arguments = [GLib.Variant(described["signature"], target)]
                except (TypeError, ValueError) as error:
                    log("cannot pass %r to %s: %s" % (target, action, error))
                    return
            self.bus.call(name, described["path"], GTK_ACTIONS, "Activate",
                          GLib.Variant("(sava{sv})", (described["short"], arguments, {})),
                          None, Gio.DBusCallFlags.NONE, 5000, None, None, None)

        def on_about_to_show(self, bus, result, window_id):
            try:
                needs_update = bus.call_finish(result).unpack()[0]
            except GLib.Error:
                return
            if needs_update:
                self.schedule_refresh(window_id)


    def main(argv):
        ready_file = None
        if len(argv) >= 2 and argv[0] == "--ready-file":
            ready_file = argv[1]
        Bridge(ready_file).run()
        return 0


    if __name__ == "__main__":
        sys.exit(main(sys.argv[1:]))

    """#
}
