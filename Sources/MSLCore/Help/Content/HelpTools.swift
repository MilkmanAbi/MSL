import Foundation

// Chapter 7. The Tools tab: the service, generated apps, snapshots, stopping
// and removing, and the maintenance tools.

extension HelpChapter {
    static let tools = HelpChapter(
        id: "tools", title: "Tools Tab", symbol: "wrench.and.screwdriver", tint: .orange,
        blurb: "The background service, snapshots, stopping and removing, and disk check and repair.",
        articles: [.toolsTab, .backgroundService, .generatedApps, .snapshots, .stoppingInstances, .removingInstances, .uninstallingMSL,
                   .maintenance, .diskCheck, .diskRepair, .checkAtStart, .maintenanceBoot, .guestUtilities])
}

extension HelpArticle {
    static let toolsTab = HelpArticle(
        id: "tools-tab", title: "The Tools tab", symbol: "wrench.and.screwdriver",
        summary: "Five cards for looking after an instance.",
        keywords: ["tools", "utilities", "admin", "cards", "manage"],
        related: ["maintenance", "snapshots", "stopping-instances"],
        body: #"""
        | Card | What's on it | More |
        |---|---|---|
        | **Background service** | Whether MSL's service is running, and whether it starts at login. | [The background service](help:background-service) |
        | **Generated applications** | Where the Mac apps made for this instance live. | [Generated apps](help:generated-apps) |
        | **Snapshots** | Saved machine states, to go back to. | [Snapshots](help:snapshots) |
        | **Maintenance** | Disk check and repair, maintenance boot, and fix-it utilities. | [Maintenance](help:maintenance) |
        | **Instance** | Suspend, Hibernate, Shut Down, Remove…. | [Stopping](help:stopping-instances), [Removing](help:removing-instances) |
        """#)

    static let backgroundService = HelpArticle(
        id: "background-service", title: "The background service", symbol: "bolt.horizontal.circle",
        summary: "mslhd runs every instance. What it is, how it starts, and what to do when it isn't running.",
        keywords: ["mslhd", "daemon", "service", "background", "login item", "launch agent", "launchagent", "not running", "start automatically"],
        related: ["trouble-service", "logs-and-doctor", "how-it-works"],
        body: #"""
        `mslhd` is MSL's background service. It runs every instance — the app, the `msl` command and the Linux apps in
        your Dock are all just ways of asking it to do things. Without it running, nothing can start.

        ## The card {#card}

        The **Background service** card at the top of the Tools tab:

        - **Start MSL's service automatically** — whether it starts when you log in (as a login item, at
          `~/Library/LaunchAgents/com.msl.mslhd.plist`). On by default.
        - **Status** — Running or Not running.
        - **Log** — `~/Library/Logs/MSL/mslhd.log`, where it writes what it's doing.

        > [!NOTE] Turning it off sticks
        > MSL normally re-installs the login item every time the app opens, so it can repair itself. Switching it off
        > here is remembered, so the app won't quietly turn it back on.

        > [!WARNING] Linux apps in your Dock need it
        > With the service off, Linux apps you've added to Applications or pinned to the Dock can't start either,
        > because it's the service that runs them.

        ## When it isn't running {#not-running}

        With no instance selected, the main window says "MSL's background service isn't running" and offers **Start
        it**. If it keeps stopping, the log says why — see [The service isn't running](help:trouble-service).

        ## After updating MSL {#updates}

        Updating the app installs the new service, but the one already running carries on until it next starts — at
        your next login. Until then, newer features that need it (like the [Maintenance](help:maintenance) card) may
        say the service is "an older version". Logging out and back in sorts it.
        """#)

    static let generatedApps = HelpArticle(
        id: "generated-apps", title: "Generated apps", symbol: "app.badge",
        summary: "Where the Mac apps made for an instance's Linux programs live.",
        keywords: ["generated applications", "~/Applications/MSL", "app bundles", "show in finder", "open logs", ".app"],
        related: ["add-to-applications", "pin-to-dock", "removing-instances"],
        body: #"""
        Every Linux app you [add to Applications](help:add-to-applications) or [pin to the Dock](help:pin-to-dock)
        becomes a small Mac app in `~/Applications/MSL/<instance>/`. The **Generated applications** card shows where:

        - **Location** — that instance's folder.
        - **Show in Finder** — opens it.
        - **Open Logs** — opens `~/Library/Logs/MSL`. A Mac app started from the Dock has no terminal to report
          problems in, so it writes them here instead.

        They're ordinary Mac apps: deleting one in Finder is exactly the same as **Remove from Applications**.
        """#)

    static let snapshots = HelpArticle(
        id: "snapshots", title: "Snapshots", symbol: "clock.arrow.circlepath",
        summary: "Save a machine's state under a name and go back to it — and the one rule that keeps it safe.",
        keywords: ["snapshot", "checkpoint", "save state", "restore", "rollback", "backup", "undo", "state file"],
        related: ["stopping-instances", "disk-repair", "reclaim-space"],
        body: #"""
        A snapshot saves a machine's state — everything in its memory, every running program — under a name, so you can
        return to that exact moment.

        ## Saving one {#saving}

        1. The instance has to be running or suspended — a stopped one has no memory to save. (The card says "Start
           *name* to take a snapshot.")
        2. Type a name in **New snapshot name** — letters, digits, hyphens and underscores, like `before-upgrade`.
        3. Click **Save** (or press Return).

        > [!IMPORTANT] Saving stops the instance
        > Saving pauses the machine, writes its memory to a file, and then **stops** it. That's deliberate — a saved
        > state is only reliable if the machine it came from doesn't carry on running. Start it again afterwards if you
        > want to keep working.

        ## Restoring one {#restoring}

        Click **Restore** beside it. Whatever the instance is doing is replaced — it stops if it was running — and it
        comes back exactly as it was when you saved. As the card says: restoring discards everything since.

        ## The rule that keeps it safe {#disk}

        > [!WARNING] A snapshot doesn't copy the disk
        > A snapshot holds the machine's memory and running state. It does *not* keep a separate copy of the disk —
        > the disk is the distro's shared disk, and it carries on changing when anything runs on it.
        >
        > If the disk changes after you save — you start the instance again, or use another instance of the same
        > distro — then restoring puts back a memory that remembers a different disk. Linux can get confused about
        > its own files, which can damage the filesystem.
        >
        > **Restore is only safe if nothing has run on that distro since the snapshot was saved.** If you've restored
        > anyway and things seem odd, [check the disk](help:disk-check).

        For "undo" after changing files, a copy of those files is often the better tool. For the disk as a whole,
        [Repair Disk](help:disk-repair) keeps a real copy of the disk before it changes anything.

        ## Where they live {#where}

        Each snapshot is a file in `~/Library/Application Support/MSL`, named `vm-<instance>-<snapshot>.state`, about
        the size of the instance's memory. There's no delete button yet; removing the instance deletes all of its
        snapshots. See [Reclaiming disk space](help:reclaim-space).
        """#)

    static let stoppingInstances = HelpArticle(
        id: "stopping-instances", title: "Suspend, hibernate or shut down?", symbol: "pause.circle",
        summary: "Three ways to stop an instance, what each costs, and which to use.",
        keywords: ["suspend", "hibernate", "shut down", "shutdown", "stop", "pause", "resume", "power off", "poweroff", "compare", "difference"],
        related: ["power-events", "idle", "concurrency", "snapshots"],
        body: #"""
        The **Instance** card at the bottom of the Tools tab has **Suspend**, **Hibernate** and **Shut Down**. The header
        and the sidebar's right-click menu have some of them too.

        | | **Suspend** | **Hibernate** | **Shut Down** |
        |---|---|---|---|
        | What happens | Frozen, kept in memory. | Memory written to a file, then stopped. | Stopped at once. |
        | Coming back | Almost instantly, exactly where it was. | A few seconds, exactly where it was. | A fresh start of Linux. |
        | Holds memory on your Mac | Yes | No | No |
        | Uses one of the four slots | Yes | No | No |
        | Disk space on your Mac | None | A file about the size of its memory | None |
        | Available when | Running | Running or suspended | Running or suspended |

        ## Suspend {#suspend}

        For a short break. Nothing is saved to disk, so it's instant both ways — but the instance keeps its memory and
        its [slot](help:concurrency). MSL also suspends instances by itself when they're [idle](help:idle).

        ## Hibernate {#hibernate}

        For a longer break. The machine's whole memory is written to your Mac's disk and the instance stops, giving back
        its memory and its slot. **Start** brings it back exactly as it was — shells, programs and all. Saving takes
        longer the more memory the instance has.

        This is also what MSL does to every running instance when your Mac shuts down, restarts or logs out. See
        [Sleep, shutdown and battery](help:power-events).

        ## Shut Down {#shut-down}

        > [!WARNING] Shut Down stops it straight away
        > **Shut Down** in the app stops the virtual machine immediately — like holding down a computer's power button.
        > Linux doesn't get the chance to finish writing to its disk first. Its filesystem recovers on the next start,
        > but anything that hadn't been written yet is lost, and stopping a machine this way over and over is how
        > disks get damaged.
        >
        > To shut Linux down properly, do one of these instead:
        >
        > - Run `sudo poweroff` in the instance's Terminal tab, and let it stop by itself.
        > - Or, in Terminal.app, run `msl --shutdown work` — it asks Linux to power off first, then stops the machine.
        > - Or **Hibernate**, which loses nothing at all.

        Shutting down also throws away a hibernated session, if there was one: after a power-off, the saved memory no
        longer matches the disk.

        ## Which one? {#which}

        - Back in a minute → **Suspend**, or just leave it — idle instances suspend themselves.
        - Done for the day, want the memory back → **Hibernate**.
        - Want a clean start of Linux → `sudo poweroff` inside it, then **Start**.
        """#)

    static let removingInstances = HelpArticle(
        id: "removing-instances", title: "Removing an instance", symbol: "trash",
        summary: "What Remove deletes, what it keeps, and why it doesn't ask first.",
        keywords: ["remove", "delete instance", "uninstall", "get rid of", "destroy", "remove instance", "clean up"],
        related: ["reclaim-space", "shared-disks", "generated-apps"],
        body: #"""
        **Remove…** is in the instance's right-click menu, the header's menu, and the Instance card on the Tools tab.

        > [!DANGER] It happens straight away
        > Remove doesn't ask for confirmation, despite the "…" on its name. Click it only when you mean it.

        ## What's deleted {#deleted}

        - The instance itself — its name disappears from the sidebar.
        - Its hibernated session, if it had one.
        - **All of its snapshots.**
        - Every Mac app made for it in `~/Applications/MSL/<instance>`, and its cached list of apps.
        - Its terminal session in the app.

        If it was running, it's stopped first.

        ## What's kept {#kept}

        > [!IMPORTANT] Your files are on the distro's disk, not the instance
        > Removing an instance never touches the distro's disk image — the files inside Linux stay, and every other
        > instance of that distro carries on as before. Create a new instance of the same distro and your files are
        > all still there.

        To really delete a distro's files and free the space, see [Reclaiming disk space](help:reclaim-space).
        """#)

    static let uninstallingMSL = HelpArticle(
        id: "uninstalling-msl", title: "Uninstalling MSL", symbol: "arrow.down.left.circle",
        summary: "Remove MSL and keep every instance and image - or remove all of it.",
        keywords: ["uninstall", "remove msl", "delete msl", "upgrade", "update", "reinstall", "clean install"],
        related: ["background-service", "generated-apps", "removing-instances"],
        body: #"""
        **Permissions & Startup ▸ Uninstall**, or `msl uninstall` in a terminal. Both run the same thing: the app
        shows you the list and then hands the job to the command in a Terminal window, because MSL can't delete
        itself while it's the one doing the deleting.

        > [!IMPORTANT] Your Linux is kept by default
        > Uninstalling removes MSL, not the Linux you installed with it. Every instance, disk image, custom image,
        > account and setting stays in `~/Library/Application Support/MSL`. Install MSL again and it all comes back
        > exactly as it was.

        ## What goes {#removed}

        - MSL.app itself.
        - The background service and the login items, stopped first.
        - The Mac apps made for your Linux apps, in `~/Applications/MSL`.
        - MSL's caches, logs and saved window state.
        - The `msl`, `mslhd`, `mslgui` and `msl-applauncher` programs.

        Running instances are shut down properly first - not hibernated, because a saved session with no MSL to
        restore it is worse than a clean power-off. Anything mounted in Finder is unmounted before that.

        ## What stays {#kept}

        - Every distro disk image, and everything inside it.
        - Your instances, the accounts you made, and each instance's storage settings.
        - Your custom images, in `Custom Images`.
        - MSL's own settings, so a reinstall doesn't switch something back on that you switched off.

        ## Upgrading is not uninstalling {#upgrading}

        To move to a newer MSL, just install it over the old one. The app and your Linux live in different places,
        so nothing is lost and there is no uninstall step. See [The background service](help:background-service)
        for why MSL restarts it after an update.

        ## Removing all of it {#everything}

        `msl uninstall --everything`, or the checkbox in the sheet, deletes the Linux side too - every image,
        instance and setting. It asks you to type a word first, the same one [Removing an
        instance](help:removing-instances) uses, because nothing here comes back.

        `msl uninstall --dry-run` prints both lists and changes nothing.
        """#)

    static let maintenance = HelpArticle(
        id: "maintenance", title: "The Maintenance card", symbol: "stethoscope",
        summary: "Disk check and repair, a maintenance boot, and fix-it utilities — organised by when they can run.",
        keywords: ["maintenance", "repair", "fix", "fsck", "e2fsck", "filesystem", "utilities", "health", "check"],
        related: ["disk-check", "disk-repair", "guest-utilities", "maintenance-boot"],
        body: #"""
        The **Maintenance** card on the Tools tab collects tools for keeping an instance healthy. It's laid out by *when*
        each one can run, because that decides whether a button can work at all:

        @card internaldrive orange | Disk | Check and repair the Linux filesystem from your Mac. The instance must be shut down.
        @card wrench.and.screwdriver purple | Maintenance Boot | Start Linux in a minimal mode and check its disk with Linux's own tools.
        @card play.circle green | While It's Running | Four fix-it utilities that run inside a running instance.

        > [!NOTE] Nothing changes without asking
        > As the card's footnote says: nothing here changes a disk without asking first, and every repair keeps a copy
        > of the disk from before it.

        ## Greyed-out buttons explain themselves {#reasons}

        A disabled button always has a line saying why, rather than just going grey:

        | You see | Why |
        |---|---|
        | "Shut the instance down first — a disk that's in use can't be checked safely." | Disk tools need it stopped. |
        | "This instance has a hibernated session…" | Its saved memory and disk are a pair. Start it, then shut it down, before maintenance. |
        | "Maintenance is already running on this disk." | One job at a time per disk. |
        | "e2fsck isn't installed…" with **Copy Install Command** | The Mac-side check needs a free tool. See [Checking a disk](help:disk-check#e2fsprogs). |
        | "Start the instance to use these." | The utilities run inside Linux. |

        ## Results {#results}

        When a tool finishes, a coloured box appears at the bottom of the card:

        | Colour | Means |
        |---|---|
        | Green | Healthy, or done. |
        | Orange | Something needs your attention. |
        | Red | It couldn't do what it was asked. |
        | Blue | For your information. |

        **Show details** opens the tool's full output; the × dismisses the box.

        > [!IMPORTANT] Instances that share the disk wait
        > While a disk tool is working, no instance using that distro's disk can start — they all share it.
        """#)

    static let diskCheck = HelpArticle(
        id: "disk-check", title: "Checking a disk", symbol: "internaldrive",
        summary: "Check Disk reads the Linux filesystem from your Mac, without changing anything.",
        keywords: ["check disk", "fsck", "e2fsck", "e2fsprogs", "homebrew", "brew", "filesystem check", "errors", "corruption", "ext4"],
        related: ["disk-repair", "check-at-start", "trouble-filesystem"],
        body: #"""
        **Check Disk** in the Maintenance card's **Disk** section examines the instance's Linux filesystem from your Mac
        and reports what it finds. It never changes anything.

        ## Before you start {#before}

        - **Shut the instance down.** Checking a disk while Linux is using it gives meaningless answers — it's only
          safe when nothing has it open.
        - **No hibernated session.** If the instance is hibernated, start it and shut it down first.
        - **Install e2fsprogs on your Mac** (see below).

        ## Installing e2fsprogs {#e2fsprogs}

        Linux disks are checked with a tool called `e2fsck`. macOS doesn't come with it, but it's free through
        [Homebrew](https://brew.sh). Until it's installed, the card says so and offers **Copy Install Command**, which
        copies this:

        ```shell
        brew install e2fsprogs
        ```

        Paste it into Terminal. MSL finds it where Homebrew puts it — no other setup needed.

        > [!TIP] No Homebrew?
        > The [maintenance boot](help:maintenance-boot) checks the disk with Linux's own copy of the tool, so it doesn't
        > need anything on your Mac.

        ## What the results mean {#results}

        | Result | Colour | Means |
        |---|---|---|
        | **No problems found** | green | The filesystem is consistent. |
        | **Problems found** | orange | "Nothing was changed. Run Repair to fix them — a backup of the disk is taken first." |
        | **The check didn't run** | red | Something stopped the check itself, and the result "says nothing about the disk". The reason follows. |

        **Show details** has e2fsck's own output.

        A big disk can take a few minutes — "Checking the disk… a large disk can take a few minutes."
        """#)

    static let diskRepair = HelpArticle(
        id: "disk-repair", title: "Repairing a disk", symbol: "bandage",
        summary: "Repair Disk fixes the filesystem — after taking an instant, free backup you can go back to.",
        keywords: ["repair disk", "fix disk", "fsck", "e2fsck", "backup", "restore backup", "discard backup", "pre-repair", "clone", "apfs", "corruption"],
        related: ["disk-check", "trouble-filesystem", "maintenance-boot"],
        body: #"""
        **Repair Disk…** fixes whatever the filesystem check finds. It asks first — "Repair this instance's disk?" — and
        explains what happens next.

        ## What it does {#what}

        1. **Takes a backup.** An instant copy of the whole disk, made with an APFS clone: it appears immediately and
           costs no space on your Mac until the disk starts to differ from it.
        2. **Repairs.** `e2fsck` fixes everything it can.
        3. **Reports** what happened.

        The same prerequisites as [Checking a disk](help:disk-check#before) apply: shut down, no hibernated session,
        e2fsprogs installed.

        > [!IMPORTANT] No backup, no repair
        > If MSL can't make the clone — the disk isn't on an APFS volume, or the backup would have to be copied to
        > another volume — it refuses to repair rather than risk the disk without a way back.

        ## Results {#results}

        | Result | Means |
        |---|---|
        | **Problems found and fixed** | Done. The backup is kept until you discard it. |
        | **Problems fixed** | Fixed, and e2fsck wants a restart before the disk is used — starting the instance now *is* that restart. |
        | **Some problems couldn't be fixed** | It fixed what it safely could. What's left needs a closer look; the backup is kept. |
        | **The check didn't run** | Nothing was repaired. The reason follows. |

        ## The backup {#backup}

        After a repair, the Disk section shows "A copy of the disk from before the last repair is kept." with two
        buttons:

        - **Restore…** — puts the old disk back. It asks first: "Put the old disk back?" — anything written to the disk
          since that repair is lost.
        - **Discard** — deletes the backup. Do this once you're happy the repaired disk is fine.

        The backup sits beside the disk image, with `.pre-repair` on the end of its name. If one already exists when you
        repair again, MSL keeps the existing one instead of replacing it — so it's always from before the first repair
        since you last discarded.

        > [!TIP] Discard when you're sure
        > The clone is free at first but grows as the repaired disk changes, up to the size of the whole disk. Once the
        > instance has been working happily for a while, discard it.
        """#)

    static let checkAtStart = HelpArticle(
        id: "check-at-start", title: "Checking the disk at every start", symbol: "checkmark.shield",
        summary: "An optional full check before each start, which refuses to boot a damaged disk.",
        keywords: ["check at start", "always check", "boot check", "startup check", "fsck on boot", "verify"],
        related: ["disk-check", "trouble-wont-start"],
        body: #"""
        **Check the disk every time this instance starts** — a switch in the Maintenance card's Disk section. **Off by
        default.**

        When it's on, every start first runs a full check of the disk from your Mac. If the disk is clean, the instance
        starts as usual. If it isn't, MSL **refuses to start it** rather than risk making things worse, with a message
        that begins "didn't start: the filesystem check at start found a problem". Then [repair it](help:disk-repair).

        - It needs e2fsprogs on your Mac. If you turn it on and later remove e2fsprogs, starts are refused until you
          reinstall it or turn the switch off — the message says which.
        - It adds the length of a full check to every start. On a big disk that's noticeable.
        - Resuming a hibernated session skips the check: the saved memory and the disk have to match exactly, and a
          check can't change that.
        - It's set per instance.
        """#)

    static let maintenanceBoot = HelpArticle(
        id: "maintenance-boot", title: "Maintenance boot", symbol: "wrench.and.screwdriver",
        summary: "Start Linux in a minimal mode and check or repair its disk with Linux's own tools.",
        keywords: ["maintenance boot", "maintenance mode", "recovery", "rescue", "single user", "check from linux", "repair from linux"],
        related: ["disk-check", "disk-repair", "whats-ready", "trouble-maintenance"],
        body: #"""
        **Check from Linux** and **Repair from Linux…** start the instance in a minimal maintenance mode: the disk
        read-only, nothing else running. Linux checks (or repairs) its own disk with its own tools, reports back, and
        shuts itself down.

        It's useful when your Mac doesn't have e2fsprogs, and it's a second opinion from Linux itself.

        ## Repairing {#repair}

        **Repair from Linux…** asks first, then takes the same instant backup as [Repair Disk](help:disk-repair#backup)
        before starting Linux. The backup appears in the Disk section afterwards, with Restore… and Discard.

        ## What you might see {#results}

        | Result | Means |
        |---|---|
        | The usual check or repair results | It ran; the same meanings as [Checking a disk](help:disk-check#results). |
        | **Maintenance boot couldn't start** (red) | Linux stopped before the tools could run — often because the disk is too damaged to start from. If e2fsprogs is on your Mac, Check Disk looks at it without starting it. |
        | **No result from the maintenance boot** (red) | It didn't report back within the time limit and was stopped. If this was a repair, check the disk before relying on it. |

        The same prerequisites apply as for the Mac-side tools: shut down, no hibernated session.
        """#)

    static let guestUtilities = HelpArticle(
        id: "guest-utilities", title: "Utilities for a running instance", symbol: "play.circle",
        summary: "Sync the clock, repair the package manager, clear caches, and look for disk errors.",
        keywords: ["clock", "time", "sync clock", "package manager", "apt lock", "dpkg", "clear cache", "free space", "journal", "dmesg", "disk errors", "utilities"],
        related: ["trouble-clock", "trouble-disk", "disk-check"],
        body: #"""
        The **While It's Running** section of the Maintenance card has four utilities. Each has a **Run** button, enabled
        while the instance is running.

        ## Sync clock with the Mac {#clock}

        An instance resumed from hibernation keeps the time it was saved at, which can confuse web certificates,
        builds and `git`. This sets Linux's clock to your Mac's and tells you how far off it was — or "The clock was
        already in sync."

        > [!TIP] Usually automatic
        > MSL already corrects the clock of running instances after your Mac wakes. This is for when something slips
        > through.

        ## Repair package manager {#packages}

        Finishes interrupted installs and clears a stale lock left behind by a crash, using the distro's own package
        manager — the fix for "could not get lock" and "interrupted" errors. It can take several minutes.

        ## Clear caches inside Linux {#caches}

        Clears the package manager's downloaded files and trims the system journal.

        > [!IMPORTANT] Frees space inside Linux, not on your Mac
        > This makes room *inside* the instance. The disk image on your Mac doesn't shrink — see
        > [Reclaiming disk space](help:reclaim-space).

        ## Check for disk errors {#disk-errors}

        Reads Linux's kernel log for filesystem and input/output errors. It only reads — if it finds any, shut the
        instance down and [check the disk](help:disk-check).
        """#)
}
