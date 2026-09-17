import Foundation

// Chapter 8. The Sandbox tab and the Traffic Monitor.

extension HelpChapter {
    static let sandbox = HelpChapter(
        id: "sandbox", title: "Sandbox Tab", symbol: "lock.shield", tint: .red,
        blurb: "Cut an instance off from the network, your files, graphics or input — and watch what it says.",
        articles: [.sandbox, .sandboxGates, .trafficMonitor])
}

extension HelpArticle {
    static let sandbox = HelpArticle(
        id: "sandbox", title: "The Sandbox tab", symbol: "lock.shield",
        summary: "Four switches that decide what one instance can reach, and one button to seal it.",
        keywords: ["sandbox", "isolate", "seal", "lock", "security", "privacy", "untrusted", "posture", "open everything"],
        related: ["sandbox-gates", "traffic-monitor"],
        body: #"""
        The Sandbox tab decides what an instance can reach. It has three parts: a header saying how locked-down the
        instance is, the four **Gates**, and **Watch**, which opens the Traffic Monitor.

        ## The header {#posture}

        A lock icon and one word:

        | Posture | Icon | Means |
        |---|---|---|
        | **Open** | open lock, grey | Every gate is open. The instance has the network, your home folder, graphics and input. |
        | **Partly sealed** | lock with clock, orange | Some gates are closed — the line under it says how many. |
        | **Sealed** | closed lock, red | Every gate is closed: "no network, no share, no new windows, no input." |

        On the right, one button does everything at once: **Seal it** closes all four gates; **Open everything** opens
        them all.

        ## The gates {#gates}

        Four switches, each **Open** or **Cut**: **Network**, **Mac home share**, **Graphics (mslgd)**, and
        **Keyboard & mouse**. When one is cut, a line under it says exactly what that does. Each is covered in
        [The four gates](help:sandbox-gates).

        ## Gates stick {#persist}

        As the card's footnote says, gates are kept across restarts and re-applied every time the instance starts or
        resumes — "so hibernating won't quietly hand anything back." You can close gates on a stopped instance, too;
        the header then says what it *will* have when it starts, which is the way to sandbox something before it
        ever runs.

        ## What the Sandbox is — and isn't {#limits}

        > [!IMPORTANT] Switches on top of the virtual machine
        > Every gate is enforced by your Mac, from outside Linux. Nothing asks Linux to behave, so software inside
        > it can't undo a gate.
        >
        > But they are switches *on top of* the virtual machine, not the security boundary itself — the virtual
        > machine is that. They don't harden the VM against escape. The tab says this too when anything is closed.

        > [!NOTE] The switches show the truth, not the request
        > The gates reflect what the virtual machine's devices are actually doing, as reported by MSL's background
        > service — not just what was last asked for. If something settles differently from what you asked, a
        > banner says "The sandbox settled differently".
        """#)

    static let sandboxGates = HelpArticle(
        id: "sandbox-gates", title: "The four gates", symbol: "switch.2",
        summary: "Exactly what cutting the network, home share, graphics or input does — and doesn't do.",
        keywords: ["network gate", "cut network", "disconnect", "offline", "internet", "home share gate", "graphics gate", "input gate", "keyboard", "mouse", "unplug"],
        related: ["sandbox", "home-share", "ssh", "trouble-ssh"],
        body: #"""
        Each gate is honest about its scope, because "cut the internet" and "unplug this VM's network card" are not
        the same promise.

        ## Network {#network}

        > The virtual network card is detached. The guest keeps its IP and routes but no packet reaches the host, so
        > it looks like an unplugged cable rather than a firewall block.

        - Linux can't reach the internet, your local network, or your Mac over the network.
        - **SSH stops working**, because SSH uses the network. The SSH card says the address isn't answering and
          names this gate as a likely reason.
        - **`msl` shells, the Terminal tab and MSL Files keep working.** They use a direct channel between your Mac
          and the virtual machine (vsock) that doesn't go through the network card at all.

        ## Mac home share {#home-share}

        > /mnt/mac stops resolving. Anything already reading a file there will see I/O errors, not a clean unmount.

        Linux loses access to your Mac home folder. Close anything using files in `/mnt/mac` before cutting it.

        ## Graphics (mslgd) {#graphics}

        > mslgd stops accepting new X11 connections. Windows that are already open keep their connection and keep
        > drawing.

        New Linux app windows can't open. Apps already on screen carry on — cut this *before* launching things if you
        want none of them.

        ## Keyboard & mouse {#input}

        > Keyboard and pointer events are dropped on the host side, before they are encoded. The guest sees an idle
        > input device, not a disconnected one.

        Linux app windows still draw, but typing and clicking in them do nothing. Handy for watching something run
        without nudging it by accident.

        ## Combining them {#combining}

        | You want | Cut |
        |---|---|
        | No internet, but keep working in the shell | Network |
        | Keep a program away from your personal files | Mac home share |
        | Stop an instance from putting windows on your screen | Graphics |
        | Look but don't touch | Keyboard & mouse |
        | Everything, for something you don't trust | **Seal it** |
        """#)

    static let trafficMonitor = HelpArticle(
        id: "traffic-monitor", title: "The Traffic Monitor", symbol: "waveform.path.ecg",
        summary: "A live, minimalist log of what MSL and an instance are doing — and what Linux has connected.",
        keywords: ["traffic", "monitor", "wireshark", "log", "activity", "connections", "sockets", "network activity", "packets", "⇧⌘T"],
        related: ["sandbox", "whats-ready", "logs-and-doctor"],
        body: #"""
        The Traffic Monitor is a small, live view of what's happening between your Mac and an instance. Open it from the
        **Watch** card on the Sandbox tab — **Open**, or **⇧⌘T** while the Sandbox tab is showing. It slides down over
        the window; **Done** closes it.

        Along the top: **Pause**/**Resume** (freezes the list so you can read it), **Clear** (empties the log), and
        **Done**. Under that, two lanes.

        ## MSL activity {#msl-activity}

        MSL's own traffic: the things your Mac and the instance actually say to each other through MSL. Newest at the
        top, each with the time, a coloured icon and a short summary. Repeated events fold together with a count like
        **×12** instead of flooding the list.

        | Category | Colour | Covers |
        |---|---|---|
        | **Control** | blue | Commands to the background service: start, suspend, snapshot. |
        | **Files** | green | The file bridge — MSL Files and Finder reading and writing guest files. |
        | **Display** | purple | X11 connections, app windows, mslgd. |
        | **Lifecycle** | orange | The virtual machine itself: booted, paused, restored, stopped. |
        | **Sandbox** | red | Gates opening and closing. |

        Click a category's chip to hide or show it. **This instance only** (on by default) hides other instances'
        events — MSL-wide events, like the service starting, always show because they're context.

        With nothing to show yet it says "Listening…" — start the instance, open a file or launch an app and it'll
        appear. The footer counts what's shown.

        > [!IMPORTANT] Not a packet capture
        > This lane shows MSL's own traffic, which your Mac can genuinely see. It doesn't show Linux's own internet
        > connections — those live inside the virtual machine's network stack. That's the second lane.

        ## Guest connections {#guest-connections}

        What Linux itself has open, read from Linux's own network stack once a second:

        - Each row: **TCP** or **UDP**, then either "listening on *address:port*" or *local* → *remote*, the program
          that owns it, and its state (listening ones in green).
        - **Show processes** matches each connection to the program that owns it. That means looking through every
          open file of every program in Linux, so it's only done while you're looking.
        - **Hide loopback** (on by default) hides connections that never leave the guest, and says how many it hid.

        This lane reports *sockets, not packets*: that something is connected to an address, and who owns it — not
        what was sent.

        > [!NOTE] Only while it's running
        > If the instance isn't running, this lane says so — and won't start it just to look, since that would change
        > the very thing you're watching.
        """#)
}
