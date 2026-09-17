import Foundation

// Chapter 3. The main window: sidebar, header, tabs and banners.

extension HelpChapter {
    static let mainWindow = HelpChapter(
        id: "main-window", title: "The Main Window", symbol: "macwindow", tint: .blue,
        blurb: "The sidebar, the header, the tabs, and the banners that come and go.",
        articles: [.mainWindow, .sidebar, .instanceHeader, .banners])
}

extension HelpArticle {
    static let mainWindow = HelpArticle(
        id: "main-window", title: "The main window", symbol: "macwindow",
        summary: "One sidebar of instances, one detail pane with five tabs.",
        keywords: ["layout", "window", "detail pane", "tabs", "segmented control", "refresh", "⌘R"],
        related: ["sidebar", "instance-header", "tour"],
        body: #"""
        MSL's main window is a sidebar on the left listing your instances, and a detail pane on the right for the one
        you've selected.

        ## The detail pane {#detail}

        From top to bottom:

        1. **The header** — the instance's name, distro and state, and its main buttons. See
           [The instance header](help:instance-header).
        2. **The tab bar** — Applications · Terminal · Overview · Tools · Sandbox.
        3. **The tab itself.**

        @card square.grid.2x2 purple | Applications | Linux GUI apps inside the instance — open, add to Applications, pin to Dock.
        @card terminal indigo | Terminal | A real Linux shell, right in the window.
        @card list.bullet.rectangle teal | Overview | SSH, CPUs and memory, storage, the shared home folder.
        @card wrench.and.screwdriver orange | Tools | The service, snapshots, maintenance and repair, suspend and shut down.
        @card lock.shield red | Sandbox | Four switches that cut the instance off, and the Traffic Monitor.

        > [!NOTE] Tabs start on Applications
        > Selecting a different instance opens it on its Applications tab. Terminal sessions aren't lost when you
        > switch — each instance keeps its own shell running in the background until you end it.

        ## With nothing selected {#empty}

        The detail pane says "No instance selected" and offers **New Instance…**. If MSL's background service isn't
        running, it says that instead and offers **Start it** — see [The background service](help:background-service).

        ## Refreshing {#refresh}

        MSL keeps itself up to date: instance states refresh every few seconds on their own. **View ▸ Refresh** (⌘R)
        asks right away, which is handy after doing something from Terminal with the `msl` command.
        """#)

    static let sidebar = HelpArticle(
        id: "sidebar", title: "The sidebar", symbol: "sidebar.left",
        summary: "Your instances, how many are running, New Instance, and the people who built MSL.",
        keywords: ["instance list", "capacity", "running count", "context menu", "right click", "contributors", "built by", "status dot"],
        related: ["concurrency", "stopping-instances", "removing-instances"],
        body: #"""
        ## Instance rows {#rows}

        Each row shows:

        - **The distro badge** — a rounded square in the distro's colour with its symbol.
        - **The name**, and the distro under it.
        - **A status dot** on the right: green running, orange suspended, yellow starting, grey stopped. While the
          instance is busy — starting, suspending, restoring a snapshot — a small spinner replaces the dot.

        Click a row to show that instance in the detail pane.

        ## The capacity pill {#capacity}

        Beside the **Instances** heading, a pill like `2/4` shows how many instances are running (or suspended) out of
        the most MSL will run at once. It turns **orange** when every slot is taken, and hovering over it explains.

        Suspended instances count because they still hold their memory on your Mac. See
        [How many can run at once](help:concurrency).

        ## Right-click menu {#context-menu}

        Right-click (or Control-click) any instance:

        | Item | What it does |
        |---|---|
        | **Start** | Starts or resumes it. Only shown when it isn't running, greyed out when every slot is taken. |
        | **Suspend** | Freezes it in memory. Only shown while running. |
        | **Shut Down** | Stops it straight away. Only shown while running — read [the note on Shut Down](help:stopping-instances#shut-down) first. |
        | **Open in Terminal.app** | Opens a shell on it in a Terminal.app window. |
        | **Show Apps in Finder** | Opens the folder of Mac apps MSL has made for it. |
        | **Remove…** | Removes the instance. See the warning below. |

        > [!DANGER] Remove happens straight away
        > Despite the "…", **Remove…** doesn't ask first. It unregisters the instance, deletes its saved state and
        > snapshots, and deletes the Mac apps made for it. The distro's disk image — and every file in it — is
        > untouched. See [Removing an instance](help:removing-instances).

        ## New Instance {#new}

        At the bottom of the list. Same as ⌘N. See [Creating an instance](help:create-instance).

        ## Built by {#built-by}

        Under that, a strip of small avatars: everyone who has landed a commit in MSL's repository, read live from
        GitHub. Hover to see their names; click to open the contributors page. If GitHub can't be reached, the strip
        quietly doesn't appear — nothing in the sidebar ever nags about it. The About window's **Contributors** section
        has everyone in full, each with their own colour. ٩(ˊᗜˋ*)و
        """#)

    static let instanceHeader = HelpArticle(
        id: "instance-header", title: "The instance header", symbol: "rectangle.topthird.inset.filled",
        summary: "The name, the state, and the buttons that change with it: Start, Suspend, Resume, Install.",
        keywords: ["start button", "suspend button", "resume", "install button", "header", "terminal button", "split button"],
        related: ["stopping-instances", "install-distro", "terminal-tab"],
        body: #"""
        Across the top of the detail pane: a large distro badge, the instance's name, and "*Distro* · *State*" under
        it. On the right, the buttons — which ones depends on the state.

        ## The buttons {#buttons}

        **Terminal** is always there. It switches to the Terminal tab, which opens a shell (starting the instance if
        needed).

        The second button changes:

        | When the instance is… | You see | Clicking it… |
        |---|---|---|
        | Stopped, distro downloaded | **Start** | starts it (or resumes a hibernated session). |
        | Stopped, distro not downloaded | **Install *Distro*** | downloads the image. Shows **Downloading…** meanwhile. |
        | Running | **Suspend** ▾ | freezes it. |
        | Suspended | **Resume** ▾ | unfreezes it, almost instantly. |

        **Suspend** and **Resume** are split buttons: click the main part for the action, or the small arrow for the
        same menu as right-clicking the instance in the sidebar — Shut Down, Open in Terminal.app, Show Apps in Finder
        and Remove….

        > [!NOTE] Why Start is sometimes grey
        > It's disabled while the instance is busy (a spinner shows beside the buttons) and when every running slot
        > is already taken. Hovering over it says which.

        ## Busy {#busy}

        While MSL works on an instance — starting, suspending, hibernating, restoring a snapshot — a small spinner
        appears in the header and on its sidebar row, and the buttons wait until it's done.
        """#)

    static let banners = HelpArticle(
        id: "banners", title: "Banners and messages", symbol: "text.bubble",
        summary: "The notices that drop in from the top of the window, and which ones stay.",
        keywords: ["notification", "error message", "alert", "toast", "message", "dismiss", "popup"],
        related: ["trouble-wont-start", "logs-and-doctor"],
        body: #"""
        When something finishes or goes wrong, MSL says so in a banner that slides down from the top of the window,
        rather than an alert you'd have to click away.

        | Banner | Icon | Goes away |
        |---|---|---|
        | **Success** — "Created work", "Saved 'before-upgrade'" | green tick | by itself, after a few seconds |
        | **Information** — "No GUI applications found in work" | blue info | by itself, after a few seconds |
        | **Error** — "Couldn't start work", with the reason under it | orange triangle | only when you close it |

        Errors stay on purpose: an error you missed is one you'll hit again. Close any banner with the **×** on its
        right.

        > [!TIP] Errors with a long reason
        > The detail under an error is the actual reason from MSL's background service. If it's cryptic, the service's
        > log usually has more — see [Logs and msl doctor](help:logs-and-doctor).

        ## Messages inside cards {#in-cards}

        Some parts of the app report in place instead, right where you clicked: the Maintenance card shows its results
        in a coloured box under its buttons (green, orange, red or blue), the Storage card shows problems in orange
        under its controls, and the Terminal tab shows "Session ended" over the terminal.
        """#)
}
