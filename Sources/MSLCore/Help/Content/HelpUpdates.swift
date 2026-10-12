import Foundation

// Chapter. How MSL updates itself, and what the release tags mean.

extension HelpChapter {
    static let updates = HelpChapter(
        id: "updates", title: "Updates", symbol: "arrow.down.circle", tint: .teal,
        blurb: "How MSL finds a new version, why some releases are offered and others only mentioned, and what the tags mean.",
        articles: [.updates, .updateTags, .updateNotes])
}

extension HelpArticle {
    static let updates = HelpArticle(
        id: "updates", title: "How updating works", symbol: "arrow.down.circle",
        summary: "Where MSL looks for a new version, how often, and what it will and will not do on its own.",
        keywords: ["update", "upgrade", "new version", "release", "download", "check for updates", "github"],
        related: ["update-tags", "update-notes", "uninstalling-msl", "credits"],
        body: #"""
        MSL checks whether there is a newer version and tells you. It never downloads or replaces anything by
        itself.

        ## What happens {#what}

        1. MSL reads the list of releases from its repository.
        2. It works out which of them are newer than the copy you are running.
        3. Of those, it works out which ones are *meant* for your copy — see [Release tags](help:update-tags).
        4. The best one becomes the offer, and you are told about it.
        5. Choosing to update opens the release page in your browser. You download and install it yourself.

        > [!NOTE] Installing stays manual, deliberately
        > MSL runs a background service and a virtual machine with your files in it. Replacing its own binaries
        > underneath a running instance is not something it should do quietly while you are working.

        ## How often it looks {#frequency}

        Once a day at most. If the check fails — no network, the service is unreachable — MSL waits an hour,
        then two, then four, up to a day, rather than asking again on every launch.

        A failed check is never reported as a problem. Not being able to reach the internet is not an MSL error.

        ## Every release is read, not just the newest {#ordering}

        The release list is ordered by **date published**, which is not the same as version order: a small fix
        to an older version can be published after a big new one, and would appear first. MSL reads them all and
        compares versions properly, so a 1.0.9 patch published last week never looks newer than 2.0.0.
        """#)

    static let updateTags = HelpArticle(
        id: "update-tags", title: "Release tags: DNUO, UBP, FP and the rest", symbol: "tag",
        summary: "What the marker on a release tag means, and why a release can be mentioned without being offered.",
        keywords: ["tag", "marker", "DNUO", "UBP", "UBPDN", "FP", "FBDN", "minimum", "version", "patch", "release"],
        related: ["updates", "update-notes"],
        body: #"""
        A release tag can carry a marker saying who that release is for. It looks like this:

        ```
        v<major>.<minor>.<patch>[-<MARKER>[-<minimum>]]
        ```

        So `v2.4.0-UBP-2.1` is version 2.4.0, marked **UBP**, with a minimum of **2.1**.

        ## The markers {#markers}

        | Marker | Means | If you are below the minimum |
        |---|---|---|
        | *(none)* | An ordinary release | — |
        | **DNUO** | Do not update older installs | Never mentioned |
        | **UBP** | Unsafe-behaviour patch — offer it at once | Mentioned, but you cannot take it |
        | **UBPDN** | Unsafe-behaviour patch, newer installs only | Never mentioned |
        | **FP** | Feature patch | Mentioned, but you cannot take it |
        | **FBDN** | Feature patch, newer installs only | Never mentioned |

        ## What the minimum is for {#minimum}

        The minimum is the oldest version of MSL a release is any use to.

        A patch that fixes something introduced in 2.1 cannot help you if you are on 2.0 — the problem is not
        there. So `v2.4.0-UBP-2.1` is urgent for anyone on 2.1 or newer, and for anyone older it is merely
        *mentioned*: you are told it exists, and told it is not for your version.

        ## Mentioned, offered, or silent {#outcomes}

        This is the difference the **DN** in a marker makes:

        | | You are at or above the minimum | You are below it |
        |---|---|---|
        | **UBP** / **FP** | Offered | Mentioned, cannot be taken |
        | **UBPDN** / **FBDN** | Offered | Not mentioned at all |
        | **DNUO** | Offered | Not mentioned at all |

        A release being *mentioned* rather than offered is not a problem to solve. It means the newer version
        exists and does not apply to the copy you are running.

        > [!IMPORTANT] Urgent patches still reach you
        > A release marked **UBP** is one where the old behaviour can do something you would not want. Those are
        > raised as soon as they are found, rather than waiting for the next time you happen to look — which is
        > the whole reason the markers exist rather than every release being equal.
        """#)

    static let updateNotes = HelpArticle(
        id: "update-notes", title: "What the update notice tells you", symbol: "doc.text",
        summary: "Where the text in an update notice comes from, and what to read before taking one.",
        keywords: ["update notes", "release notes", "info", "changelog", "what's new", "notice"],
        related: ["updates", "update-tags"],
        body: #"""
        When there is a release worth telling you about, MSL shows the version, what kind of release it is, and
        whatever notes the release carries.

        ## Where the notes come from {#source}

        Each release can ship a short plain-text file alongside it. MSL fetches that and shows it in the notice.
        It is written to lead with anything you have to do by hand.

        If a release has no such file, the notice says the release page has notes worth reading and points you
        there, rather than inventing a summary.

        ## What to check before updating {#before}

        - **Anything you must do by hand.** The notes lead with this when there is any.
        - **Whether instances need to be stopped.** MSL will tell you; when in doubt, stop them.
        - **Your own settings.** Updating keeps them. A new version that turns something on by default changes
          only that switch, not choices you have made.

        > [!NOTE] Your instances are not touched
        > Updating MSL replaces MSL. Instances, their disks and their snapshots live separately and are left
        > exactly as they are. [Uninstalling](help:uninstalling-msl) explains where they live and what removing
        > MSL does and does not take with it.
        """#)
}
