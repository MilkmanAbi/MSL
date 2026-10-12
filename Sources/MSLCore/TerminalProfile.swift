import Foundation

/// What the Mac terminal running `msl` can display, told to the Linux side.
///
/// shellinit runs as a system service with no `TERM` at all, and a pty
/// doesn't carry one across, so every guest shell started with none: `clear`
/// said "TERM environment variable not set", `apt` printed no colour, `less`
/// and `nano` guessed. The Mac side knows exactly which terminal it is in
/// (`TERM_PROGRAM`, `TERM`, `COLORTERM`), so `msl` passes that knowledge in
/// front of every session.
///
/// Two tiers, deliberately:
/// - **rich** for terminals known to render colour and Unicode properly:
///   Terminal.app, MSL's own Terminal tab, and the well-known third-party
///   ones. The guest gets `xterm-256color` (present in every distro's base
///   terminfo, unlike `xterm-kitty` or `alacritty`), UTF-8, and `COLORTERM`
///   where 24-bit colour is known to work.
/// - **plain** for anything else: `vt100`, `NO_COLOR`, the C locale. An
///   unknown terminal gets a boring but *certain* description; apps stop
///   probing, asking and printing escape codes it may not understand.
public enum TerminalProfile: Equatable, Sendable {
    case rich(truecolor: Bool)
    case plain

    /// Known terminals by `TERM_PROGRAM`, and whether they do 24-bit colour.
    static let knownPrograms: [String: Bool] = [
        "Apple_Terminal": false,   // 256 colours is its documented ceiling
        "MSL": true,               // SwiftTerm, the app's own Terminal tab
        "iTerm.app": true,
        "ghostty": true,
        "WezTerm": true,
        "vscode": true,
        "Hyper": true,
        "Tabby": true,
        "WarpTerminal": true,
        "zed": true,
    ]

    /// `TERM` values that identify a capable terminal that sets no
    /// `TERM_PROGRAM` (kitty, Alacritty, foot, and tmux/screen inside one).
    static let knownTermPrefixes = ["xterm-kitty", "alacritty", "foot", "wezterm", "ghostty",
                                    "tmux", "screen"]

    /// `nil` when there is no terminal on the Mac side at all (output piped
    /// or redirected): the guest's own `dumb` default is correct then.
    public static func detect(environment: [String: String], interactive: Bool) -> TerminalProfile? {
        guard interactive else { return nil }
        if let program = environment["TERM_PROGRAM"], let truecolor = knownPrograms[program] {
            return .rich(truecolor: truecolor || saysTruecolor(environment))
        }
        let term = environment["TERM"] ?? ""
        if knownTermPrefixes.contains(where: { term.hasPrefix($0) }) {
            return .rich(truecolor: true)
        }
        return .plain
    }

    private static func saysTruecolor(_ environment: [String: String]) -> Bool {
        let value = environment["COLORTERM"]?.lowercased() ?? ""
        return value == "truecolor" || value == "24bit"
    }

    /// Shell lines that set it up. `LANG` is only defaulted, never forced, in
    /// the rich tier - a guest with its own locale keeps it.
    public var exports: String {
        switch self {
        case .rich(let truecolor):
            return "export TERM=xterm-256color"
                + (truecolor ? " COLORTERM=truecolor" : "; unset COLORTERM")
                + "; unset NO_COLOR"
                // Every terminal in the rich tier handles ESC[3J. The guest
                // reads this back in `GuestIntegration.terminalShellLines`
                // to make `clear` actually clear - see there for why that is
                // not already true.
                + "; export MSL_CLEAR_SCROLLBACK=1"
                + #"; [ -n "${LANG-}" ] || export LANG=C.UTF-8"#
        case .plain:
            // No ESC[3J here: the plain tier is "a terminal we do not
            // recognise", and the whole point of it is to claim nothing.
            return "export TERM=vt100 NO_COLOR=1 LANG=C; unset COLORTERM MSL_CLEAR_SCROLLBACK"
        }
    }

    /// The command for an interactive session: the exports, then the user's
    /// login shell in place of this one, so the prompt is exactly what it
    /// would have been - just with a terminal it can describe.
    public var interactiveCommand: String {
        exports + "\n" + #"exec "${SHELL:-/bin/sh}" -l"#
    }
}
