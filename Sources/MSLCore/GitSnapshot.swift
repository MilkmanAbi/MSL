import Foundation

/// What MSL Files shows about a folder that is a git repository.
///
/// **The whole of this file is pure.** It builds shell scripts and parses
/// their output; it never runs anything. Running happens in the guest for a
/// Linux folder and on the Mac for a Mac one, and both hand their output
/// here - so the parsing is written and tested once, and the two sides
/// cannot drift into disagreeing about what a status line means.
///
/// Reading only. There is no push, pull or fetch, and that is deliberate:
/// those can need credentials, and a guest command has no terminal to ask
/// on, so one that wanted a password would hang until its timeout with the
/// person looking at a spinner. Anything that talks to a remote belongs in
/// a terminal where it can prompt.
/// What a `gitQuery` asks for. Deliberately a closed set of two rather than
/// a command string: a daemon request that ran arbitrary git would be a
/// request that ran arbitrary code, since git can be told to run a shell
/// through an alias, a hook or `-c core.pager`.
public enum GitOperation: String, Sendable, Equatable, CaseIterable {
    /// Read the folder's state. Writes nothing.
    case inspect
    /// Read every repository among a directory's subfolders, for their dots.
    /// Writes nothing, and runs on every directory opened.
    case badges
    /// `git init`, and only that.
    case initialise
    /// Point `origin` at a URL, or remove it when the URL is empty.
    case setOrigin
}

public enum Git {

    // MARK: - What a repository looks like

    /// One changed file, as `git status --porcelain=v1 -z` reports it.
    public struct Change: Equatable, Sendable {
        /// Path relative to the repository root.
        public let path: String
        /// The index (staged) column, and the worktree (unstaged) column.
        /// A space means "nothing in this column"; `?` in both means
        /// untracked.
        public let index: Character
        public let worktree: Character
        /// Set when the change is a rename or copy: where it came from.
        public let from: String?

        public init(path: String, index: Character, worktree: Character, from: String? = nil) {
            self.path = path
            self.index = index
            self.worktree = worktree
            self.from = from
        }

        public var isUntracked: Bool { index == "?" && worktree == "?" }
        public var isStaged: Bool { index != " " && index != "?" }
        public var isConflicted: Bool {
            index == "U" || worktree == "U"
                || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
        }

        /// A word for the change, for a person rather than for git.
        public var summary: String {
            if isConflicted { return "conflicted" }
            if isUntracked { return "untracked" }
            let column = isStaged ? index : worktree
            switch column {
            case "M": return isStaged ? "modified, staged" : "modified"
            case "A": return "added"
            case "D": return "deleted"
            case "R": return "renamed"
            case "C": return "copied"
            case "T": return "type changed"
            default: return "changed"
            }
        }
    }

    /// One commit from `git log`.
    public struct Commit: Equatable, Sendable {
        public let hash: String
        public let shortHash: String
        public let subject: String
        public let author: String
        public let date: Date?
        /// `HEAD -> main, origin/main, tag: v1.0` - empty for most commits.
        public let refs: String

        public init(hash: String, shortHash: String, subject: String,
                    author: String, date: Date?, refs: String) {
            self.hash = hash
            self.shortHash = shortHash
            self.subject = subject
            self.author = author
            self.date = date
            self.refs = refs
        }
    }

    /// Everything the panel shows about one folder.
    public struct Snapshot: Equatable, Sendable {
        /// The repository root, which may be above the folder looked at.
        public let root: String
        public let branch: String
        /// Empty when the repository has no `origin`.
        public let origin: String
        /// Commits this branch is ahead of / behind its upstream. Both zero
        /// when there is no upstream to compare against.
        public let ahead: Int
        public let behind: Int
        public let upstream: String
        public let changes: [Change]
        public let commits: [Commit]
        /// True when `git log` found nothing, which is a fresh `git init`
        /// rather than an error and reads very differently in the panel.
        public let isEmpty: Bool

        public init(root: String, branch: String, origin: String, ahead: Int, behind: Int,
                    upstream: String, changes: [Change], commits: [Commit], isEmpty: Bool) {
            self.root = root
            self.branch = branch
            self.origin = origin
            self.ahead = ahead
            self.behind = behind
            self.upstream = upstream
            self.changes = changes
            self.commits = commits
            self.isEmpty = isEmpty
        }

        public var isClean: Bool { changes.isEmpty }
        public var staged: [Change] { changes.filter { $0.isStaged && !$0.isConflicted } }
        public var unstaged: [Change] {
            changes.filter { !$0.isStaged && !$0.isUntracked && !$0.isConflicted }
        }
        public var untracked: [Change] { changes.filter(\.isUntracked) }
        public var conflicted: [Change] { changes.filter(\.isConflicted) }
    }

    /// One folder's dot in a listing.
    public struct Badge: Equatable, Sendable {
        public let branch: String
        /// How many entries `git status --porcelain` reported.
        public let changes: Int

        public init(branch: String, changes: Int) {
            self.branch = branch
            self.changes = changes
        }

        public var isClean: Bool { changes == 0 }

        /// What the dot says when you hover it. A count is more use than
        /// "dirty", and the branch is the thing people actually want to know
        /// at a glance.
        public var summary: String {
            isClean
                ? "git: clean on \(branch)"
                : "git: \(changes) change\(changes == 1 ? "" : "s") on \(branch)"
        }
    }

    /// Why there is no snapshot. Each of these is a sentence the panel shows,
    /// and they are distinguished because the right thing to offer differs:
    /// a folder that is not a repository gets an **Initialise** button, and a
    /// guest with no git installed gets told to install it.
    public enum Absence: Error, Equatable, Sendable {
        case notARepository
        case gitNotInstalled
        /// git refused to look - almost always its ownership check. Kept
        /// apart from `notARepository` because offering to initialise over
        /// the top of a repository that is really there would be worse than
        /// saying nothing.
        case refusedByGit
        case noSuchFolder
        case instanceNotRunning
        case commandLineToolsMissing
        case failed(String)

        public var sentence: String {
            switch self {
            case .notARepository: return "This folder is not a git repository."
            case .refusedByGit:
                return "git will not read this repository - it belongs to another user." 
            case .gitNotInstalled: return "git is not installed in this instance."
            case .noSuchFolder: return "That folder is no longer there."
            case .instanceNotRunning: return "Start the instance to see its repositories."
            case .commandLineToolsMissing:
                return "Install Xcode's Command Line Tools to use git on the Mac side."
            case .failed(let why): return why
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case repository(Snapshot)
        case absent(Absence)
    }

    // MARK: - The script

    /// How many commits the panel asks for. Enough to scroll, few enough that
    /// a large repository answers instantly.
    public static let logLimit = 50

    /// Separators chosen because git will not put them in a field: a record
    /// separator and a unit separator. `--format` writes them literally via
    /// `%x1e` / `%x1f`, so no amount of creative commit subject can forge a
    /// field boundary - which a newline or a `|` very much can.
    static let recordSeparator = "\u{1e}"
    static let unitSeparator = "\u{1f}"

    /// Every git invocation, pinned, and run as the folder's owner.
    ///
    /// **Reads do not run as root.** The daemon is root, and the obvious
    /// shortcut - root plus `safe.directory='*'` - defeats the check git
    /// added precisely to stop a repository's own config running commands as
    /// somebody else. `core.fsmonitor` and clean filters are ordinary config
    /// that git executes. Since the badge pass runs on every directory you
    /// visit, that shortcut would mean a crafted `.git/config` - out of an
    /// extracted archive, say - executing as root in the guest because
    /// somebody browsed past its folder. Dropping to the owner first makes
    /// git's own ownership check pass honestly instead of being waived.
    ///
    /// **`--no-optional-locks`, because `git status` writes.** Without it,
    /// status takes `.git/index.lock` and rewrites the index as a side
    /// effect. Harmless when a person runs it; not harmless when a file
    /// browser runs it on every folder, where it would race the commit they
    /// are typing in a terminal and fail it with "index.lock: File exists".
    ///
    /// The commands reach `su` through a **quoted here-document**, so no
    /// amount of quoting inside them has to survive anything - which matters
    /// because the log format is full of single quotes. The working
    /// directory is set before `su` and inherited through it, so no path ever
    /// enters the command text either.
    static func asOwnerRunning(_ commands: String) -> String {
        """
        owner=$(stat -c '%U' . 2>/dev/null || stat -f '%Su' . 2>/dev/null || echo "")
        if [ -z "${owner:-}" ] || [ "$(id -un)" = "$owner" ]; then
            runner() { /bin/sh; }
        else
            runner() { su -s /bin/sh "$owner"; }
        fi
        runner <<'MSLGITEOF'
        \(commands)
        MSLGITEOF
        """
    }

    /// The git preamble shared by every script: no prompting, no pager, no
    /// colour, no octal-escaped filenames, and no optional locks.
    static let gitPreamble = """
    g() {
      GIT_TERMINAL_PROMPT=0 git --no-optional-locks --no-pager \
        -c color.ui=false -c core.quotepath=false "$@"
    }
    """

    /// The script that reads one folder.
    ///
    /// It is handed over base64-encoded and decoded on the other side, so
    /// nothing here has to survive a round trip through a shell's quoting -
    /// which is the usual way a path with a space or a quote in it turns into
    /// a command that does something else entirely.
    public static func inspectScript(path: String) -> String {
        """
        set -u
        d=\(shellSingleQuoted(path))
        [ -d "$d" ] || { printf 'MSL:nodir\\n'; exit 0; }
        command -v git >/dev/null 2>&1 || { printf 'MSL:nogit\\n'; exit 0; }
        cd "$d" 2>/dev/null || { printf 'MSL:nodir\\n'; exit 0; }
        \(asOwnerRunning("""
        \(gitPreamble)
        # Separated from "not a repository", because git refusing to look is
        # not the same fact and must not offer to initialise over the top of
        # a repository that is really there.
        why=$(g rev-parse --show-toplevel 2>&1 >/dev/null)
        root=$(g rev-parse --show-toplevel 2>/dev/null)
        if [ -z "${root:-}" ]; then
          case "$why" in
            *dubious*|*ownership*|*denied*) printf 'MSL:denied\\n' ;;
            *) printf 'MSL:norepo\\n' ;;
          esac
          exit 0
        fi
        printf 'MSL:root %s\\n' "$root"
        printf 'MSL:branch %s\\n' "$(g rev-parse --abbrev-ref HEAD)"
        printf 'MSL:origin %s\\n' "$(g remote get-url origin 2>/dev/null || true)"
        up=$(g rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
        if [ -n "${up:-}" ]; then
          printf 'MSL:upstream %s\\n' "$up"
          printf 'MSL:counts %s\\n' "$(g rev-list --left-right --count "$up"...HEAD | tr '\\t' ' ')"
        fi
        printf 'MSL:log\\n'
        g log -\(logLimit) --format='%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%D%x1f%s'
        printf '\\nMSL:status\\n'
        g status --porcelain=v1 -z --untracked-files=normal
        printf '\\nMSL:end\\n'
        """))
        """
    }

    /// `git init`, and only that.
    ///
    /// Runs as the folder's owner. A repository created by root inside
    /// somebody's home directory leaves a `.git` they cannot write, so their
    /// very next commit fails - the feature would have broken the thing it
    /// offered to set up.
    public static func initialiseScript(path: String) -> String {
        """
        set -u
        d=\(shellSingleQuoted(path))
        [ -d "$d" ] || { printf 'MSL:nodir\\n'; exit 0; }
        command -v git >/dev/null 2>&1 || { printf 'MSL:nogit\\n'; exit 0; }
        cd "$d" 2>/dev/null || { printf 'MSL:nodir\\n'; exit 0; }
        \(asOwnerRunning("""
        GIT_TERMINAL_PROMPT=0 git init -q && printf 'MSL:ok\\n'
        """))
        """
    }

    /// Points `origin` somewhere, creating it if there is none.
    ///
    /// A write to `.git/config`, so it runs as the owner like `init` does.
    /// The URL is validated before it ever reaches here - see `isUsableRemote`
    /// - and `--` stops a URL beginning with a dash being read as an option.
    public static func setOriginScript(path: String, url: String) -> String {
        """
        set -u
        d=\(shellSingleQuoted(path))
        u=\(shellSingleQuoted(url))
        [ -d "$d" ] || { printf 'MSL:nodir\\n'; exit 0; }
        command -v git >/dev/null 2>&1 || { printf 'MSL:nogit\\n'; exit 0; }
        cd "$d" 2>/dev/null || { printf 'MSL:nodir\\n'; exit 0; }
        export MSL_REMOTE_URL="$u"
        \(asOwnerRunning("""
        \(gitPreamble)
        g rev-parse --git-dir >/dev/null 2>&1 || { printf 'MSL:norepo\\n'; exit 0; }
        if [ -z "${MSL_REMOTE_URL:-}" ]; then
          g remote remove origin >/dev/null 2>&1
          printf 'MSL:ok\\n'
        elif g remote get-url origin >/dev/null 2>&1; then
          g remote set-url origin -- "$MSL_REMOTE_URL" && printf 'MSL:ok\\n'
        else
          g remote add origin -- "$MSL_REMOTE_URL" && printf 'MSL:ok\\n'
        fi
        """))
        """
    }

    /// Reads every repository among a directory's immediate subfolders, in
    /// one pass.
    ///
    /// **One round trip for the whole listing, not one per folder.** This
    /// runs every time a directory is opened, so the shape that matters is
    /// the number of guest commands, and that is exactly one however many
    /// folders are on screen.
    ///
    /// Each repository is bounded by `timeout`, and the number looked at is
    /// capped: a folder full of large checkouts must not make opening it
    /// slow. A repository that times out simply produces no record, and so
    /// shows no dot - never a green one, which would be the same kind of
    /// confident lie as reporting an unreadable repository as empty.
    public static func badgesScript(directory: String, limit: Int = badgeLimit) -> String {
        """
        set -u
        cd \(shellSingleQuoted(directory)) 2>/dev/null || exit 0
        command -v git >/dev/null 2>&1 || exit 0
        n=0
        for entry in * .[!.]*; do
          [ -d "$entry" ] || continue
          # `.git` is a FILE in a submodule or a linked worktree, so testing
          # for a directory alone would miss both.
          [ -e "$entry/.git" ] || continue
          n=$((n + 1))
          [ "$n" -le \(limit) ] || break
          ( cd "$entry" 2>/dev/null || exit 0
        \(asOwnerRunning("""
        \(gitPreamble)
        b=$(timeout 5 git --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
        [ -n "${b:-}" ] || exit 0
        c=$(timeout 5 git --no-optional-locks status --porcelain=v1 \\
              --untracked-files=normal 2>/dev/null | wc -l) || exit 0
        printf 'MSLB%s%s%s%s%s' "$(printf '\\037')" "$b" "$(printf '\\037')" "$c" "$(printf '\\036')"
        """))
          printf '%s' "$entry"
          printf '\\000'
          )
        done
        """
    }

    /// How many repositories one listing will look at.
    public static let badgeLimit = 60

    /// Whether a string is safe and sensible to hand to `git remote`.
    ///
    /// A leading dash would be read as an option however it is quoted, which
    /// is the one way a remote URL can become a command. Control characters
    /// have no business in a URL and are how a value smuggles a newline into
    /// a config file.
    public static func isUsableRemote(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }

    /// The web page for a remote, for the button that opens it.
    ///
    /// Only for the two shapes that certainly have one. A `file://` or plain
    /// path remote has no web page, and guessing one would send somebody to a
    /// address that does not exist.
    public static func webURL(forRemote remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        if text.hasPrefix("https://") || text.hasPrefix("http://") {
            return URL(string: text)
        }
        // git@host:owner/repo
        if text.hasPrefix("git@"), let colon = text.firstIndex(of: ":") {
            let host = String(text[text.index(text.startIndex, offsetBy: 4)..<colon])
            let path = String(text[text.index(after: colon)...])
            return URL(string: "https://\(host)/\(path)")
        }
        if text.hasPrefix("ssh://git@") {
            return URL(string: "https://" + String(text.dropFirst("ssh://git@".count)))
        }
        return nil
    }

    /// Wraps a script so it survives being passed as one shell word.
    ///
    /// The script is base64 on the wire and decoded where it runs, which
    /// means no layer in between - the exec framing, a shell, a `su` - ever
    /// sees its quotes, newlines or `$`.
    public static func wrapped(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "printf %s \(encoded) | base64 -d | /bin/sh"
    }

    /// Single-quotes a string for `/bin/sh`: the only character that needs
    /// care inside single quotes is the single quote itself.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Parsing

    /// Strips carriage returns, whatever they are attached to.
    ///
    /// **A guest command comes back with `\r\n`**, because it runs through a
    /// pty. That alone would be unremarkable, except that in Swift `\r\n` is
    /// a single `Character` - one grapheme cluster - so the obvious defences
    /// against it both quietly fail: `contains("\r")` is **false** on a
    /// string full of CRLF, and `split(separator: "\n")` does not split
    /// those lines at all.
    ///
    /// The result was not a parse error but a confident lie. The whole reply
    /// arrived as one "line", so only the first marker matched, the section
    /// markers were never found, and every repository in an instance was
    /// reported as a new one with nothing committed yet.
    ///
    /// Working in unicode scalars sidesteps the grapheme clustering
    /// entirely, which neither a `replacingOccurrences(of: "\r")` nor a
    /// trim of `.whitespacesAndNewlines` reliably does.
    static func withoutCarriageReturns(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where scalar != "\r" { scalars.append(scalar) }
        return String(scalars)
    }

    /// Reads what `inspectScript` printed.
    public static func parse(_ raw: String) -> Outcome {
        let output = withoutCarriageReturns(raw)
        if output.contains("MSL:nodir") { return .absent(.noSuchFolder) }
        if output.contains("MSL:nogit") { return .absent(.gitNotInstalled) }
        if output.contains("MSL:denied") { return .absent(.refusedByGit) }
        if output.contains("MSL:norepo") { return .absent(.notARepository) }
        guard output.contains("MSL:root ") else {
            // No marker at all: the command did not get as far as running,
            // so saying "not a repository" would be a guess dressed as a
            // fact.
            return .absent(.failed("git did not answer."))
        }

        var root = "", branch = "", origin = "", upstream = ""
        var ahead = 0, behind = 0

        // The header is line-based; the log and status sections are not, so
        // they are cut out by marker rather than scanned line by line.
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let value = after("MSL:root ", in: text) { root = value }
            else if let value = after("MSL:branch ", in: text) { branch = value }
            else if let value = after("MSL:origin ", in: text) { origin = value }
            else if let value = after("MSL:upstream ", in: text) { upstream = value }
            else if let value = after("MSL:counts ", in: text) {
                // `--left-right --count upstream...HEAD` prints "behind ahead".
                let numbers = value.split(separator: " ").compactMap { Int($0) }
                if numbers.count == 2 { behind = numbers[0]; ahead = numbers[1] }
            }
        }

        let commits = parseLog(section(of: output, from: "MSL:log\n", to: "\nMSL:status"))
        let changes = parseStatus(section(of: output, from: "MSL:status\n", to: "\nMSL:end"))

        return .repository(Snapshot(
            root: root, branch: branch.isEmpty ? "HEAD" : branch, origin: origin,
            ahead: ahead, behind: behind, upstream: upstream,
            changes: changes, commits: commits, isEmpty: commits.isEmpty))
    }

    /// `git log --format='%x1e<hash>%x1f<short>%x1f<author>%x1f<date>%x1f<refs>%x1f<subject>'`
    public static func parseLog(_ text: String) -> [Commit] {
        let formatter = ISO8601DateFormatter()
        return text.components(separatedBy: recordSeparator).compactMap { record in
            let fields = record.components(separatedBy: unitSeparator)
            // A subject may be empty, but every separator must be there.
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            return Commit(
                hash: fields[0],
                shortHash: fields[1],
                // The subject is last and may itself contain newlines from a
                // `--format` that ran into the next record's leading text, so
                // it is trimmed rather than taken raw.
                subject: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
                author: fields[2],
                date: formatter.date(from: fields[3]),
                refs: fields[4])
        }
    }

    /// `git status --porcelain=v1 -z`.
    ///
    /// **`-z` is not just about newlines in filenames.** In `-z` a rename is
    /// two NUL-terminated entries - the new path then the old one - rather
    /// than the `old -> new` of the text format, so a path containing the
    /// literal characters ` -> ` cannot be split in the wrong place.
    public static func parseStatus(_ text: String) -> [Change] {
        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [Change] = []
        var pendingRenameFrom: String?
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1
            // "XY path", so anything shorter is not a status record.
            guard record.count > 3 else { continue }
            let columns = Array(record.prefix(2))
            let path = String(record.dropFirst(3))

            if columns[0] == "R" || columns[0] == "C" || columns[1] == "R" || columns[1] == "C" {
                // The next record is where it came from.
                pendingRenameFrom = index < records.count ? records[index] : nil
                if pendingRenameFrom != nil { index += 1 }
            }
            changes.append(Change(path: path, index: columns[0], worktree: columns[1],
                                  from: pendingRenameFrom))
            pendingRenameFrom = nil
        }
        return changes
    }

    /// Reads what `badgesScript` printed, keyed by folder name.
    ///
    /// Records are NUL-separated because a folder name may contain anything
    /// a filesystem allows, newlines and tabs included, and the fields within
    /// one record use the same unit and record separators as the log - for
    /// the same reason, that a branch name cannot contain them.
    ///
    /// **A record without git's part is skipped, not guessed.** The folder
    /// name is printed by the outer shell and the git data by the inner one,
    /// so a repository that timed out or refused leaves its name with nothing
    /// attached. That folder gets no dot. Showing green there would be the
    /// same confident lie as reporting an unreadable repository as empty.
    public static func parseBadges(_ raw: String) -> [String: Badge] {
        var badges: [String: Badge] = [:]
        for chunk in withoutCarriageReturns(raw).split(separator: "\0",
                                                       omittingEmptySubsequences: true) {
            let parts = chunk.split(separator: recordSeparator.first!,
                                    maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[1])
            guard !name.isEmpty else { continue }

            let fields = parts[0].split(separator: unitSeparator.first!,
                                        omittingEmptySubsequences: false)
            // "MSLB", branch, count
            guard fields.count == 3, fields[0].hasSuffix("MSLB"),
                  let changes = Int(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            let branch = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { continue }
            badges[name] = Badge(branch: branch, changes: changes)
        }
        return badges
    }

    // MARK: - Small helpers

    private static func after(_ marker: String, in line: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func section(of text: String, from start: String, to end: String) -> String {
        guard let lower = text.range(of: start) else { return "" }
        let rest = text[lower.upperBound...]
        guard let upper = rest.range(of: end) else { return String(rest) }
        return String(rest[..<upper.lowerBound])
    }
}
