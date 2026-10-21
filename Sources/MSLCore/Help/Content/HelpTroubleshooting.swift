import Foundation

// Chapter 11. When something goes wrong: symptom first, then what to do.

extension HelpChapter {
    static let troubleshooting = HelpChapter(
        id: "troubleshooting", title: "Troubleshooting", symbol: "cross.case", tint: .watermelon,
        blurb: "Symptoms first, then what to do — and where to look when that isn't enough.",
        articles: [.troubleWontStart, .troubleService, .troubleApps, .troubleSSH, .troubleDisk, .troubleFilesystem,
                   .troubleClock, .troubleMaintenance, .troubleMemory, .troubleNetwork,
                   .stopCodes, .observer, .logsAndDoctor, .reclaimSpace])
}

extension HelpArticle {
    static let troubleWontStart = HelpArticle(
        id: "trouble-wont-start", title: "An instance won't start", symbol: "exclamationmark.triangle",
        summary: "Greyed-out Start buttons, refusals, and what each message means.",
        keywords: ["won't start", "can't start", "start greyed out", "start disabled", "error starting", "boot fails", "kernel panic", "timed out", "refused"],
        related: ["concurrency", "shared-disks", "trouble-filesystem", "trouble-service"],
        body: #"""
        ## Start is greyed out {#greyed}

        | Why | What to do |
        |---|---|
        | A spinner is showing — it's busy. | Wait for it to finish. |
        | The capacity pill is orange — four are running. | Hibernate or shut one down. Suspending doesn't free a slot. See [Concurrency](help:concurrency). |
        | There's an **Install *Distro*** button instead. | The distro isn't downloaded. See [Installing a distro](help:install-distro). |

        ## Messages, and what they mean {#messages}

        > [!NOTE] "4 instances are already running … suspend or shut one down first"
        > Every slot is taken. Hibernate or shut one down.

        > [!NOTE] "'other' is already running and shares distro's disk with 'this'…"
        > Another instance of the same distro is running. Only one can use the disk at a time — stop that one first.
        > See [Shared disks](help:shared-disks).

        > [!NOTE] "didn't start: the filesystem check at start found a problem"
        > [Check-at-start](help:check-at-start) is on and found damage. [Repair the disk](help:disk-repair), then start
        > it.

        > [!NOTE] "check-at-start is on, but e2fsck isn't installed on this Mac"
        > Install e2fsprogs (`brew install e2fsprogs`), or turn the check off on the Maintenance card.

        > [!NOTE] "maintenance is running on this instance's disk"
        > A disk tool is working on it. It can start once that finishes.

        > [!WARNING] "the guest kernel panicked while booting — its filesystem is probably damaged"
        > Linux couldn't start from its disk. With the instance stopped, [check the disk](help:disk-check), then repair
        > it. The log has the details: `~/Library/Logs/MSL/mslhd.log`.

        > [!NOTE] "shell connection timed out"
        > The connection to the instance got stuck. Try again — MSL starts a fresh machine.

        > [!NOTE] "MSL's background service isn't running"
        > See [The service isn't running](help:trouble-service).
        """#)

    static let troubleService = HelpArticle(
        id: "trouble-service", title: "The service isn't running", symbol: "bolt.horizontal.circle",
        summary: "When MSL's background service is missing, stopped, or out of date.",
        keywords: ["mslhd not running", "daemon not running", "service stopped", "background service", "older version", "not answering", "start it"],
        related: ["background-service", "logs-and-doctor"],
        body: #"""
        Everything in MSL goes through its background service, `mslhd`. When it isn't running, nothing can start.

        ## Signs {#signs}

        - With no instance selected: "MSL's background service isn't running", and a **Start it** button.
        - Errors ending "MSL's background service isn't running."
        - The Tools tab's **Background service** card says **Not running**.
        - Linux apps in the Dock don't open.

        ## Fixes, in order {#fixes}

        1. Click **Start it** (or quit and reopen MSL, which starts it too).
        2. Make sure **Start MSL's service automatically** is on, on the Tools tab.
        3. Run `msl doctor` in Terminal — it checks whether the service is reachable and whether MSL's tools are
           installed. See [Logs and msl doctor](help:logs-and-doctor).
        4. Read `~/Library/Logs/MSL/mslhd.log` — the last lines usually say why it stopped.

        ## "an older version" {#outdated}

        The Maintenance card may say "MSL's background service answered, but not in a way this version understands".
        That's the service from before your last update, still running. The new one takes over the next time you log
        in — log out and back in to switch now.
        """#)

    static let troubleApps = HelpArticle(
        id: "trouble-apps", title: "Linux apps won't appear or open", symbol: "square.grid.2x2",
        summary: "Empty app grids, apps that won't open, and windows that misbehave.",
        keywords: ["no apps", "app not showing", "app won't open", "couldn't start", "blank window", "no window", "dock app not opening", "drawing glitches"],
        related: ["apps-tab", "linux-windows", "sandbox-gates"],
        body: #"""
        ## The grid is empty {#empty}

        - "**No GUI applications found**" — nothing installed has a `.desktop` entry. Command-line programs never do.
          Install a GUI app inside Linux, then **Refresh**. See [Your first Linux app](help:first-app).
        - "**No applications yet**" with **Install *Distro*** — the distro isn't downloaded yet.

        ## I installed something and it isn't there {#missing}

        Click **Refresh** — MSL only reads the list when asked. Check the source picker isn't filtering it out (choose
        **All**), and that the search field is empty.

        ## It won't open {#wont-open}

        | Check | Because |
        |---|---|
        | Is the **Graphics** gate cut on the Sandbox tab? | It stops new windows opening. |
        | Is the capacity pill orange? | Opening an app has to start the instance, and every slot is taken. |
        | Is the background service running? | It's what runs Linux apps. See [The service isn't running](help:trouble-service). |
        | Does it run from the Terminal tab? | Type its command there — errors print right in the terminal. |

        An orange "Couldn't start *app*" banner includes the reason. Apps started from the Dock or Spotlight have no
        terminal, so they write problems to `~/Library/Logs/MSL` — **Open Logs** on the Tools tab.

        ## An app in my Dock does nothing {#dock}

        If the instance it belongs to has been removed, its Mac apps were removed too — but a Dock tile can outlive
        them. Remove the tile. `msl doctor` lists apps pointing at removed instances, and `msl doctor --fix` cleans
        them up.

        ## The window looks wrong {#drawing}

        mslgd is MSL's own display server, and some apps use parts of X11 it doesn't draw perfectly yet. Try the app
        from another source (a Flatpak, say). See [Living with Linux windows](help:linux-windows).

        ## Copy and paste doesn't work between apps {#clipboard}

        Not yet — only within one Linux app. See [Copy and paste](help:linux-windows#clipboard).
        """#)

    static let troubleSSH = HelpArticle(
        id: "trouble-ssh", title: "SSH won't connect", symbol: "network.slash",
        summary: "Not answering on port 22, stale details, and setup that fails.",
        keywords: ["ssh not working", "connection refused", "port 22", "timeout", "not answering", "vs code can't connect", "host key"],
        related: ["ssh", "sandbox-gates"],
        body: #"""
        ## "isn't answering on port 22" {#not-answering}

        1. **Is the Network gate cut?** On the Sandbox tab. Cutting it unplugs the virtual network card SSH uses. The
           app's own terminal and `msl` shells still work, because they don't use the network.
        2. **Is the instance running?** SSH needs it up.
        3. Click **Set up again** on the SSH card — it redoes everything, including restarting the SSH server.

        ## "Last known details" {#stale}

        Not a problem: the card is showing details from when the instance last ran. It rechecks once the instance is
        running.

        ## Setup failed {#failed}

        The card shows the reason and a **Try again** button. Setting up installs things inside Linux, which needs the
        instance running — and, the first time, may need the network.

        ## VS Code or another tool can't find it {#tools}

        They read `~/.ssh/config`. Check the `Host msl-work` entry is there; **Set up again** rewrites it. **Copy all
        details** on the card gives you everything to paste elsewhere.
        """#)

    static let troubleDisk = HelpArticle(
        id: "trouble-disk", title: "The disk is full", symbol: "externaldrive.badge.exclamationmark",
        summary: "Running out of space inside Linux, or on your Mac.",
        keywords: ["disk full", "no space left on device", "out of space", "storage full", "enospc", "mac disk full"],
        related: ["storage", "reclaim-space", "guest-utilities"],
        body: #"""
        There are two different "full"s, and the Storage card on the Overview tab shows both.

        ## Full inside Linux {#guest-full}

        "No space left on device" inside Linux, or the usage bar is orange.

        1. **Make room inside:** run **Clear caches inside Linux** from the Maintenance card, and delete what you don't
           need.
        2. **Raise the limit:** drag the Storage card's slider up. The disk grows and Linux's filesystem is stretched to
           match at the next start.
        3. **Let it grow by itself:** with a dynamic disk, **Grow automatically when it runs low** adds 8 GB at a start
           whenever it's 85% full, up to the limit.

        ## Full on your Mac {#host-full}

        A dynamic disk only takes the space it has written, but that grows as Linux writes — and it never shrinks
        back, even after deleting files inside Linux. The Storage card shows what it really takes ("Actually used on
        your Mac"), and its footnote shows your Mac's free space.

        See [Reclaiming disk space](help:reclaim-space) for what can be deleted.
        """#)

    static let troubleFilesystem = HelpArticle(
        id: "trouble-filesystem", title: "Filesystem errors", symbol: "bandage",
        summary: "Read-only filesystems, I/O errors, and instances that won't boot — how to check and repair.",
        keywords: ["filesystem error", "read-only file system", "i/o error", "input/output error", "corrupt", "corruption", "ext4", "journal", "fsck", "damaged disk"],
        related: ["disk-check", "disk-repair", "maintenance-boot", "check-at-start"],
        body: #"""
        ## Signs {#signs}

        - "Read-only file system" when writing — Linux switched the disk to read-only after finding a problem.
        - "Input/output error" on files.
        - The instance won't start: "the guest kernel panicked while booting".
        - **Check for disk errors** on the Maintenance card finds something.

        ## What to do {#steps}

        1. **Save anything you can** — copy important files out to `/mnt/mac` or with MSL Files.
        2. **Shut the instance down.**
        3. **[Check Disk](help:disk-check)** on the Maintenance card (needs e2fsprogs on your Mac).
        4. If it finds problems, **[Repair Disk…](help:disk-repair)**. A backup is taken first.
        5. Start the instance and see how it is. If things are worse, **Restore…** puts the old disk back.
        6. When all's well, **Discard** the backup.

        No e2fsprogs? Try the [maintenance boot](help:maintenance-boot).

        ## Keeping it from happening {#prevent}

        - Shut Linux down properly — `sudo poweroff` inside it, or `msl --shutdown` — rather than the app's
          **Shut Down**, which stops it at once. See [the note on Shut Down](help:stopping-instances#shut-down).
        - Don't restore [snapshots](help:snapshots#disk) after the disk has changed.
        - Consider [checking at every start](help:check-at-start).
        """#)

    static let troubleClock = HelpArticle(
        id: "trouble-clock", title: "The clock is wrong", symbol: "clock.badge.exclamationmark",
        summary: "Wrong time inside Linux after sleep or hibernation, and why it matters.",
        keywords: ["wrong time", "clock", "date wrong", "time drift", "certificate error", "ssl error", "tls", "make", "git"],
        related: ["guest-utilities", "power-events"],
        body: #"""
        A frozen or hibernated instance's clock stops, so after a long pause it can be hours behind. That isn't only
        cosmetic: it breaks secure web connections ("certificate is not yet valid"), confuses `make` and `git`, and
        causes errors that look unrelated.

        - MSL fixes the clock of running instances automatically after your Mac wakes.
        - Anything else: **Sync clock with the Mac** on the Maintenance card. It says how far
          off it was.

        Check the time inside Linux with `date`.
        """#)

    static let troubleMaintenance = HelpArticle(
        id: "trouble-maintenance", title: "The Maintenance card says…", symbol: "stethoscope",
        summary: "Every message the Maintenance card can show instead of working, and what to do.",
        keywords: ["maintenance unavailable", "older version", "e2fsck isn't installed", "hibernated session"],
        related: ["maintenance", "whats-ready", "trouble-service"],
        body: #"""
        | The card says | What to do |
        |---|---|
        | "This distro isn't installed yet, so there's no disk to check or repair." | Nothing to maintain yet. |
        | "Checking what's available…" | Wait a moment. |
        | "MSL's background service isn't answering…" | See [The service isn't running](help:trouble-service). |
        | "…answered, but not in a way this version understands…" | An older service is still running. Log out and back in. |
        | "e2fsck isn't installed…" | **Copy Install Command**, then run it in Terminal. |
        | "Shut the instance down first…" | Stop it. See [the note on Shut Down](help:stopping-instances#shut-down). |
        | "This instance has a hibernated session…" | **Start** it, then shut it down, then try again. |
        | "Maintenance is already running on this disk." | Wait for it to finish. |
        | "Start the instance to use these." | The utilities run inside Linux. |
        | "MSL's background service didn't answer in time. It may still be working — check again in a moment." | A long job may still be running. Wait, then check again. |
        """#)

    static let troubleMemory = HelpArticle(
        id: "trouble-memory", title: "Memory trouble", symbol: "memorychip",
        summary: "Your Mac gets slow, or programs inside Linux are killed for running out of memory.",
        keywords: ["slow mac", "beachball", "paging", "swap", "out of memory", "oom", "killed", "memory pressure", "lag"],
        related: ["memory", "memory-dynamic", "concurrency"],
        body: #"""
        ## Your Mac gets slow {#mac-slow}

        Instances' memory can't be paged out, so too much of it leaves macOS short.

        - Hibernate instances you aren't using — suspended ones still hold their memory.
        - Lower their memory on the Overview tab — especially above the three-fifths warning.
        - Use [dynamic memory](help:memory-dynamic), so idle instances give memory back.

        ## Programs in Linux get killed {#guest-oom}

        When Linux runs out of memory it stops a program to survive — often the biggest one. Linux images don't use
        swap, so there's no slow fallback first.

        - Raise the instance's memory (manual), or its maximum (dynamic), then restart it.
        - On dynamic memory, the live readout's **Guest stalling on memory** shows when it's struggling.
        """#)

static let stopCodes = HelpArticle(
        id: "stop-codes", title: "The crash screen and its stop codes", symbol: "exclamationmark.octagon",
        summary: "What MSL shows when it cannot carry on, and what each code means.",
        keywords: ["crash", "crash screen", "stop code", "error code", "0x", "fatal",
                   "SERVICE_CANNOT_LISTEN", "SIGNING_KEY_UNREADABLE", "KEY_STORE_UNPROTECTED",
                   "VIRTUALIZATION_REFUSED", "SERVICE_WILL_NOT_STAY_UP",
                   "SERVICE_STOPPED_ANSWERING", "SERVICE_IS_NOT_INSTALLED",
                   "STATE_DIRECTORY_UNUSABLE", "observer", "mslod", "quit unexpectedly"],
        related: ["observer", "logs-and-doctor", "trouble-service", "mslap-strength"],
        body: #"""
        Most things that go wrong in MSL get a sentence and a way out. The crash screen is for the ones that
        do not: MSL has stopped, and carrying on would mean pretending.

        The picture on it is a joke. The panel beside it is not - it carries the code, which part of MSL the
        failure was about, which part noticed, when, and what was actually measured. That panel is what you
        quote; **Copy report** puts all of it on the clipboard, with the observer's own record of the minutes
        beforehand when the observer is what raised it.

        Every stop carries a **code** - a number like `0x00000010` and a name like `SERVICE_CANNOT_LISTEN`.
        The number never changes meaning, so it is worth quoting in a bug report or searching for.

        ## Who raises one {#who}

        | Raised by | |
        |---|---|
        | **MSL, about itself** | A condition MSL detects where it happens and cannot continue past. `0x10`-`0x13`. |
        | **MSL's observer** | A separate program, `mslod`, that watches MSL from outside and reports a state MSL cannot get itself out of. `0x20` upwards. See [MSL's observer](help:observer). |
        | **Nothing** | A signal or an unhandled error. `0x01`-`0x06`, and they carry no advice on purpose. |

        ## Codes MSL raises about itself {#known}

        ### 0x00000010 SERVICE_CANNOT_LISTEN {#service-cannot-listen}

        MSL's background service could not open the socket everything else talks to it on, so nothing can
        reach it. Another copy may already be running. Quit MSL and open it again; failing that, restart
        the Mac.

        ### 0x00000011 SIGNING_KEY_UNREADABLE {#signing-key-unreadable}

        The key MSL signs your instances with is there and cannot be read. Check that `/Users/Shared/MSL`
        and the `machine-key` file inside it still belong to you.

        > [!important]
        > MSL will **not** replace an unreadable signing key. A new one would make every instance on this Mac
        > unverifiable, permanently - so it stops instead, which is the recoverable outcome.

        ### 0x00000012 KEY_STORE_UNPROTECTED {#key-store-unprotected}

        This Mac is managed, but the folder holding the administrator's keys can be written by other
        accounts, so signed policies no longer verify. An administrator repairs it - see
        [How strong a policy is](help:mslap-strength).

        ### 0x00000013 VIRTUALIZATION_REFUSED {#virtualization-refused}

        macOS will not let this copy of MSL's service create a virtual machine, so no instance can start.
        Install MSL from its package rather than copying the files in: the permission is part of the
        signature and does not survive a plain copy.

        ## Codes MSL's observer raises {#observer-codes}

        These come from `mslod`, which is not part of MSL and does not depend on it. Each one is a state MSL
        has been in **for minutes**, not a moment of trouble - a single crash that the service recovered from
        is recorded and never shown. See [MSL's observer](help:observer) for how it decides.

        ### 0x00000020 SERVICE_WILL_NOT_STAY_UP {#service-will-not-stay-up}

        The background service has crashed and restarted several times in a few minutes and never answered
        anything in between. Quit MSL and open it again - that reinstalls the service from the app. If it
        keeps happening, the crash report named `mslhd` in Console's Crash Reports says why, and the report
        panel quotes the exception type it found.

        ### 0x00000021 SERVICE_STOPPED_ANSWERING {#service-stopped-answering}

        The service is running and accepting connections but has stopped replying to them, so anything that
        asks it something waits forever instead of being told no. Restart it:

        ```shell
        launchctl kickstart -k gui/$(id -u)/com.msl.mslhd
        ```

        Your instances keep their disks, and anything that was running comes back. If it wedges again,
        restart the Mac before using MSL for anything you care about.

        ### 0x00000022 SERVICE_IS_NOT_INSTALLED {#service-is-not-installed}

        The program MSL runs everything through is missing from where MSL installs it, so nothing can start -
        most likely an install or update that stopped part-way. Open MSL once: the app reinstalls its own
        command-line programs every launch. If MSL will not open either, install it again from its package;
        your instances and their disks are untouched by that.

        ### 0x00000023 STATE_DIRECTORY_UNUSABLE {#state-directory-unusable}

        MSL cannot use the folder it keeps your instances, accounts and settings in, so instances may appear
        to have vanished. **Nothing has been deleted.** Check that `~/Library/Application Support/MSL` still
        belongs to you, is readable and writable, and that its disk is not full. Do not delete anything in
        there - it is where your instances live.

        ## Codes nothing understands {#unknown}

        These mean MSL fell over in a way it did not anticipate. They carry no advice, deliberately: inventing
        a next step for something MSL cannot explain would be worse than admitting it. They name no subsystem
        either, for the same reason.

        | Code | |
        |---|---|
        | `0x00000001` WENT_SOMEWHERE_IT_SHOULDNT | Memory that was not MSL's own |
        | `0x00000002` BUS_TOOK_A_WRONG_TURN | Memory the processor could not give it |
        | `0x00000003` INSTRUCTION_MAKES_NO_SENSE | Something that is not an instruction |
        | `0x00000004` MATHS_HAPPENED | Arithmetic with no usable answer |
        | `0x00000005` GAVE_UP_ON_ITSELF | A check inside MSL that it could not carry on past |
        | `0x00000006` TRIPPED_OVER_A_TRAP | A trap left for a debugger |

        An uncaught error shows as `UNCAUGHT_` and the error's own name instead of a number.

        ## What MSL does not trade away {#report}

        macOS writes its own crash report, with a backtrace, and that file is the thing that actually makes a
        crash like this fixable. So MSL shows the screen and then lets the process die exactly as it would
        have. Nothing is given up for the window.

        You will find that report in **Console ▸ Crash Reports**, named after the part that stopped -
        `mslhd`, `MSLApp`, `MSLFiles` or `msl`.
        """#)

    static let observer = HelpArticle(
        id: "observer", title: "MSL's observer", symbol: "eye",
        summary: "The separate program that watches MSL, what it records, and when it interrupts you.",
        keywords: ["observer", "mslod", "watchdog", "observer.log", "monitoring", "watching",
                   "com.msl.observer", "incident", "crash screen"],
        related: ["stop-codes", "logs-and-doctor", "trouble-service", "background-service"],
        body: #"""
        `mslod` is a small program that watches MSL from outside and does nothing else. It is installed
        beside MSL's other programs and runs as its own login job - never inside MSL's background service,
        because a watchdog that lives in the thing it watches is missing at the only moment it matters.

        Nothing in MSL depends on it. If it is not running, MSL works exactly the same; you simply get no
        report when something goes badly wrong. `msl doctor` says whether it is running.

        ## What it watches {#watches}

        From outside, every few seconds, using nothing but the process table and MSL's own control socket:

        - the background service starting, stopping and being replaced, by process id;
        - whether it **answers**, not merely whether it can be connected to - a socket accepts connections on
          the kernel's behalf, so connecting proves nothing;
        - every Linux application host starting and ending, and which instance each belongs to;
        - your instances appearing, running and stopping;
        - crash reports macOS writes for any part of MSL, and the exception type inside them;
        - whether MSL's own folder can be written and its list of instances read.

        It also quotes MSL's own log lines into its record, so one file holds both what MSL said about
        itself and what was seen from outside. Guest kernel output is left out - that is Linux talking,
        not MSL.

        ## When it interrupts you {#interrupts}

        Almost never, by design. A crash screen for a healthy MSL is worse than no observer at all, so every
        threshold is minutes rather than seconds, and all of the following are recorded and **not** shown:

        - one crash that the service came back from - that is the system working;
        - the service being replaced during an update, or booted out by the installer;
        - `launchctl kickstart`;
        - a slow reply while MSL freezes and saves a guest's memory, however long that takes - a service
          still writing its own log is busy, not wedged;
        - the Mac waking from sleep;
        - the service being off because you turned it off;
        - MSL having already put up its own crash screen, which says more than the observer can.

        What it does show is a state MSL has been in for minutes and cannot get out of: the service in a
        restart loop, a service that has stopped replying, a missing installation, or a folder MSL cannot
        use. Each is one of the [stop codes](help:stop-codes), and each is shown **once** per session.

        ## Its record {#record}

        `~/Library/Logs/MSL/observer.log`, and it belongs to **this time you turned the Mac on**. The next
        boot deletes it and starts again, so there is nothing to clear out and nothing that grows forever.
        Restarting the observer, or MSL, does not clear it - only booting does.

        That is deliberately short-lived, so an incident keeps its own copy. When the observer raises a stop
        code it writes `observer-incident.txt` into `~/Library/Application Support/MSL` with the code, what
        it measured, and the tail of what it saw beforehand. **Copy report** on the crash screen includes all
        of it. That file survives the log, and is removed once the screen has shown it.

        ## Turning it off {#off}

        It follows **Start MSL's background service** in Settings. Turning that off removes the observer's
        job along with the service's; turning it back on reinstates both.
        """#)

    static let logsAndDoctor = HelpArticle(
        id: "logs-and-doctor", title: "Logs and msl doctor", symbol: "doc.text.magnifyingglass",
        summary: "Where MSL writes what it's doing, and the command that checks your installation.",
        keywords: ["logs", "log file", "mslhd.log", "debug", "diagnostics", "msl doctor", "doctor", "fix", "cleanup", "console"],
        related: ["trouble-service", "where-things-live"],
        body: #"""
        ## Logs {#logs}

        MSL's logs are in `~/Library/Logs/MSL`. **Open Logs** on the Tools tab opens the folder.

        - **mslhd.log** — the background service: every start, stop, power event and error, with the details behind
          the short messages in the app.
        - Mac apps started from the Dock or Spotlight write their problems here too, since they have no terminal.

        ## msl doctor {#doctor}

        In Terminal:

        ```shell
        msl doctor
        ```

        It checks for things no other command shows, and lists each with ✓, a warning or a problem:

        - Whether MSL's command-line tools are installed.
        - Whether the background service is reachable.
        - Every instance, and whether its distro is downloaded.
        - Leftover files from removed instances, and cached app lists for them.
        - Mac apps still pointing at removed instances.
        - How much space the disk images take in total.

        It only reports. If it finds leftovers, it lists them and tells you to run:

        ```shell
        msl doctor --fix
        ```

        which deletes exactly what it listed — nothing else.
        """#)

    static let reclaimSpace = HelpArticle(
        id: "reclaim-space", title: "Reclaiming disk space", symbol: "arrow.3.trianglepath",
        summary: "What takes space on your Mac, what can go, and what can't be shrunk.",
        keywords: ["free space", "reclaim", "delete image", "disk space", "shrink", "clean up", "large files", "state files", "remove distro"],
        related: ["storage", "removing-instances", "snapshots", "where-things-live"],
        body: #"""
        ## What takes space {#what}

        Everything is in `~/Library/Application Support/MSL`:

        | File | What | Size |
        |---|---|---|
        | `rootfs.img` (Alpine), and `rootfs-<distro>.img` for the rest — `rootfs-debian.img`, `rootfs-rocky.img` and so on | Each distro's disk. | Whatever Linux has written. |
        | `vm-<instance>.state` | A hibernated session. | About the instance's memory. |
        | `vm-<instance>-<snapshot>.state` | A snapshot. | About the instance's memory. |
        | `<disk>.pre-repair` | A backup from a disk repair. | Grows as the repaired disk changes. |

        ## What you can do {#options}

        - **Discard repair backups** you no longer need, on the Maintenance card.
        - **Remove instances** you don't use — that deletes their hibernated sessions and snapshots. See
          [Removing an instance](help:removing-instances).
        - **Delete a distro's disk image**, with every instance of that distro stopped. The space comes back
          immediately; the next start downloads the distro fresh.

        > [!DANGER] Deleting a disk image deletes its files
        > Everything inside Linux on that distro — for every instance using it — goes with it. Copy out anything you
        > want to keep first. Hibernated sessions and snapshots of that distro no longer match a fresh disk, so delete
        > those too, or remove the instances.

        ## What doesn't work {#doesnt}

        > [!IMPORTANT] Deleting files inside Linux doesn't shrink the image
        > A dynamic disk grows as Linux writes, but deleting files inside Linux doesn't hand the space back to your Mac.
        > **Clear caches inside Linux** makes room *inside* the instance, not on your Mac. The only way to get that space
        > back is to delete the image and start fresh.
        """#)

    static let troubleNetwork = HelpArticle(
        id: "trouble-network", title: "Linux has no internet", symbol: "wifi.slash",
        summary: "Working out where the connection stops: the gate, the guest, DNS, or your Mac.",
        keywords: ["internet", "network", "offline", "dns", "ping", "resolve", "connection", "apt", "download",
                   "no route", "temporary failure"],
        related: ["sandbox-gates", "trouble-ssh", "traffic-monitor", "trouble-clock"],
        body: #"""
        Work down this list. Each step rules out one layer, and the first one that fails is the answer.

        ## 1. Is the network gate open? {#gate}

        The Sandbox tab's **Network** gate detaches the virtual network card. It is kept across restarts, so an
        instance you sealed last week is still sealed.

        This is by far the most common cause, and it looks exactly like a broken connection: no internet, no
        local network, SSH not answering. Note that `msl` shells, the Terminal tab and MSL Files keep working
        with it closed, because they do not use the network — so "the terminal works but nothing downloads" points
        straight here.

        ## 2. Does the guest have an address? {#address}

        In the instance:

        ```
        ip addr
        ip route
        ```

        You want an address on the main interface and a default route. If there is no address, ask for one:

        ```
        sudo dhclient -v
        ```

        ## 3. Can it reach anything by number? {#ping}

        ```
        ping -c 3 1.1.1.1
        ```

        Working here but not by name means DNS, which is the next step. Failing here with the gate open points
        at your Mac's own connection — check that the Mac itself is online.

        ## 4. Can it resolve names? {#dns}

        ```
        getent hosts deb.debian.org
        cat /etc/resolv.conf
        ```

        "Temporary failure in name resolution" from `apt` is almost always this. `/etc/resolv.conf` should name a
        resolver; if it is empty or points somewhere unreachable, that is the fault.

        ## 5. Is the clock right? {#clock}

        A clock that is badly wrong breaks anything using certificates, which looks like a network problem:
        downloads fail, `apt` complains that release files are not valid yet. See [The clock is
        wrong](help:trouble-clock).

        ## What each symptom usually means {#symptoms}

        | Symptom | Usually |
        |---|---|
        | Terminal works, nothing downloads | The Network gate is closed |
        | `ping 1.1.1.1` works, names do not | DNS |
        | Everything fails, the Mac is also offline | Your Mac's connection |
        | `apt` says release files are not valid yet | The clock |
        | SSH refused but shells work | The Network gate, or SSH is not running |

        > [!NOTE] Watching it live
        > The Traffic Monitor's **Guest connections** lane shows what Linux itself has open, read from Linux's own
        > network stack. It is the quickest way to see whether an app is even trying to connect.
        """#)
}
