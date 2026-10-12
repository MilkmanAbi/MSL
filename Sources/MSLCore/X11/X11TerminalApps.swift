import Foundation

/// Which Linux apps are terminal emulators, by `WM_CLASS`.
///
/// **Why this list decides anything.** Translating ⌘C to Ctrl+C is right in
/// every Linux app except the one place a Mac user is most likely to press
/// it: a terminal. There Ctrl+C is SIGINT, so a plain ⌘→Ctrl mapping kills
/// the running command instead of copying. The same trap catches ⌘Z
/// (suspend), ⌘D (EOF, closes the shell) and ⌘V (readline's literal-next).
/// A terminal wants **Ctrl+Shift** instead, which is what every major
/// terminal binds copy, paste, new tab and close tab to.
///
/// So `X11ShortcutRemapper` needs to know what it is talking to, and
/// `WM_CLASS` is the only reliable answer: the *process* name does not work
/// (GNOME Terminal's windows belong to `gnome-terminal-server`), and neither
/// does the window title, which is whatever the running command set it to.
///
/// The list is taken from **Toshy** (`RedBearAK/toshy`,
/// `default-toshy-config/toshy_config.py`), which maintains it for exactly
/// this purpose and is GPL-3.0 - the same licence as mslgd, where this file
/// lives. Matching is case-insensitive because `WM_CLASS` capitalisation is
/// inconsistent across toolkits ("Konsole" and "konsole" are both seen).
enum X11TerminalApps {
    /// Exact `WM_CLASS` matches, lowercased.
    private static let names: Set<String> = [
        "alacritty", "com.raggesilver.blackbox", "com.system76.cosmicterm",
        "contour", "cutefish-terminal", "deepin-terminal", "dev.warp.warp",
        "eterm", "gnome-terminal", "gnome-terminal-server", "guake", "hyper",
        "io.elementary.terminal", "kgx", "kitty", "konsole", "lxterminal",
        "mate-terminal", "mateterminal", "org.codeberg.dnkl.foot.desktop",
        "org.gnome.console", "org.gnome.terminal", "org.kde.konsole",
        "org.kde.yakuake", "org.wezfurlong.wezterm", "qterminal", "roxterm",
        "sakura", "st", "station", "tabby", "terminator", "terminology",
        "termite", "termius", "tilda", "tilix", "urxvt", "wave", "wezterm",
        "wezterm-gui", "xfce4-terminal", "xterm", "yakuake",
    ]

    /// Substrings, for the families that version their class name. Toshy
    /// carries these as regexes (`.*ghostty.*`); a `contains` is the same
    /// test without a regex engine.
    private static let fragments = ["ghostty", "ptyxis", "foot"]

    /// Terminals that do **not** bind Ctrl+Shift to copy and paste.
    ///
    /// **This distinction is the whole safety of the feature, and it was
    /// found the hard way.** Ctrl+Shift+C is a VTE/Konsole/kitty
    /// convention, not an X11 one. The classic X terminals never adopted it:
    /// they copy by selecting with the mouse (PRIMARY) and paste with the
    /// middle button. Send Ctrl+Shift+C to one of these and *nothing*
    /// intercepts it - Shift does not change the control character, so the
    /// pty receives the same 0x03 as a plain Ctrl+C and **interrupts the
    /// running command**. Measured in xterm on 2026-09-30: `sleep 300` died
    /// and `^C` appeared, with the terminal profile correctly applied.
    ///
    /// So these get no Command translation at all (see
    /// `X11ShortcutRemapper`). ⌘C doing nothing is a fair trade for ⌘C never
    /// killing someone's build, and it costs little in practice: these
    /// terminals' own copy has never been a key combination anyway.
    private static let withoutControlShift: Set<String> = ["xterm", "urxvt", "st", "eterm"]

    /// Whether a `WM_CLASS` names a terminal emulator.
    ///
    /// An unknown app is **not** a terminal: being wrong that way costs a
    /// Mac user ⌘C-as-copy in one obscure terminal, while being wrong the
    /// other way would send Ctrl+Shift+C to an ordinary app, where it means
    /// nothing. Silence beats a wrong guess.
    static func isTerminal(_ wmClass: String?) -> Bool {
        guard let name = normalised(wmClass) else { return false }
        if names.contains(name) { return true }
        return fragments.contains { name.contains($0) }
    }

    /// Whether this terminal understands Ctrl+Shift+C/V as copy and paste.
    /// `false` for the classic X terminals, where sending it would reach the
    /// pty as a plain Ctrl+C - see `withoutControlShift`.
    static func bindsControlShift(_ wmClass: String?) -> Bool {
        guard let name = normalised(wmClass), isTerminal(wmClass) else { return false }
        return !withoutControlShift.contains(name)
    }

    private static func normalised(_ wmClass: String?) -> String? {
        guard let wmClass, !wmClass.isEmpty else { return nil }
        return wmClass.lowercased()
    }
}
