import Foundation

// Chapter. How MSL updates itself, and what the version number means.

extension HelpChapter {
    static let updates = HelpChapter(
        id: "updates", title: "Updates", symbol: "arrow.down.circle", tint: .teal,
        blurb: "How MSL finds a new version, which releases it raises on its own, and what the version number tells you.",
        articles: [.updates, .updateVersions, .updateNotes])
}

extension HelpArticle {
    static let updates = HelpArticle(
        id: "updates", title: "How updating works", symbol: "arrow.down.circle",
        summary: "Where MSL looks for a new version, how often, and what it will and will not do on its own.",
        keywords: ["update", "upgrade", "new version", "release", "download", "check for updates", "github"],
        related: ["update-versions", "update-notes", "uninstalling-msl", "credits"],
        body: #"""
        MSL checks whether there is a newer version and tells you about it. Nothing is downloaded or replaced
        without you choosing it.

        ## What happens {#what}

        1. MSL reads the list of releases from its repository.
        2. It works out which of them are newer than the copy you are running.
        3. The newest one becomes the offer.
        4. Whether you are *told* depends on which number changed — see
           [Version numbers](help:update-versions).
        5. Choosing **Download and Update** fetches the installer, checks it is really that version, and then
           asks a second time before anything on this Mac is replaced.

        > [!NOTE] The download always finishes first
        > The new version is on disk and verified before the old one is touched. A download that fails, or that
        > you cancel, leaves the MSL you are running exactly as it was.

        ## Doing it yourself {#by-hand}

        **Check for Updates…** in the MSL menu asks right now, and answers in full: it ignores the once-a-day
        limit, a version you skipped, and the silence switch. Asking is asking.

        From a terminal:

        ```
        msl update              say what there is
        msl update --download   fetch and verify it into Downloads
        ```

        ## How often it looks {#frequency}

        Once a day at most. If the check fails — no network, GitHub unreachable — MSL waits an hour, then two,
        then four, up to a day, rather than asking again on every launch.

        A failed check is never reported as a problem. Not being able to reach the internet is not an MSL error.

        ## Every release is read, not just the newest {#ordering}

        The release list is ordered by **date published**, which is not the same as version order: a small fix
        to an older version can be published after a big new one, and would appear first. MSL reads them all and
        compares versions properly, so a 1.0.9 patch published last week never looks newer than 2.0.0.

        Tags with anything after a hyphen — `v3.0.0-rc1`, `v3.0.0-beta2` — are pre-releases. MSL recognises them
        and never offers them.
        """#)

    static let updateVersions = HelpArticle(
        id: "update-versions", title: "What the version number tells you", symbol: "number",
        summary: "MSL uses plain semantic versioning, and which of the three numbers changed decides whether you are interrupted.",
        keywords: ["version", "semver", "semantic versioning", "major", "minor", "patch", "release", "number"],
        related: ["updates", "update-notes"],
        body: #"""
        An MSL release is `major.minor.patch` and nothing more — plain semantic versioning, the same as
        everything else you install.

        ```
        v2.1.3
         │ │ └── patch: a fix
         │ └──── minor: new features
         └────── major: MSL itself changed
        ```

        ## Which releases MSL raises on its own {#announcing}

        | Changed | Example | What MSL does |
        |---|---|---|
        | **Patch** | 2.0.0 → 2.0.**1** | Nothing unasked. You see it when you check. |
        | **Minor** | 2.0.0 → 2.**1**.0 | Tells you it is there. |
        | **Major** | 2.0.0 → **3**.0.0 | Tells you, and to read the repository first. |

        ## Why a patch doesn't interrupt you {#patches}

        A patch release is a fix. An app that puts a window up for every third-number change teaches you to
        dismiss its windows, and then the one notice that mattered gets dismissed too.

        A fix is never hidden, though. **Check for Updates…** and `msl update` report every release there is,
        patches included, because at that point you came looking.

        ## Why a major version is different {#major}

        A minor release adds to the MSL you already know. A major one is where MSL itself changes — how
        something works, where something lives, what a setting means.

        So a major release still offers to install itself, but the first thing on the notice is the repository,
        because the thing to do first is read what changed.

        > [!NOTE] Your instances are never part of the version
        > Instances, their disks and their snapshots are yours and live separately. Updating MSL — by any of the
        > three numbers — replaces MSL and leaves them alone.
        """#)

    static let updateNotes = HelpArticle(
        id: "update-notes", title: "What the update notice tells you", symbol: "doc.text",
        summary: "Where the text in an update notice comes from, and what to read before taking one.",
        keywords: ["update notes", "release notes", "info", "changelog", "what's new", "notice"],
        related: ["updates", "update-versions"],
        body: #"""
        When there is a release worth telling you about, MSL shows the version, which of the three numbers
        changed, and whatever notes the release carries.

        ## Where the notes come from {#source}

        Each release ships a short plain-text file — `info.txt` — alongside the installer. MSL fetches that and
        shows it in the notice. It is written to lead with anything you have to do by hand.

        If a release has no such file, the notice says the release page has notes worth reading and points you
        there, rather than inventing a summary.

        ## What to check before updating {#before}

        - **Anything you must do by hand.** The notes lead with this when there is any.
        - **Whether instances need to be stopped.** MSL will tell you; when in doubt, stop them.
        - **For a major version, the repository.** That is what the notice points at first, and why.
        - **Your own settings.** Updating keeps them. A new version that turns something on by default changes
          only that switch, not choices you have made.

        > [!NOTE] Your instances are not touched
        > Updating MSL replaces MSL. Instances, their disks and their snapshots live separately and are left
        > exactly as they are. [Uninstalling](help:uninstalling-msl) explains where they live and what removing
        > MSL does and does not take with it.
        """#)
}
