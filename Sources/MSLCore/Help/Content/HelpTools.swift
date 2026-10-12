import Foundation

// Chapter 7. The Tools tab: the service, generated apps, snapshots, stopping
// and removing, and the maintenance tools.

extension HelpChapter {
    static let tools = HelpChapter(
        id: "tools", title: "Tools Tab", symbol: "wrench.and.screwdriver", tint: .orange,
        blurb: "The background service, snapshots, stopping and removing, and disk check and repair.",
        articles: [.toolsTab, .shipments, .backgroundService, .generatedApps, .snapshots, .stoppingInstances, .removingInstances, .uninstallingMSL,
                   .maintenance, .diskCheck, .diskRepair, .checkAtStart, .maintenanceBoot, .guestUtilities,
                   .usbDevices])
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

    static let usbDevices = HelpArticle(
        id: "usb-devices", title: "USB devices", symbol: "cable.connector",
        summary: "Hand a USB device on your Mac to a Linux instance - including hardware macOS has no driver for.",
        keywords: ["usb", "device", "passthrough", "driver", "serial", "ftdi", "arduino",
                   "dev board", "programmer", "dongle", "hardware", "attach", "detach", "vhci", "usbip"],
        related: ["tools-tab", "cli-help", "experiments"],
        body: #"""
        Some devices macOS simply has no driver for: a development board, a
        programmer, a vendor-specific dongle, a piece of lab equipment whose
        manufacturer only ever shipped a Linux driver. Plug one into a Mac and
        nothing happens. Linux, very often, knows exactly what it is.

        MSL can hand the device over. It carries it into the instance over
        USB/IP, which has been part of Linux since 2008 and is built into every
        image MSL ships - so there is nothing to install on the Linux side and
        no driver to find.

        ## Seeing what is there

            msl usb list

        | Column | What it tells you |
        |---|---|
        | `LOCATION` | The device's location ID, which is what you pass to attach. It is the port it is plugged into, so it changes if you move it. |
        | `ID` | Vendor and product, as `vendor:product`. You can use this instead of the location ID. |
        | `macOS DRIVER` | Which of macOS's own drivers is holding it, or `none - native`. |
        | `ATTACHED TO` | Which instance has it, if any. |

        That third column is the one that matters, because it decides which of
        two quite different things happens next.

        ## A device macOS does not know

            msl usb attach 00100000 work

        This is the case MSL is built for. Nothing on your Mac has claimed the
        device, so MSL opens it and serves it to the instance directly. No
        password, no approval, nothing to grant. It appears in the guest a
        moment later and `lsusb` lists it like any other device.

        ## A device macOS does know

        Most things you own are in this group: anything speaking USB serial
        (macOS ships drivers for the FTDI, CH34x, CP210x and Prolific chips),
        anything CDC-ACM, and every flash drive. macOS has already claimed it,
        so MSL has to **take** it, and taking hardware away from the system
        needs an administrator password.

        MSL asks for it with a prompt that says what it is for, and only a
        small helper program runs with those privileges - never the whole app,
        and never anything between one attach and the next. The attachment
        lasts as long as that command: press Ctrl-C, or close the window, and
        the device goes back.

        > Note: a disk in this group is unmounted the hard way when it is
        > taken. Eject it in Finder first, or anything still writing to it
        > loses whatever it had not flushed. MSL warns you before asking for
        > the password.

        ## Giving it back

            msl usb detach 00100000 work

        macOS picks the device up again by itself. So does stopping or
        hibernating the instance - nothing is left stranded, and you never have
        to unplug something physically to get it back.

        An instance holding a device will not be paused or hibernated by the
        idle timer, because a paused machine cannot answer the device and it
        would appear to die.

        ## Checking it works, with nothing plugged in

            msl usb test work

        This attaches a device MSL makes up: it has no hardware behind it, and
        exists so the whole path - the connection into the guest, the kernel
        attach, the protocol - can be checked on a Mac with nothing connected.
        If it appears in the instance, passthrough itself is working, and
        anything that then fails is about that particular device.
        """#)

    static let shipments = HelpArticle(
        id: "shipments", title: "Shipments", symbol: "shippingbox",
        summary: "A whole instance in one file, for carrying to another Mac.",
        keywords: ["shipment", "mslship", "export", "import", "share", "docker", "image", "portable", "backup"],
        related: ["tools-tab", "removing-instances", "experiments"],
        body: #"""
        A **shipment** is one instance packed into a single file. Everything it
        has goes with it: the applications you installed, your files, your Linux
        account, how much disk and memory it was given, and which experimental
        features it was running. Someone else's MSL can install that file and
        get a working machine - even if their Mac has never downloaded that
        distribution.

        It is, honestly, MSL's weirder and worse version of what Docker does.
        There are no layers, no registry, no build file, and nothing clever
        about it: it is one machine, copied whole. Docker is a better tool for
        almost everything a shipment could be used for. What a shipment is good
        at is the thing Docker makes awkward - handing a colleague the *exact*
        environment you are sitting in, graphical applications and all, and
        having them open it on their Mac without learning anything first.

        ## Making one

        From the app, in the **Tools** tab, or from the menu beside the Terminal
        button: **Create Shipment…**. From a terminal:

            msl work --shipment
            msl work --shipment -o ~/Desktop/work.mslship

        The instance has to be **shut down** first. A shipment taken from a
        running machine catches its filesystem halfway through a write, which
        makes a file that looks fine and is not.

        Expect it to take a few minutes and produce a file a few hundred
        megabytes to a gigabyte or so, depending on how much is in the instance.
        Most of that time is compression.

        ## Installing one

        **New Instance → Install MSL Shipment…**, or:

            msl shipment install work.mslship
            msl shipment install work.mslship --name borrowed

        If the name inside is already taken, MSL picks a free one rather than
        writing over the instance you have. To see what is in a file before
        committing to it:

            msl shipment info work.mslship

        That reads only the small manifest at the front of the file, so it
        answers immediately even for a very large shipment.

        ## What travels, and what it does on arrival

        | | |
        |---|---|
        | The filesystem | Everything - applications, files, configuration |
        | Your Linux account | The one you log in as, so the instance opens as you |
        | CPUs, memory, disk size | Applied to the new instance |
        | Sandbox seals | Applied, but see below |
        | Experimental features | Applied **to that instance only** |

        **Experiments do not change your MSL.** The settings in a shipment are
        recorded as overrides for the instance it created and nothing else, so
        installing a shipment from someone who runs MSL differently from you
        leaves your own switches exactly as they were. Only the differences are
        stored, so an instance is not frozen against settings its author never
        touched.

        Some things cannot be reproduced on every Mac. If a shipment wanted GPU
        acceleration and this Mac has no renderer installed, that one is
        skipped, and MSL says which and why rather than pretending.

        **Seals only travel in the safe direction.** A sealed shipment installs
        sealed. An open one does not unseal anything - it leaves your defaults
        alone.

        ## Before you install someone else's

        A shipment is a complete Linux system somebody else assembled. It can
        contain anything they put in it, and installing one is closer to running
        their computer than to opening their document. Install shipments from
        people you trust.

        The checksum inside a shipment is there to catch a damaged or truncated
        file. It is not a signature, and it says nothing about who made it.

        ## Where the file goes

        A `.mslship` is a plain zip. You can look inside with Archive Utility or
        `unzip -l` and find two things: `msl.json`, which is the manifest above,
        and the compressed disk. Nothing is hidden or encrypted.
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

        The **MSL** panel in MSL Files has an *MSL itself* card showing how much the logs have grown, with
        **Show** and **Clear**. Clearing empties them in place rather than deleting the files, because MSL's
        background service holds them open while it runs — a deleted log would leave it writing somewhere
        nothing can read, until it next restarted.

        MSL's record of what instances were started, stopped and changed is kept separately and is not touched
        by clearing the logs.

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
        related: ["background-service", "generated-apps", "mslap-capabilities"],
        body: #"""
        **Window ▸ Remove MSL…**, or `msl uninstall` in a terminal. Both build the same itemised list and remove the
        same things, so the two can never disagree about what MSL leaves behind.

        The window shows the choice first — **Keep my Linux** or **Remove everything** — then every item with its
        size, and removes nothing until you have read it. Deleting your Linux asks again, with the instance count
        and the total.

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
        - The Admin Portal's password and signing keys, and any encrypted containers, in
          `/Users/Shared/MSL`. Those are MSL's own records about who administers this Mac, not your Linux, so they
          go in both modes.
        - An enrolled policy in `/Library/Application Support/MSL`.
        - Things that are not files: Dock tiles for your Linux apps, the app's registration with macOS so it stops
          appearing in Spotlight and Launchpad, and the installer's receipt so a reinstall does its own work.

        A few of those belong to the system, so macOS asks for your password once at the end. MSL finishes the job
        itself rather than printing a `sudo rm -rf` for you to paste — an uninstaller that stops and hands you a
        command has not finished.

        If an instance is in an encrypted container and you are keeping your Linux, its disk is taken back out
        first. The key lives in `/Users/Shared/MSL`, which is about to go, and leaving a disk inside would make it
        permanently unreadable — see [Protecting an image](help:instances-protect).

        Running instances are shut down properly first - not hibernated, because a saved session with no MSL to
        restore it is worse than a clean power-off. Anything mounted in Finder is unmounted before that.

        ## What stays {#kept}

        - Every distro disk image, and everything inside it.
        - Your instances, the accounts you made, and each instance's storage settings.
        - Your custom images, in `Custom Images`.
        - MSL's own settings, so a reinstall doesn't switch something back on that you switched off.

        ## Under a policy {#policy}

        An administrator can deny `system.uninstall`. The menu item is still there and the refusal says who decided
        and why, because hiding it would leave you hunting for something that is not there — see
        [Reading a refusal](help:mslap-refusals).

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
