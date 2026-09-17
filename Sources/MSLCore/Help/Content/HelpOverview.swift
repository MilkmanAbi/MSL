import Foundation

// Chapter 6. The Overview tab: what an instance is made of and how big it is.

extension HelpChapter {
    static let overview = HelpChapter(
        id: "overview", title: "Overview Tab", symbol: "list.bullet.rectangle", tint: .teal,
        blurb: "CPUs, memory, disk, the shared home folder — what each instance is made of.",
        articles: [.overviewTab, .processors, .memory, .memoryDynamic, .storage, .homeShare, .concurrency])
}

extension HelpArticle {
    static let overviewTab = HelpArticle(
        id: "overview-tab", title: "The Overview tab", symbol: "list.bullet.rectangle",
        summary: "Six cards describing and configuring one instance.",
        keywords: ["overview", "settings", "configuration", "preferences", "cards", "details"],
        related: ["processors", "memory", "storage"],
        body: #"""
        The Overview tab is a stack of cards, top to bottom:

        | Card | What's on it | More |
        |---|---|---|
        | **Instance** | Name, distribution and current state. | — |
        | **Connect over SSH** | A ready-made `ssh` command for this instance, and its details. | [SSH](help:ssh) |
        | **Processor & memory** | How many virtual CPUs, and how much memory — fixed or dynamic. | [CPUs](help:processors), [Memory](help:memory) |
        | **Storage** | How full the disk is, how big it may get, and what it really costs on your Mac. | [Storage](help:storage) |
        | **Shared with macOS** | Where your Mac home folder appears inside Linux. | [Home folder](help:home-share) |
        | **Concurrency** | How many instances are running out of the most MSL allows. | [Concurrency](help:concurrency) |

        > [!IMPORTANT] Most settings apply at the next start
        > A virtual machine's CPUs, memory and disk size are fixed when it boots. Change them while an instance is
        > running and MSL saves the change for its next start — each card says so in its footnote.
        """#)

    static let processors = HelpArticle(
        id: "processors", title: "Virtual CPUs", symbol: "cpu",
        summary: "How many processors an instance gets, and why it's fine to be generous.",
        keywords: ["cpu", "vcpu", "processor", "cores", "threads", "performance", "speed", "stepper"],
        related: ["memory", "concurrency"],
        body: #"""
        The **Virtual CPUs** row at the top of the **Processor & memory** card sets how many processors Linux sees.
        Use the stepper arrows; the number beside them is the current value.

        ## How many to choose {#how-many}

        The stepper goes from 1 up to this Mac's number of logical cores — the caption under it tells you how many
        that is.

        If you've never changed it, an instance gets **half of your Mac's cores, but at least 2 and never more than
        8**. That's a good default for almost everything; compiling large projects is the main reason to go higher.

        > [!TIP] CPUs are shared, not reserved
        > As the caption says: vCPUs are time-shared, not reserved. An instance with 8 vCPUs that's sitting idle
        > costs your Mac nothing, and several instances can each have several. Unlike memory, being generous here
        > doesn't take anything away from macOS until Linux is actually busy.

        ## Applying it {#apply}

        Click **Apply** at the bottom of the card. The change takes effect the next time the instance starts; a
        green **Saved** confirms it. **Revert** puts back what was saved.

        > [!WARNING] A hibernated session is discarded
        > If the instance was hibernated, its saved session can't be resumed into a machine of a different size, so
        > it's discarded and the instance starts fresh. Save your work inside Linux first.
        """#)

    static let memory = HelpArticle(
        id: "memory", title: "Memory: manual mode", symbol: "memorychip",
        summary: "A fixed amount of memory, and why MSL warns above three fifths of your Mac's RAM.",
        keywords: ["ram", "memory", "manual", "mb", "megabytes", "gigabytes", "paging", "warning", "three fifths", "allocate"],
        related: ["memory-dynamic", "processors", "trouble-memory"],
        body: #"""
        The **Memory** picker on the **Processor & memory** card has two modes: **Manual** and **Dynamic**. This page is
        about Manual; [Dynamic](help:memory-dynamic) has its own.

        **Manual** is a fixed amount, reserved on your Mac the whole time the instance is running. Type a number of
        megabytes in the **Memory** field and click **Apply**.

        | Megabytes | Is |
        |---|---|
        | 1024 | 1 GB |
        | 2048 | 2 GB |
        | 4096 | 4 GB |
        | 8192 | 8 GB |

        If you've never changed it, an instance gets **a sixth of your Mac's memory, at least 1 GB and at most 8 GB**
        — enough for desktop apps, and small enough that four instances together can't crowd macOS out.

        ## The warnings {#warnings}

        MSL checks the number as you type and explains anything worrying in a coloured box under it.

        > [!WARNING] Orange: more than three fifths of your Mac's memory
        > A virtual machine's memory is *wired down* — macOS can't compress it or page it out to make room for
        > anything else. Give an instance more than three fifths of your Mac and macOS is left with the rest for
        > itself and everything you're running. Expect heavy paging, beachballs, and possibly an unstable machine.
        > MSL still lets you — the box says "It will still start."

        > [!DANGER] Red: numbers that can't work
        > Too small for the Virtualization framework to start a VM, more than it allows for one VM, or more than
        > your Mac has in total. **Apply** stays greyed out until the number is possible.

        Pressing Return in the field also snaps a value that's out of range back to the nearest allowed one.

        ## When it takes effect {#when}

        At the instance's next start. A running instance keeps the memory it booted with; a hibernated session is
        discarded rather than resumed into a differently sized machine.
        """#)

    static let memoryDynamic = HelpArticle(
        id: "memory-dynamic", title: "Memory: dynamic mode", symbol: "waveform.path",
        summary: "Start at a maximum and hand back whatever Linux isn't using, continuously.",
        keywords: ["dynamic memory", "balloon", "ballooning", "automatic", "adaptive", "minimum", "maximum", "floor", "ceiling", "memd", "stall", "pressure"],
        related: ["memory", "whats-ready", "trouble-memory"],
        body: #"""
        **Dynamic** memory gives an instance a **Minimum** and a **Maximum**. It starts with the maximum, and MSL keeps
        watching how much Linux actually needs, handing back what it isn't using and letting it have more again as
        it needs it — never above the maximum, never below the minimum.

        ## Choosing the numbers {#numbers}

        - **Maximum** is what your Mac sets aside when the instance starts, and the most it can ever have.
        - **Minimum** is as far down as MSL will ever squeeze it.

        The same [warnings as manual mode](help:memory#warnings) apply to the maximum, and the minimum can't be larger
        than the maximum.

        > [!IMPORTANT] It can only give back, never grow past the maximum
        > The Virtualization framework fixes a VM's size when it boots. Dynamic memory works by letting Linux return
        > memory it isn't using — a *balloon* inside the guest that inflates to hand memory back to your Mac and
        > deflates to give it back to Linux. The balloon moves *within* the maximum; nothing can take an instance
        > above it. So set the maximum to the most you'd ever want it to have.

        ## How MSL decides {#how}

        Rather than guessing from one number, MSL looks at how much memory Linux is really using, how much it could
        free if it had to, and — most tellingly — whether programs inside are **stalling** while they wait for memory.
        It gives memory back gently when there's plenty spare, and returns it quickly the moment Linux starts to
        struggle. Linux images don't use swap, so MSL never squeezes an instance below what its programs are actually
        holding.

        ## The live readout {#live}

        While a dynamic instance is running, the bottom of the card updates every few seconds:

        | Row | Meaning |
        |---|---|
        | **Allocated right now** | What Linux currently has from your Mac. |
        | **Guest is using** | What its programs are really using, out of what it can see. |
        | **Guest stalling on memory** | The share of time programs spend waiting for memory. Only shown when it isn't zero. |
        | **Last change** | Why MSL last moved the number, in words. |
        | **Adjustments this session** | How many times it has moved since the instance started. |

        If the guest has swap turned on, a note says so: MSL still sizes it conservatively, but swap changes what
        running out of memory feels like.

        ## When it takes effect {#when}

        Switching between Manual and Dynamic, or changing the numbers, applies at the next start — like every
        memory change.
        """#)

    static let storage = HelpArticle(
        id: "storage", title: "Disk size and storage", symbol: "internaldrive",
        summary: "How full the disk is, how big it may get, dynamic versus fixed, and automatic growth.",
        keywords: ["disk", "storage", "space", "size", "capacity", "gb", "full", "grow", "resize", "sparse", "dynamic disk", "fixed disk", "reserve", "limit"],
        related: ["reclaim-space", "trouble-disk", "shared-disks"],
        body: #"""
        The **Storage** card on the Overview tab shows how full an instance's disk is and sets how big it may get.

        > [!IMPORTANT] Storage belongs to the distro
        > Every instance of a distro shares one disk, so this card is really about that distro's disk. Resize it from
        > `work` and `scratch` (the same distro) gets the bigger disk too.

        ## Reading the card {#reading}

        - **The usage bar** — "*X* used inside *name*" and "*N*% of *total*", with when it was last measured. The bar
          turns **orange** once the disk is 85% full. Until the instance has run once, it says "Start this instance
          once and MSL will measure how full it is."
        - **Guest disk size** — how big Linux thinks its disk is.
        - **Actually used on your Mac** — what the image file really takes on your Mac right now. For a dynamic disk
          this is usually far smaller than the disk size; a fixed disk adds "(reserved)".

        ## Dynamic or fixed {#modes}

        | | **Dynamic** (the default) | **Fixed** |
        |---|---|---|
        | On your Mac | Takes only the space Linux has actually written. | Reserves the whole size up front. |
        | The slider sets | the **Limit** | the **Size** |
        | Good for | Almost everyone. | Making sure the space is there, however full your Mac gets. |

        A new disk is dynamic, with a 64 GB limit.

        > [!WARNING] Switching to fixed takes a while
        > Reserving space means writing out the whole disk — "Reserving space on your Mac… this writes the whole disk,
        > so it can take a while." For a large disk that can be minutes. The card stays usable; the rest of the app
        > does too.

        ## Making it bigger {#bigger}

        Drag the slider (4 GB to 512 GB, in steps of 4) and let go. If the instance is stopped, the image grows right
        away; if it's running, the change waits for its next start. Either way, Linux's filesystem is stretched to
        fill the new size during the next start, and until then the card says "The guest filesystem is extended the
        next time this instance starts."

        > [!DANGER] Disks only grow
        > A disk can be made bigger but never smaller. Drag below its current size and the card says so and puts the
        > slider back.

        ## Growing automatically {#auto-grow}

        With a dynamic disk, **Grow automatically when it runs low** (on by default) looks after a disk that's smaller
        than its limit: whenever the instance starts with its disk at least 85% full, MSL grows it by 8 GB, up to the
        limit. When it's already at the limit, nothing grows and the log notes it.

        ## Your Mac's free space {#free-space}

        The footnote shows how much space is free on your Mac. A dynamic disk can't grow past what your Mac has room
        for, so keep an eye on both. See [The disk is full](help:trouble-disk).
        """#)

    static let homeShare = HelpArticle(
        id: "home-share", title: "Your home folder inside Linux", symbol: "folder.badge.person.crop",
        summary: "Your Mac home folder appears at /mnt/mac in every running instance.",
        keywords: ["mnt", "/mnt/mac", "shared folder", "home", "share", "files", "mount", "access mac files"],
        related: ["files-window", "sandbox-gates", "files-open-in-msl"],
        body: #"""
        Every running instance can see your Mac home folder at `/mnt/mac`. The **Shared with macOS** card on the
        Overview tab shows both ends:

        | | |
        |---|---|
        | **Home folder** (inside Linux) | `/mnt/mac` |
        | **Host path** (on your Mac) | your home folder, e.g. `/Users/you` |

        So `~/Documents/report.txt` on your Mac is `/mnt/mac/Documents/report.txt` in Linux. Changes on either side
        show up on the other straight away — it's the same file, not a copy.

        ```shell
        cd /mnt/mac/Desktop
        ls
        ```

        ## Only your home folder {#scope}

        Folders outside your home — `/Applications`, other drives, `/usr/local` — aren't visible inside Linux. That's
        why [MSL Files](help:files-open-in-msl) greys out **Open Folder in MSL** for them.

        ## Turning it off {#off}

        The **Mac home share** gate on the [Sandbox](help:sandbox-gates) tab revokes it for one instance: `/mnt/mac`
        stops resolving. Anything in the middle of reading a file there sees I/O errors rather than a clean unmount,
        so close things first.

        > [!TIP] The other direction
        > To reach Linux's files from your Mac, use [MSL Files](help:files-window) (⌥⌘F).
        """#)

    static let concurrency = HelpArticle(
        id: "concurrency", title: "How many can run at once", symbol: "square.stack.3d.up.fill",
        summary: "MSL runs at most four instances together, and why suspended ones count.",
        keywords: ["limit", "cap", "maximum instances", "four", "4", "slots", "concurrency", "already running", "capacity pill"],
        related: ["shared-disks", "stopping-instances", "trouble-wont-start"],
        body: #"""
        MSL runs **at most four instances at once**. The **Concurrency** card on the Overview tab shows "Running now:
        *n* of 4", and the capacity pill at the top of the sidebar shows the same, turning orange when all four are
        in use.

        ## Why there's a limit {#why}

        Every running or suspended instance keeps its memory on your Mac, and virtual machine memory can't be paged
        out. Without a limit, it would be easy to start enough instances to leave macOS gasping. The default memory
        size is chosen so that four instances together stay well within your Mac.

        ## What counts {#what-counts}

        | State | Uses a slot? |
        |---|---|
        | Running | Yes |
        | Suspended | Yes — it's frozen, but its memory is still held. |
        | Hibernated or stopped | No |

        ## When it's full {#full}

        **Start** is greyed out on stopped instances, and trying anyway says "4 instances are already running … Suspend
        or shut one down first." Things that would start an instance — **Find Apps**, a sharper icon for a Dock tile —
        say the same, or quietly fall back (an app added while the slots are full keeps its existing icon).

        To free a slot, **hibernate** or **shut down** something. Suspending doesn't free one. See
        [Suspend, hibernate or shut down?](help:stopping-instances).
        """#)
}
