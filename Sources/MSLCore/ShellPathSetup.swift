import Foundation

/// Puts `msl` on the PATH of the user's own shells, with no password.
///
/// `/usr/local/bin/msl` needs root and can point at an app that isn't there
/// (2026-09-16: the package linked to /Applications/MSL.app while MSL ran from
/// somewhere else, and `msl` was "command not found" twice over). The shell
/// startup files are the user's, so MSL can keep them right on every launch:
/// a marked block in `~/.zprofile` and `~/.zshrc` (Terminal.app opens login
/// shells; other terminals open plain interactive ones) and in bash's login
/// file.
///
/// The block adds a directory holding only an `msl` link - never `bin/`,
/// which also holds mslhd, the X11 hosts and Linux binaries that have no
/// business on a Mac PATH. It is guarded, so sourcing a file twice doesn't
/// grow PATH, and `msl uninstall` removes it.
public enum ShellPathSetup {
    public static let beginMarker = "# >>> MSL >>>"
    public static let endMarker = "# <<< MSL <<<"

    /// `~/Library/Application Support/MSL/cli` - the directory on PATH.
    public static func commandDirectory(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("cli", isDirectory: true)
    }

    /// The block, written with `$HOME` so it survives a renamed account and
    /// reads plainly to anyone who opens the file.
    public static func block(home: URL, appSupport: URL) -> String {
        var directory = commandDirectory(appSupport: appSupport).path
        if directory.hasPrefix(home.path + "/") {
            directory = "$HOME" + directory.dropFirst(home.path.count)
        }
        return """
        \(beginMarker)
        # Lets you type msl in Terminal. Added by MSL; removed by msl uninstall.
        case ":$PATH:" in *":\(directory):"*) ;; *) export PATH="\(directory):$PATH" ;; esac
        \(endMarker)

        """
    }

    /// The files the block belongs in. Bash reads only the *first* of
    /// `.bash_profile`, `.bash_login` and `.profile` it finds, so creating a
    /// `.bash_profile` next to an existing `.profile` would silently stop
    /// bash reading the user's `.profile` - the block goes into whichever one
    /// bash already uses.
    public static func profileFiles(home: URL) -> [URL] {
        let fm = FileManager.default
        let bashCandidates = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
        let bash = bashCandidates.first { fm.fileExists(atPath: $0.path) } ?? bashCandidates[0]
        return [home.appendingPathComponent(".zprofile"), home.appendingPathComponent(".zshrc"), bash]
    }

    /// `text` with MSL's block removed, or unchanged if it has none.
    public static func removingBlock(from text: String) -> String {
        guard let start = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else { return text }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return String(text[..<start.lowerBound]) + String(text[upper...])
    }

    /// `text` with exactly one, current block at the end.
    public static func addingBlock(to text: String, home: URL, appSupport: URL) -> String {
        var result = removingBlock(from: text)
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty, !result.hasSuffix("\n\n") { result += "\n" }
        return result + block(home: home, appSupport: appSupport)
    }

    /// Makes the link and the blocks current. Returns the files it changed -
    /// empty when everything was already right, which is every launch but
    /// the first. A file that can't be written is skipped, never fatal.
    @discardableResult
    public static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               appSupport: URL = MSLPaths.appSupport) -> [URL] {
        let fm = FileManager.default
        let directory = commandDirectory(appSupport: appSupport)
        let link = directory.appendingPathComponent("msl")
        // Relative, so it keeps working if Application Support is restored
        // from a backup under another home folder.
        let target = "../bin/msl"
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target {
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }

        var changed: [URL] = []
        for file in profileFiles(home: home) {
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let updated = addingBlock(to: existing, home: home, appSupport: appSupport)
            guard updated != existing else { continue }
            // Written in place, not atomically: a profile is often a symlink
            // into a dotfiles repo, and an atomic write replaces the link.
            do {
                if fm.fileExists(atPath: file.path) {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data(updated.utf8))
                } else {
                    try Data(updated.utf8).write(to: file)
                }
                changed.append(file)
            } catch {
                continue
            }
        }
        return changed
    }

    /// Whether every profile already carries the current block.
    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   appSupport: URL = MSLPaths.appSupport) -> Bool {
        let expected = block(home: home, appSupport: appSupport)
        return profileFiles(home: home).allSatisfy {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(expected)
        }
    }

    /// Removes the blocks and the link directory - `msl uninstall`.
    @discardableResult
    public static func uninstall(home: URL, appSupport: URL, dryRun: Bool = false) -> [URL] {
        let fm = FileManager.default
        var changed: [URL] = []
        let candidates = [".zprofile", ".zshrc", ".bash_profile", ".bash_login", ".profile", ".bashrc"]
            .map { home.appendingPathComponent($0) }
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let updated = removingBlock(from: text)
            guard updated != text else { continue }
            changed.append(file)
            // A file holding nothing but MSL's block was made by MSL - take
            // it away rather than leave an empty ~/.bash_profile behind.
            if !dryRun, updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? fm.removeItem(at: file)
            } else if !dryRun, let handle = try? FileHandle(forWritingTo: file) {
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: Data(updated.utf8))
                try? handle.close()
            }
        }
        if !dryRun { try? fm.removeItem(at: commandDirectory(appSupport: appSupport)) }
        return changed
    }

    // MARK: - Terminals that are already open

    /// AppleScript that brings `msl` to every Terminal.app tab already open.
    ///
    /// A shell reads its profile once, at start, so windows opened before the
    /// block existed would keep saying "command not found". Terminal's
    /// dictionary exposes each tab's `busy` flag and its process list: only a
    /// tab sitting idle at a zsh or bash prompt gets the `source` line, typed
    /// with `do script … in tab`. A tab running vim, ssh or `msl` itself is
    /// never typed into. Does nothing - and asks nothing - when Terminal
    /// isn't running.
    public static func refreshOpenTerminalsScript(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let bashFile = "~/" + profileFiles(home: home)[2].lastPathComponent
        return refreshTemplate.replacingOccurrences(of: "@BASHFILE@", with: bashFile)
    }

    static let refreshTemplate = #"""
    if application "Terminal" is running then
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if not (busy of t) then
                            set procs to processes of t
                            if (count of procs) > 0 then
                                set shellName to last item of procs
                                if shellName ends with "zsh" then
                                    do script "source ~/.zprofile" in t
                                else if shellName ends with "bash" then
                                    do script "source @BASHFILE@" in t
                                end if
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end tell
    end if
    """#
}
