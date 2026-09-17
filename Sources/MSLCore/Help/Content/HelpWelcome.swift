import Foundation

// Chapter 1. The guide's front door: what MSL is, a tour, the words it uses,
// how it works underneath, and an honest list of what is and isn't ready.

extension HelpChapter {
    static let welcome = HelpChapter(
        id: "welcome", title: "Welcome", symbol: "sparkles", tint: .melon,
        blurb: "What MSL is, a quick tour, and the words you'll keep seeing.",
        articles: [.welcome, .tour, .vocabulary, .howItWorks, .whatsReady, .usingHelp])
}

extension HelpArticle {
    static let welcome = HelpArticle(
        id: "welcome", title: "Welcome to MSL", symbol: "hand.wave",
        summary: "Real Linux on your Mac, as close to native as one project could get it.",
        keywords: ["introduction", "overview", "about", "what is msl", "mac subsystem for linux", "start here"],
        related: ["tour", "install-distro", "whats-ready"],
        body: #"""
        MSL — the **Mac Subsystem for Linux** — runs real Linux distributions on your Mac. Not an emulator and not a
        compatibility layer: an actual Linux kernel with an actual Linux userland, running on Apple's own
        Virtualization framework, so there's no emulation in the way and no virtual-machine window to look after.

        You get a real Linux shell in about a second, and — experimentally — Linux apps with windows of their own,
        each with its own Dock tile, its own icon and its own name in the menu bar. ヽ(・∀・)ﾉ

        > [!ASIDE] A small offering
        > macOS already has plenty of good ways to reach Linux: Docker, UTM, Lima, OrbStack, a VM in a window.
        > MSL isn't here to replace any of them. It's another path — one that tries to make Linux feel like it
        > belongs on the Mac, with a lot of engineering effort, care and getting-it-wrong-first poured into it.
        > If it suits the way you work, lovely. If one of the others suits you better, that's lovely too.

        ## What you can do with it {#what-you-can-do}

        @card terminal indigo | Open a Linux shell | A real login shell with job control, colours and line editing, inside the app or in Terminal.app.
        @card square.grid.2x2 purple | Run Linux apps | Linux GUI programs open as ordinary Mac windows, each with its own Dock tile.
        @card folder rind | Share files both ways | Your Mac home folder appears inside Linux at /mnt/mac, and MSL Files browses both sides.
        @card memorychip teal | Size each machine | Choose CPUs, a fixed or dynamic amount of memory, and how big each disk may grow.
        @card clock.arrow.circlepath orange | Save and roll back | Snapshots, hibernation, and disk check-and-repair tools with automatic backups.
        @card lock.shield red | Cut things off | Sandbox switches that detach the network, the home share, graphics or input.

        ## Where to go next {#next}

        - New here? The [two-minute tour](help:tour) walks the whole app from left to right.
        - Ready to go? [Install a distro](help:install-distro), then [create an instance](help:create-instance).
        - Curious how it works? [Under the hood](help:how-it-works) explains the moving parts in plain words.
        - Want to know what's solid and what's still experimental? [What's ready](help:whats-ready) is honest about it.

        > [!TIP] Searching this guide
        > The search field at the top of the sidebar finds any word in the guide — and it's forgiving: it copes with
        > typos, finishes words as you type, and knows that "RAM" means memory and "VM" means instance.
        > Press **⌘F** in this window to jump to it. More in [Using this guide](help:using-help).
        """#)

    static let tour = HelpArticle(
        id: "tour", title: "A two-minute tour", symbol: "map",
        summary: "Every window and panel in MSL, in the order you'll meet them.",
        keywords: ["tour", "walkthrough", "layout", "interface", "ui", "screens", "tabs", "windows"],
        related: ["main-window", "files-window", "shortcuts"],
        body: #"""
        MSL has one main window, a file browser, and a few smaller windows. Here's all of it, left to right.

        ## The main window {#main}

        A sidebar-and-detail window, like Mail or Notes.

        - **The sidebar** lists your [instances](help:vocabulary#instance) — each is one Linux machine with its own
          name. A coloured badge shows the distro; a small dot shows whether it's running. At the top, a pill like
          `1/4` shows how many are running out of the most MSL will run at once. At the bottom: **New Instance**,
          and a strip of the people who built MSL.
        - **The header** across the top of the right-hand side shows the selected instance's name, distro and state,
          with **Terminal** and **Start** (or **Suspend**/**Resume**, or **Install** if its distro isn't downloaded).
        - **Five tabs** sit under the header. More on each below.

        More detail: [The main window](help:main-window).

        ## The five tabs {#tabs}

        | Tab | What it's for |
        |---|---|
        | **Applications** | The Linux GUI apps inside the instance, with their real icons. Open them, add them to your Applications folder, pin them to the Dock. |
        | **Terminal** | A full terminal with a real Linux shell in it. |
        | **Overview** | The instance's settings: SSH, CPUs and memory, disk size, the shared home folder. |
        | **Tools** | The background service, generated apps, snapshots, maintenance and repair, and suspend/hibernate/shut down/remove. |
        | **Sandbox** | Switches that cut the instance off from the network, your files, graphics or input — plus the Traffic Monitor. |

        ## The other windows {#other-windows}

        - **MSL Files** (⌥⌘F) — a Finder work-alike that shows your Mac and your running Linux instances side by side,
          so you can drag files across. See [MSL Files](help:files-window).
        - **Traffic Monitor** — a live log of what MSL and an instance are saying to each other. Opened from the
          Sandbox tab. See [Traffic Monitor](help:traffic-monitor).
        - **About MSL** — what MSL is, its licences, the people who built it, and some stories. It's in the MSL menu.
        - **MSL Help** — this. It's in the Help menu.

        ## Things that happen on their own {#automatic}

        - MSL's background service, `mslhd`, starts when you log in. It's what actually runs every instance, and it
          keeps running when the MSL window is closed — Linux apps you've added to your Dock work without MSL open.
        - When you close the last terminal session on an instance, MSL suspends it a few seconds later so it stops
          using your processor. Opening a shell or an app wakes it again. See [Idle instances](help:idle).
        - When your Mac sleeps, shuts down or logs out, MSL freezes every running instance first so nothing is
          mid-write. See [Sleep, shutdown and battery](help:power-events).
        """#)

    static let vocabulary = HelpArticle(
        id: "vocabulary", title: "Words you'll see", symbol: "character.book.closed",
        summary: "Instance, distro, image, guest, host, mslhd, mslgd — what each one means here.",
        keywords: ["terms", "terminology", "definitions", "jargon", "meaning", "explained"],
        related: ["glossary", "how-it-works"],
        body: #"""
        A handful of words come up everywhere in MSL. Here they are in the order they start to matter. The
        [glossary](help:glossary) has the full A–Z.

        ## Instance {#instance}

        One Linux machine, with a name you chose — `work`, `scratch`, `gimp-box`. Each instance has its own settings,
        its own saved state, its own apps list and its own sandbox switches. You can have as many as you like.

        ## Distro {#distro}

        Short for *distribution* — the flavour of Linux: Alpine, Debian, Ubuntu, Arch, Fedora, Rocky and more. Every
        instance is one distro, chosen when you create it. See [Choosing a distro](help:choosing-distro).

        ## Image {#image}

        A distro's disk: one big file on your Mac that holds the whole Linux filesystem. You download it once per
        distro.

        > [!IMPORTANT] Instances of the same distro share one disk
        > Two Debian instances use the same Debian image. That keeps your Mac's disk from filling with copies — and
        > it means **only one instance of a given distro can run at a time**, because two running machines writing to
        > one disk would wreck it. Different distros run side by side happily. See
        > [Shared disks](help:shared-disks).

        ## Guest and host {#guest-host}

        The **guest** is Linux, inside the virtual machine. The **host** is your Mac. "Guest-side" means something
        happens inside Linux; "host-side" means your Mac does it from outside, where Linux can't interfere.

        ## Running, suspended, hibernated, stopped {#states}

        | State | Dot | What it means |
        |---|---|---|
        | **Running** | green | Linux is up. |
        | **Starting…** | yellow | On its way up or down. |
        | **Suspended** | orange | Frozen in memory. Resumes almost instantly, but still holds its memory on your Mac. |
        | **Stopped** | grey | Not running. It may have a hibernated session saved to disk — then starting it picks up exactly where it left off. |

        The difference between suspend, hibernate and shut down is covered properly in
        [Suspend, hibernate or shut down?](help:stopping-instances).

        ## mslhd {#mslhd}

        MSL's **background service**. It hosts every instance, starts at login, and keeps running when the MSL window
        is closed. If it isn't running, nothing can start. See [The background service](help:background-service).

        ## mslgd {#mslgd}

        MSL's own **X11 display server** — the part that turns a Linux app's drawing into a real Mac window. It was
        written from scratch for MSL. See [Under the hood](help:how-it-works#mslgd).

        ## Snapshot {#snapshot}

        A saved copy of a whole running machine — memory and disk — that you can go back to. See
        [Snapshots](help:snapshots).

        ## Gate {#gate}

        One of the four [Sandbox](help:sandbox) switches: network, Mac home share, graphics, keyboard & mouse.
        A gate is either open or cut.
        """#)

    static let howItWorks = HelpArticle(
        id: "how-it-works", title: "Under the hood", symbol: "gearshape.2",
        summary: "The moving parts — the VM, the service, the display server, the per-app processes — in plain words.",
        keywords: ["architecture", "internals", "virtualization framework", "vsock", "technical", "design", "x11"],
        related: ["vocabulary", "linux-windows", "background-service"],
        body: #"""
        You never need to know any of this to use MSL. But when something behaves in a way that seems odd, the reason
        is usually here.

        ## A real virtual machine {#vm}

        Each running instance is a lightweight virtual machine made with Apple's **Virtualization framework** — the
        same technology behind most Mac virtualisation apps. Your Mac's processor runs Linux directly; nothing is
        translated or emulated. That's why a shell opens in about a second, and why Linux programs run at close to
        full speed.

        The virtual machine has no window of its own. Everything you see — the terminal, the app windows, the files —
        reaches your Mac through MSL, not through a screen.

        ## The background service {#service}

        `mslhd` runs every virtual machine. It's installed as a login item, so it starts when you log in and keeps
        going when the MSL window is closed. The app, the `msl` command, and the Linux apps in your Dock all ask it to
        do things — start this, suspend that, open a shell — over a private connection on your Mac.

        Its log is at `~/Library/Logs/MSL/mslhd.log`. See [The background service](help:background-service).

        ## Talking to Linux {#vsock}

        The Mac and each guest talk over **vsock**, a direct channel between a virtual machine and its host that
        doesn't go through the network at all. Shells, file access, app launching and window traffic all use it.

        This is why cutting the network in the [Sandbox](help:sandbox) doesn't stop `msl` shells from working:
        detaching the network card doesn't touch vsock.

        ## Your files, both ways {#files}

        - **Mac → Linux:** your home folder is shared into every running instance at `/mnt/mac`.
        - **Linux → Mac:** each running instance's filesystem is served back to your Mac as a network volume.
          Finder can see it, but it's named after a loopback address rather than the instance, which is why
          [MSL Files](help:files-window) exists: it shows each instance by name, beside your Mac's folders.

        ## Windows for Linux apps {#mslgd}

        Linux GUI apps draw through a protocol called **X11**. On most Macs the X11 answer is XQuartz, which works
        well — but under it, every Linux app is a window belonging to XQuartz: one Dock tile, one menu bar, one app.

        MSL tried the other thing. **mslgd** is an X11 server written from scratch in Swift, drawing straight into
        AppKit and Core Graphics, so each Linux window becomes a real Mac window. And because macOS gives exactly one
        Dock tile per process, **each Linux app runs in its own small helper process** on your Mac — that's how it gets
        its own tile, icon, name and place in Mission Control.

        > [!ASIDE] Honest footnote
        > This is the part MSL exists to attempt, rather than a finished claim about how well it does it. Plenty of
        > apps work nicely; some still draw oddly. The About window's Extras section has the full story, swearing
        > included. ( ͡° ᴥ ͡°)

        ## Apps as Mac apps {#bundles}

        When you [add a Linux app to your Applications folder](help:add-to-applications), MSL writes a real, tiny
        `.app` into `~/Applications/MSL/<instance>/`. Opening it asks the background service to start the instance
        if it needs to, then runs the Linux program. That's why Spotlight and the Dock can launch Linux apps with the
        MSL window closed.
        """#)

    static let whatsReady = HelpArticle(
        id: "whats-ready", title: "What's ready, what's experimental", symbol: "checklist",
        summary: "An honest map of what's solid and what's still experimental.",
        keywords: ["status", "experimental", "beta", "limitations", "known issues", "roadmap"],
        related: ["trouble-maintenance", "memory-dynamic", "maintenance"],
        body: #"""
        This is MSL-1.0.0 — still held together with love. Here's where things stand, so nothing catches you out.

        ## Solid {#solid}

        - Installing distros and creating instances.
        - Shells — in the app, in Terminal.app, over SSH, and with the `msl` command.
        - Suspend, hibernate, shut down, snapshots, and protecting instances when your Mac sleeps or shuts down.
        - CPU count, manual memory, disk sizing and automatic disk growth.
        - Your home folder inside Linux at `/mnt/mac`, and MSL Files.
        - The Sandbox gates and the MSL side of the Traffic Monitor.
        - Checking and repairing a disk from the Mac, with automatic backups (needs one free tool — see
          [Checking a disk](help:disk-check)).

        ## Experimental {#experimental}

        - **Linux GUI apps as Mac windows.** Many apps work well; some draw imperfectly. It's the most ambitious part
          of MSL and the most likely to surprise you.
        - **Everything in Experimental Features** (**Window ▸ Experimental Features**). Every experiment lives there, and
          each says whether it starts on or off:
          - **Open links on the Mac** (on) — web and email links from Linux apps open in your Mac's browser and mail
            app, with attachments.
          - **Show folders in MSL Files** (on) — "Open containing folder" and friends open MSL Files instead of a Linux
            file manager. Nautilus, Dolphin and the rest still run when you start them yourself.
          - **Linux app menus in the menu bar** (off) — a Linux app's menus move into the Mac menu bar. Qt and KDE apps
            support it on their own; GTK apps need `appmenu-gtk3-module` in the instance.
          - **Mac shortcuts, text navigation, screenshot keys and Option keys** (off) — how Linux apps receive your
            keyboard.

        Experiments aren't promises: a future version may build one in properly, change it, or remove it, depending on
        what the community prefers. The list is specific to each version.
        """#)

    static let usingHelp = HelpArticle(
        id: "using-help", title: "Using this guide", symbol: "questionmark.circle",
        summary: "How search works, what the coloured boxes mean, and the keys for getting around.",
        keywords: ["help", "search", "find", "guide", "manual", "documentation", "docs", "how to search"],
        related: ["shortcuts", "glossary"],
        body: #"""
        Open this guide from anywhere in MSL with **Help ▸ MSL Help**. From the keyboard, **⇧⌘?** opens the Help menu
        in any Mac app — then choose MSL Help. The same menu also jumps straight to Getting Started, Keyboard Shortcuts,
        Troubleshooting, and what's ready or experimental.

        ## Searching {#searching}

        Type in the search field at the top of the sidebar. Results appear as you type, each one pointing at the exact
        section that matches — click one and the guide scrolls there, with your words highlighted.

        Search is deliberately forgiving:

        - **Every word counts.** `memory dynamic` finds places that mention both. If nothing mentions all of them,
          you get the places that mention some.
        - **Half-typed words work.** `snaps` already finds snapshots.
        - **Other forms work.** `restoring`, `restored` and `restores` all find each other.
        - **Typos work.** A letter missing, doubled or swapped with its neighbour still finds the word you meant.
        - **Everyday words work.** `ram` finds memory, `vm` finds instances, `delete` finds remove, `fsck` finds disk
          repair, `wifi` finds the network gate, `wireshark` finds the Traffic Monitor.
        - **Keys work.** Search for `⌘` or `shortcut` to find keyboard shortcuts.

        @keys ⌘F | Jump to the search field
        @keys ⎋ | Clear the search
        @keys ⇧⌘? | Open the Help menu, in any Mac app

        ## Reading {#reading}

        Each article starts with a one-line summary and an "On this page" list of its sections — click any of them to
        jump. Blue links go to other parts of the guide. **Related** at the bottom suggests where to read next, and
        the arrows at the very end step through the whole guide in order.

        ## The coloured boxes {#callouts}

        > [!TIP] Tip
        > A shortcut, or a nicer way to do something.

        > [!NOTE] Note
        > Extra detail worth knowing.

        > [!IMPORTANT] Important
        > Something that changes how a feature behaves.

        > [!WARNING] Warning
        > Something that can cost you time or work if you miss it.

        > [!DANGER] Danger
        > Something you can't undo.

        > [!ASIDE] Aside
        > MSL being a person for a moment. (˶ᵔ ᵕ ᵔ˶)
        """#)
}
