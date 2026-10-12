import XCTest
@testable import MSLCore

/// The git reading MSL Files does, tested against output shaped exactly as
/// git writes it - NUL-separated status records and unit-separated log
/// fields - because every interesting bug in parsing git is a separator
/// appearing inside a field rather than between two.
final class GitSnapshotTests: XCTestCase {

    private func inspectOutput(log: String = "", status: String = "",
                               header: String = "MSL:root /home/u/p\nMSL:branch main\n") -> String {
        "\(header)MSL:log\n\(log)\nMSL:status\n\(status)\nMSL:end\n"
    }

    // MARK: - Absences

    func testEachAbsenceIsDistinguished() {
        XCTAssertEqual(Git.parse("MSL:nodir\n"), .absent(.noSuchFolder))
        XCTAssertEqual(Git.parse("MSL:nogit\n"), .absent(.gitNotInstalled))
        XCTAssertEqual(Git.parse("MSL:norepo\n"), .absent(.notARepository))
    }

    /// Nothing came back at all. Reporting "not a repository" here would be a
    /// guess presented as a fact, and the panel would offer to initialise a
    /// repository that may already exist.
    func testSilenceIsNotMistakenForNotARepository() {
        guard case .absent(.failed) = Git.parse("") else {
            return XCTFail("empty output must not read as a definite answer")
        }
    }

    // MARK: - The header

    func testAheadAndBehindAreNotSwapped() {
        // `--left-right --count upstream...HEAD` prints behind first.
        let output = inspectOutput(header: """
            MSL:root /home/u/p
            MSL:branch main
            MSL:upstream origin/main
            MSL:counts 3 7

            """)
        guard case .repository(let snapshot) = Git.parse(output) else { return XCTFail("expected a repo") }
        XCTAssertEqual(snapshot.behind, 3)
        XCTAssertEqual(snapshot.ahead, 7)
        XCTAssertEqual(snapshot.upstream, "origin/main")
    }

    func testARepositoryWithNoCommitsIsEmptyNotBroken() {
        guard case .repository(let snapshot) = Git.parse(inspectOutput()) else {
            return XCTFail("expected a repo")
        }
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.isClean)
        XCTAssertEqual(snapshot.branch, "main")
    }

    // MARK: - The log

    func testCommitFieldsAreReadInOrder() {
        let rs = Git.recordSeparator, us = Git.unitSeparator
        let log = "\(rs)abc123def\(us)abc123d\(us)Abi\(us)2026-10-12T17:02:31+01:00"
                + "\(us)HEAD -> main, origin/main\(us)Make the thing work"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(log: log)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.commits.count, 1)
        let commit = snapshot.commits[0]
        XCTAssertEqual(commit.hash, "abc123def")
        XCTAssertEqual(commit.shortHash, "abc123d")
        XCTAssertEqual(commit.author, "Abi")
        XCTAssertEqual(commit.subject, "Make the thing work")
        XCTAssertEqual(commit.refs, "HEAD -> main, origin/main")
        XCTAssertNotNil(commit.date)
    }

    /// A commit subject is written by a person, so it can contain anything -
    /// including a newline, which is why the records are separated by a
    /// character git will not emit rather than by a line break.
    func testASubjectContainingANewlineDoesNotSplitTheLog() {
        let rs = Git.recordSeparator, us = Git.unitSeparator
        let log = "\(rs)h1\(us)h1\(us)A\(us)2026-10-12T00:00:00Z\(us)\(us)first"
                + "\(rs)h2\(us)h2\(us)B\(us)2026-10-11T00:00:00Z\(us)\(us)second"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(log: log)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.commits.map(\.hash), ["h1", "h2"])
        XCTAssertEqual(snapshot.commits.map(\.subject), ["first", "second"])
    }

    // MARK: - Status

    func testStagedUnstagedAndUntrackedAreSeparated() {
        let status = "M  staged.txt\0 M unstaged.txt\0?? new.txt\0"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(status: status)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.staged.map(\.path), ["staged.txt"])
        XCTAssertEqual(snapshot.unstaged.map(\.path), ["unstaged.txt"])
        XCTAssertEqual(snapshot.untracked.map(\.path), ["new.txt"])
        XCTAssertFalse(snapshot.isClean)
    }

    /// In `-z` a rename is two records: the new path, then the old one. Read
    /// as one record each, the old path becomes a phantom second change.
    func testARenameIsOneChangeNotTwo() {
        let status = "R  after.txt\0before.txt\0 M other.txt\0"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(status: status)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.changes.count, 2)
        XCTAssertEqual(snapshot.changes[0].path, "after.txt")
        XCTAssertEqual(snapshot.changes[0].from, "before.txt")
        XCTAssertEqual(snapshot.changes[1].path, "other.txt")
    }

    /// The reason for `-z` that is easy to miss: a path may contain the
    /// literal text the non-`-z` format uses as its rename separator.
    func testAPathContainingAnArrowSurvives() {
        let status = "?? weird -> name.txt\0"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(status: status)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.untracked.map(\.path), ["weird -> name.txt"])
    }

    func testConflictsAreTheirOwnCategory() {
        let status = "UU both.txt\0AA added.txt\0"
        guard case .repository(let snapshot) = Git.parse(inspectOutput(status: status)) else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(snapshot.conflicted.count, 2)
        XCTAssertTrue(snapshot.staged.isEmpty, "a conflict is not a staged change")
    }

    // MARK: - Line endings

    /// **A guest command runs through a pty, so it answers in CRLF**, and in
    /// Swift `\r\n` is a single `Character`. That makes the two obvious
    /// defences silently useless: `contains("\r")` is false on a string full
    /// of CRLF, and `split(separator: "\n")` does not split those lines.
    ///
    /// Before this was handled the parser did not fail - it reported every
    /// repository inside an instance as a new one with nothing committed,
    /// which is a lie that looks exactly like a true answer.
    func testCrlfOutputIsReadTheSameAsLf() {
        let rs = Git.recordSeparator, us = Git.unitSeparator
        let body = "MSL:root /home/u/p\nMSL:branch master\nMSL:log\n"
                 + "\(rs)h1\(us)h1\(us)A\(us)2026-10-12T00:00:00Z\(us)\(us)only commit"
                 + "\nMSL:status\n M a.txt\0?? new.txt\0\nMSL:end\n"

        guard case .repository(let unix) = Git.parse(body) else {
            return XCTFail("the LF form must parse")
        }
        guard case .repository(let dos) = Git.parse(body.replacingOccurrences(of: "\n",
                                                                              with: "\r\n")) else {
            return XCTFail("the CRLF form must parse")
        }
        XCTAssertEqual(dos.branch, "master")
        XCTAssertEqual(dos.branch, unix.branch)
        XCTAssertEqual(dos.commits.count, 1)
        XCTAssertEqual(dos.commits.map(\.subject), unix.commits.map(\.subject))
        XCTAssertEqual(dos.changes.map(\.path), unix.changes.map(\.path))
        XCTAssertFalse(dos.isEmpty, "a repository with a commit must not read as empty")
    }

    /// The trap that made the above worth a test of its own.
    func testCarriageReturnsAreStrippedDespiteGraphemeClustering() {
        let crlf = "a\r\nb\r\n"
        XCTAssertFalse(crlf.contains("\r"), "if this ever becomes true, Swift changed")
        XCTAssertEqual(Git.withoutCarriageReturns(crlf), "a\nb\n")
    }

    // MARK: - Badges

    private func badgeRecord(_ name: String, _ branch: String, _ changes: Int) -> String {
        "MSLB\(Git.unitSeparator)\(branch)\(Git.unitSeparator)\(changes)"
            + "\(Git.recordSeparator)\(name)\0"
    }

    func testBadgesAreReadPerFolder() {
        let output = badgeRecord("clean", "main", 0) + badgeRecord("dirty", "main", 3)
        let badges = Git.parseBadges(output)
        XCTAssertEqual(badges.count, 2)
        XCTAssertTrue(badges["clean"]?.isClean == true)
        XCTAssertFalse(badges["dirty"]?.isClean == true)
        XCTAssertEqual(badges["dirty"]?.changes, 3)
    }

    /// **A repository that timed out or refused must show no dot.** The
    /// folder name is printed by the outer shell and git's part by the inner
    /// one, so a repository that failed leaves a name with nothing attached.
    /// Treating that as clean would be green for a repository nobody
    /// successfully read - the same confident lie as the CRLF bug.
    func testAFolderWithNoGitAnswerGetsNoBadge() {
        let output = badgeRecord("ok", "main", 0) + "timedout\0"
        let badges = Git.parseBadges(output)
        XCTAssertEqual(Array(badges.keys), ["ok"])
        XCTAssertNil(badges["timedout"])
    }

    /// Folder names are whatever a filesystem allows, which is why the
    /// records are NUL-separated and the fields use characters git will not
    /// emit.
    func testAFolderNameWithATabOrNewlineSurvives() {
        let awkward = "my\tproject\nv2"
        let badges = Git.parseBadges(badgeRecord(awkward, "main", 1))
        XCTAssertEqual(badges[awkward]?.changes, 1)
    }

    func testBadgesSurviveCrlf() {
        let output = badgeRecord("repo", "main", 2).replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(Git.parseBadges(output)["repo"]?.changes, 2)
    }

    func testNoRepositoriesMeansNoBadges() {
        XCTAssertTrue(Git.parseBadges("").isEmpty)
        XCTAssertTrue(Git.parseBadges("\0\0").isEmpty)
    }

    func testTheSummaryCountsRatherThanJustSayingDirty() {
        XCTAssertEqual(Git.Badge(branch: "main", changes: 0).summary, "git: clean on main")
        XCTAssertEqual(Git.Badge(branch: "dev", changes: 1).summary, "git: 1 change on dev")
        XCTAssertEqual(Git.Badge(branch: "dev", changes: 4).summary, "git: 4 changes on dev")
    }

    /// `.git` is a file, not a directory, in a submodule and in a linked
    /// worktree - testing only for a directory misses both.
    func testTheBadgeScriptAcceptsAGitFileNotJustADirectory() {
        let script = Git.badgesScript(directory: "/p")
        XCTAssertTrue(script.contains("[ -e \"$entry/.git\" ]"))
        XCTAssertFalse(script.contains("[ -d \"$entry/.git\" ]"))
    }

    func testTheBadgeScriptIsBoundedAndCapped() {
        let script = Git.badgesScript(directory: "/p", limit: 12)
        XCTAssertTrue(script.contains("-le 12"), "the number of repositories must be capped")
        XCTAssertTrue(script.contains("timeout 5"), "each repository must be bounded")
    }

    // MARK: - Running as the owner

    /// **Reads must not run as root with git's ownership check waived.** That
    /// check exists because a repository's own config can name commands git
    /// will execute - `core.fsmonitor`, clean filters - and the badge pass
    /// runs on every directory opened, so a crafted `.git/config` would run
    /// without anybody clicking anything.
    ///
    /// Verified live as well: with a `core.fsmonitor` hook planted in a guest
    /// repository, browsing ran it as the folder's owner, not as root.
    func testNoScriptWaivesGitsOwnershipCheck() {
        for script in [Git.inspectScript(path: "/p"),
                       Git.badgesScript(directory: "/p"),
                       Git.initialiseScript(path: "/p"),
                       Git.setOriginScript(path: "/p", url: "https://e.com/a.git")] {
            XCTAssertFalse(script.contains("safe.directory"),
                           "running as the owner is the fix; waiving the check is the bug")
        }
    }

    /// `git status` takes `.git/index.lock` and rewrites the index unless
    /// told not to. Harmless when a person runs it; not harmless on every
    /// folder you browse, where it races the commit being typed in a
    /// terminal.
    func testStatusNeverTakesTheIndexLock() {
        for script in [Git.inspectScript(path: "/p"), Git.badgesScript(directory: "/p")] {
            XCTAssertTrue(script.contains("--no-optional-locks"))
        }
    }

    // MARK: - Remotes

    func testARemoteBeginningWithADashIsRefused() {
        // However it is quoted, git reads a leading dash as an option.
        XCTAssertFalse(Git.isUsableRemote("--upload-pack=touch /tmp/x"))
        XCTAssertFalse(Git.isUsableRemote("-x"))
    }

    func testARemoteCarryingAControlCharacterIsRefused() {
        XCTAssertFalse(Git.isUsableRemote("https://e.com/a.git\nfetch = evil"))
        XCTAssertFalse(Git.isUsableRemote(""))
        XCTAssertFalse(Git.isUsableRemote("   "))
    }

    func testOrdinaryRemotesAreAccepted() {
        for url in ["https://github.com/a/b.git", "git@github.com:a/b.git",
                    "ssh://git@h/a/b.git", "/srv/git/b.git"] {
            XCTAssertTrue(Git.isUsableRemote(url), "\(url) should be allowed")
        }
    }

    /// Only the shapes that certainly have a web page. Guessing one for a
    /// `file://` remote would send somebody to an address that does not exist.
    func testOnlyRemotesWithAWebPageGetALink() {
        XCTAssertEqual(Git.webURL(forRemote: "git@github.com:a/b.git")?.absoluteString,
                       "https://github.com/a/b")
        XCTAssertEqual(Git.webURL(forRemote: "https://github.com/a/b.git")?.absoluteString,
                       "https://github.com/a/b")
        XCTAssertEqual(Git.webURL(forRemote: "ssh://git@github.com/a/b.git")?.absoluteString,
                       "https://github.com/a/b")
        XCTAssertNil(Git.webURL(forRemote: "/srv/git/b.git"))
        XCTAssertNil(Git.webURL(forRemote: "file:///srv/b.git"))
    }

    // MARK: - Scripts

    /// The scripts travel base64-encoded precisely so that no shell in
    /// between has to cope with what is in them.
    func testAPathWithAQuoteCannotEscapeItsScript() {
        let script = Git.inspectScript(path: "/home/u/it's a 'folder'")
        XCTAssertTrue(script.contains("'/home/u/it'\\''s a '\\''folder'\\'''"))
        // And once wrapped, the path is not in the command line at all.
        XCTAssertFalse(Git.wrapped(script).contains("folder"))
    }

    func testEveryInvocationIsPinned() {
        let script = Git.inspectScript(path: "/p")
        // No terminal to prompt on, no pager to hang in, no colour codes to
        // parse around, no octal-escaped filenames.
        XCTAssertTrue(script.contains("GIT_TERMINAL_PROMPT=0"))
        XCTAssertTrue(script.contains("--no-pager"))
        XCTAssertTrue(script.contains("color.ui=false"))
        XCTAssertTrue(script.contains("core.quotepath=false"))
    }

    /// Nothing here may reach a network, because a command that needs a
    /// credential has nowhere to ask for one and would hang until timeout.
    func testNothingTalksToARemote() {
        for script in [Git.inspectScript(path: "/p"), Git.initialiseScript(path: "/p")] {
            for forbidden in ["git push", "git pull", "git fetch", "git clone"] {
                XCTAssertFalse(script.contains(forbidden), "\(forbidden) must not be in a script")
            }
        }
    }

    /// Reading runs as root with the ownership check waived; `init` must not,
    /// or it leaves a `.git` the person cannot write to.
    func testInitialiseRunsAsTheFolderOwner() {
        let script = Git.initialiseScript(path: "/home/u/p")
        XCTAssertTrue(script.contains("stat -c '%U'"))
        XCTAssertTrue(script.contains("su -s /bin/sh"))
        XCTAssertFalse(script.contains("safe.directory"),
                       "init must not paper over ownership - it must get it right")
    }
}
