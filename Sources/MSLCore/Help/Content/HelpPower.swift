import Foundation

// Chapter 10. How instances behave around sleep, shutdown, idleness and each other.

extension HelpChapter {
    static let power = HelpChapter(
        id: "power", title: "Power & Lifecycle", symbol: "powerplug", tint: .green,
        blurb: "What happens when your Mac sleeps or shuts down, when instances sit idle, and why distros share.",
        articles: [.powerEvents, .idle, .sharedDisks])
}

extension HelpArticle {
    static let powerEvents = HelpArticle(
        id: "power-events", title: "Sleep, shutdown and battery", symbol: "powerplug",
        summary: "MSL freezes every instance before your Mac sleeps, shuts down, logs out or runs out of battery.",
        keywords: ["sleep", "wake", "shutdown", "restart", "logout", "log out", "battery", "low battery", "lid", "close lid", "fast user switching", "power"],
        related: ["stopping-instances", "linux-windows", "trouble-clock"],
        body: #"""
        A virtual machine that's writing to its disk when the power goes is how Linux disks get damaged. So whenever
        your Mac is about to sleep or stop, MSL's first move is to **freeze every running instance** — near-instant, with
        no disk activity — so none of them is mid-write. Only then does it do anything slower.

        ## What happens when {#table}

        | Your Mac… | MSL… |
        |---|---|
        | **Sleeps** (lid closed, Apple menu ▸ Sleep) | Freezes every instance. They stay in memory. |
        | **Shuts down or restarts** | Freezes every instance, then hibernates each one to disk. |
        | **Logs out** | The same as shutting down. |
        | **Is on battery at 10% or below** | The same as shutting down, before the battery gives out. |
        | **Switches to another user** | Nothing — instances keep running for you, like everything else in your session. |

        MSL never holds up your Mac shutting down.

        ## Waking up {#wake}

        After your Mac wakes:

        - Instances that were frozen stay **Suspended** until something uses them — open a shell or an app, or click
          **Resume**.
        - Open terminal sessions have ended — the connection didn't survive the sleep. The Terminal tab shows
          "Session ended"; click **Reconnect**.
        - MSL corrects the clock of instances that are running, since a frozen instance's clock stops while your Mac
          sleeps.

        ## Shutting down {#shutdown}

        Shutdown, restart and logout hibernate every running instance, so next time you start one it picks up exactly
        where it was.

        Before that, MSL asks open Linux apps to close, the way their own close buttons would — so an app with unsaved
        work gets its chance to ask.

        > [!WARNING] Linux app windows don't come back
        > The instance resumes, but its app windows don't: each window's connection to your Mac ended when the Mac shut
        > down. Save your work in Linux apps before shutting down or restarting.

        > [!NOTE] If time runs out
        > macOS only waits so long. If an instance can't finish saving in time, it was still frozen first, so its disk
        > is safe — it simply starts fresh next time instead of resuming, and Linux tidies its filesystem up as it
        > starts, as it would after a power cut.

        > [!TIP] Trying it without shutting down
        > `msl power-test sleep` (or `shutdown`, `logout`, `lowbattery`, `wake`) runs MSL's response by hand, without
        > your Mac actually doing it. `msl power-test battery` shows what the battery watcher sees.
        """#)

    static let idle = HelpArticle(
        id: "idle", title: "Idle instances", symbol: "moon.zzz",
        summary: "Instances nobody's using suspend themselves, and wake the moment you need them.",
        keywords: ["idle", "auto suspend", "automatic", "sleeping instance", "why did it suspend", "timeout", "battery life"],
        related: ["stopping-instances", "terminal-tab", "linux-windows"],
        body: #"""
        A running instance uses processor time and battery even when nothing's happening inside it. So MSL tidies up
        after you.

        ## When the last session closes {#last-session}

        When the last shell or Linux app on an instance closes, MSL **suspends** it about three seconds later. The dot
        turns orange.

        Using it again resumes it straight away — opening the Terminal tab, `msl work` in a terminal, opening one of its
        apps, or clicking **Resume**. Resuming from suspend is almost instant, so mostly you won't notice.

        What keeps an instance awake:

        - an open shell, in the app, in Terminal.app, or from `msl`;
        - an open Linux app.

        ## Left alone for a while {#long-idle}

        Instances that have been left alone for a while may also be **hibernated**, to give their memory back to your
        Mac. Starting one resumes it exactly where it was — it just takes a few seconds rather than being instant.

        ## Around sleep and shutdown {#power}

        While your Mac is going to sleep or shutting down, idle suspending stands aside so it can't get in the way of
        MSL [protecting instances](help:power-events).
        """#)

    static let sharedDisks = HelpArticle(
        id: "shared-disks", title: "Shared disks", symbol: "externaldrive.connected.to.line.below",
        summary: "Instances of the same distro share one disk — so only one of them can run at a time.",
        keywords: ["shared disk", "same distro", "two instances", "already running", "shares", "corrupt", "one at a time", "disk image"],
        related: ["vocabulary", "concurrency", "create-instance", "storage"],
        body: #"""
        Each distro has **one disk image** on your Mac, and every instance of that distro uses it. Two Debian instances,
        one Debian disk.

        ## Why {#why}

        Distro disks are big, and a copy per instance would fill your Mac quickly. Sharing means a new instance costs
        almost nothing.

        ## What it means {#means}

        - **Only one instance per distro can run at a time.** Two running machines writing to one disk would wreck it,
          so MSL refuses: "'*other*' is already running and shares *distro*'s disk with '*this*' — running both at once
          would corrupt it; stop '*other*' first."
        - **Files are shared.** Anything saved inside Linux on `work` is there on `scratch`, if they're the same distro.
          So is your [Linux user](help:first-start#user).
        - **Disk size and storage settings are shared** — see [Disk size and storage](help:storage).
        - **Disk maintenance blocks the whole distro** while it runs.

        ## What's separate {#separate}

        Each instance still has its own name, CPUs and memory, sandbox gates, SSH shortcut, hibernated session,
        snapshots, and Mac apps.

        > [!TIP] Two Linux machines at once
        > Use two different distros — they have separate disks and run side by side happily.

        > [!WARNING] Snapshots and shared disks
        > Because the disk is shared, running *any* instance of a distro changes the disk every snapshot of that distro
        > was taken against. See [the snapshot rule](help:snapshots#disk).
        """#)
}
