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
        File(path: "bin/msl-session", contents: sessionShell, executable: true),
        File(path: "bin/msl_menubridge.py", contents: menuBridgePython, executable: true),
        File(path: "share/applications/msl-open-url.desktop", contents: openURLDesktop, executable: false),
        File(path: "share/applications/msl-files.desktop", contents: filesDesktop, executable: false),
        // Both places: gio and current xdg-mime read the config dirs, older
        // xdg-mime only the data dirs.
        File(path: "share/applications/mimeapps.list", contents: mimeApps, executable: false),
        File(path: "config/mimeapps.list", contents: mimeApps, executable: false),
        File(path: "share/dbus-1/services/org.freedesktop.FileManager1.service", contents: fileManager1Service, executable: false),
    ]

    /// Changes whenever any file does, so an updated MSL rewrites the kit
    /// on the next launch and an unchanged one costs a single `cat`.
    static var stamp: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for file in files {
            for byte in Array(file.path.utf8) + [0] + Array(file.contents.utf8) + [file.executable ? 1 : 0] {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    /// A shell snippet that installs or refreshes the kit. Never fails the
    /// command it is part of: without the kit, apps simply keep using Linux
    /// handlers.
    public static func installCommand() -> String {
        var lines: [String] = [
            #"MSL_D="$HOME/\#(directory)""#,
            #"if [ "$(cat "$MSL_D/.stamp" 2>/dev/null)" != "\#(stamp)" ]; then"#,
            #"  mkdir -p "$MSL_D/bin" "$MSL_D/config" "$MSL_D/share/applications" "$MSL_D/share/dbus-1/services" && ("#,
        ]
        for file in files {
            let encoded = Data(file.contents.utf8).base64EncodedString()
            var line = #"    printf '%s' '\#(encoded)' | base64 -d | sed "s|@MSLDIR@|$MSL_D|g" > "$MSL_D/\#(file.path)""#
            if file.executable { line += #" && chmod 755 "$MSL_D/\#(file.path)""# }
            lines.append(line + " &&")
        }
        lines.append(#"    printf '%s' '\#(stamp)' > "$MSL_D/.stamp") || echo "msl: couldn't install the MSL integration kit" >&2"#)
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

    /// The line in front of a one-shot command from `msl <instance> <cmd>`.
    ///
    /// shellinit runs those as `sh -c`, not a login shell, so the profile
    /// line above never runs for them - and `msl debian gnome-chess` is the
    /// most natural way there is to open a Linux app from a Mac terminal.
    public static func oneShotDisplayPrefix() -> String {
        #"[ -n "${DISPLAY-}" ] || export DISPLAY="# + display + "\n" + appPathLine + "\n"
    }

    /// Where distros put programs that a non-login `sh -c` can't see.
    ///
    /// Debian and Ubuntu install games in `/usr/games` (gnome-chess,
    /// aisleriot), which only a *login* shell's PATH carries. Apps launched
    /// from MSL run through shellinit's plain `sh -c`, so their `.desktop`
    /// `Exec=gnome-chess` failed with exit 127 while typing the same word at
    /// a prompt worked (2026-09-16). Flatpak and snap export their launchers
    /// to directories that are likewise only on a login PATH.
    static let appPathLine =
        #"export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:/usr/local/games:/usr/games:/var/lib/flatpak/exports/bin:/snap/bin""#

    /// The full guest command that runs `command` as an MSL-launched app:
    /// on MSL's display, with the kit's handlers in front when the kit is
    /// installed, and under `msl-session` (a D-Bus session carrying the menu
    /// bridge) when the global menu bar is on.
    public static func launchCommand(_ command: String, settings: MSLExperimentalSettings) -> String {
        var lines: [String] = [
            "export DISPLAY=:1",
            appPathLine,
            #"MSL_D="$HOME/\#(directory)""#,
            #"if [ -f "$MSL_D/.stamp" ]; then"#,
            #"  export MSL_ORIG_XDG_DATA_DIRS="${XDG_DATA_DIRS-}" MSL_ORIG_XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS-}""#,
            #"  export XDG_DATA_DIRS="$MSL_D/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}""#,
            #"  export XDG_CONFIG_DIRS="$MSL_D/config:${XDG_CONFIG_DIRS:-/etc/xdg}""#,
        ]
        if settings.globalMenuBar {
            lines.append(#"  [ -x "$MSL_D/bin/msl-session" ] && exec "$MSL_D/bin/msl-session" sh -c \#(shellQuoted(command))"#)
        }
        lines.append("fi")
        lines.append(command)
        return lines.joined(separator: "\n")
    }

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
    import socket
    import sys
    from urllib.parse import unquote, urlparse

    HOST_CID = 2
    PORT = 5008


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


    def main(argv):
        if len(argv) < 2 or argv[0] not in ("url", "dir", "show"):
            print("usage: msl_open.py url|dir|show TARGET...", file=sys.stderr)
            return 2
        kind, targets = argv[0], argv[1:]
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

    static let filesDesktop = #"""
    [Desktop Entry]
    Type=Application
    Name=MSL Files
    Comment=MSL: shows folders in MSL Files on the Mac
    Exec=@MSLDIR@/bin/msl-open dir %u
    NoDisplay=true
    MimeType=inode/directory;

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

    /// Runs one app with a session bus of its own and the menu bridge on
    /// it. The bridge has to own `com.canonical.AppMenu.Registrar` before
    /// the app starts: Qt checks for it once, at startup, and never again.
    static let sessionShell = #"""
    #!/bin/sh
    # MSL: runs one Linux app with MSL's global menu bridge on its D-Bus
    # session. Installed by MSL (GuestIntegration.swift).
    D="@MSLDIR@"
    bus_pid=""
    bridge_pid=""
    if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v dbus-daemon >/dev/null 2>&1; then
        bus_info=$(mktemp)
        if dbus-daemon --session --fork --print-address=1 --print-pid=1 >"$bus_info" 2>/dev/null; then
            DBUS_SESSION_BUS_ADDRESS=$(sed -n 1p "$bus_info")
            bus_pid=$(sed -n 2p "$bus_info")
            export DBUS_SESSION_BUS_ADDRESS
        fi
        rm -f "$bus_info"
    fi
    if [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v python3 >/dev/null 2>&1; then
        ready=$(mktemp -u)
        python3 "$D/bin/msl_menubridge.py" --ready-file "$ready" &
        bridge_pid=$!
        tries=0
        while [ ! -e "$ready" ] && [ $tries -lt 30 ] && kill -0 "$bridge_pid" 2>/dev/null; do
            sleep 0.1
            tries=$((tries + 1))
        done
        rm -f "$ready"
    fi
    for module in /usr/lib/*/gtk-3.0/modules/libappmenu-gtk-module.so /usr/lib/gtk-3.0/modules/libappmenu-gtk-module.so; do
        if [ -e "$module" ]; then
            export GTK_MODULES="${GTK_MODULES:+$GTK_MODULES:}appmenu-gtk-module"
            export UBUNTU_MENUPROXY=1
            break
        fi
    done
    "$@"
    status=$?
    [ -n "$bridge_pid" ] && kill "$bridge_pid" 2>/dev/null
    [ -n "$bus_pid" ] && kill "$bus_pid" 2>/dev/null
    exit $status

    """#

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
    REGISTRAR = "com.canonical.AppMenu.Registrar"
    REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar"
    DBUSMENU = "com.canonical.dbusmenu"

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
            if self.ready_file:
                open(self.ready_file, "w").close()

        def on_name_lost(self, connection, name):
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
                return None
            link = self.links.get(name)
            if link is None or not link.alive:
                try:
                    link = HostLink(name, self.on_host_message)
                except OSError:
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
            if new_owner or not name.startswith(":"):
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
            except GLib.Error:
                return
            if window["link"] is None or not window["link"].alive:
                window["link"] = self.link_for(window["sender"])
            if window["link"] is not None:
                window["link"].send({"t": "menu", "window": window_id, "menu": convert(plain(layout))})

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
