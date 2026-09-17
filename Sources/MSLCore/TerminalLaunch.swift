import Foundation

/// Builds the AppleScript that runs a command in a new Terminal.app window.
///
/// Two layers of quoting, and each one matters: Terminal types the command
/// into the user's login shell, so every word is shell-quoted first; that
/// command then sits inside an AppleScript string literal, so backslashes and
/// double quotes are escaped on top. Only the second layer used to exist, so
/// the path through "Application Support" split at the space and zsh said
/// `permission denied: /Users/…/Library/Application`.
public enum TerminalLaunch {
    /// `words` as one command line, safe for any POSIX shell.
    public static func shellCommand(_ words: [String]) -> String {
        words.map(DesktopEntry.shellQuote).joined(separator: " ")
    }

    public static func shellCommand(tool: String, instance: String) -> String {
        shellCommand([tool, instance])
    }

    public static func appleScript(_ words: [String]) -> String {
        let escaped = shellCommand(words)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    public static func appleScript(tool: String, instance: String) -> String {
        appleScript([tool, instance])
    }
}
