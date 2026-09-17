import Foundation

// Chapter 4. Linux GUI apps: finding them, opening them, keeping them.

extension HelpChapter {
    static let applications = HelpChapter(
        id: "applications", title: "Applications Tab", symbol: "square.grid.2x2", tint: .purple,
        blurb: "Linux GUI apps as real Mac windows — find them, open them, keep them in your Dock.",
        articles: [.appsTab, .openingApps, .addToApplications, .pinToDock, .appSources, .linuxWindows])
}

extension HelpArticle {
    static let appsTab = HelpArticle(
        id: "apps-tab", title: "The Applications tab", symbol: "square.grid.2x2",
        summary: "A grid of the Linux GUI apps inside an instance, with their real icons.",
        keywords: ["apps", "applications", "grid", "find apps", "refresh", "scan", "desktop entries", ".desktop", "search apps", "icons"],
        related: ["first-app", "opening-apps", "app-sources"],
        body: #"""
        The Applications tab shows the graphical apps installed inside an instance — the programs a Linux desktop would
        list in its app menu. It's the tab MSL opens first.

        ## Finding apps {#finding}

        The first time, the tab is empty with a **Find Apps** button. Clicking it:

        1. starts the instance if it isn't running ("Starting an instance for the first time can take a moment"),
        2. reads every installed app's `.desktop` entry from inside Linux — the same file a Linux desktop reads to put
           an app in its menu,
        3. fetches each app's icon, and fills the grid.

        After that the button says **Refresh**, and "Updated *5 minutes ago*" beside it says when the list was last
        read. Refresh after installing or removing software inside Linux.

        > [!NOTE] Only apps with windows
        > Command-line programs have no `.desktop` entry, so they don't appear here — use them from the
        > [Terminal](help:terminal-tab). If nothing at all turns up, MSL says "No GUI applications found" and suggests
        > installing some.

        > [!TIP] Or just type its name
        > Any shell MSL opens — the Terminal tab, or `msl` in Terminal.app — can start GUI apps too: type `gnome-chess`
        > or `gimp` at the prompt and it opens as a Mac window. From a Mac terminal, `msl debian gimp` does the same in
        > one step.

        ## The toolbar {#toolbar}

        - **Search** — "Search *N* apps". Matches app names and descriptions, and the packaging: typing `flatpak` shows
          only Flatpak apps.
        - **Source picker** — All · System · User · Flatpak · Snap. It only appears when the instance has apps from more
          than one source. See [Where apps come from](help:app-sources).
        - **Find Apps / Refresh** on the right.

        ## Each tile {#tiles}

        | Part | Means |
        |---|---|
        | The icon | The app's own icon, drawn from its vector artwork when it has one, so it stays crisp. |
        | The name | Up to two lines. |
        | A small grey badge | Where it came from — only shown for User, Flatpak and Snap apps. |
        | A blue tick in the corner | It's in your Applications folder. |
        | A small spinner in the corner | MSL is fetching a sharper icon for it. |

        Hover over a tile to reveal three small buttons: **▶** open, **folder** add to or remove from Applications,
        and **pin** pin or unpin from the Dock. Hovering also shows the app's description.

        ## Right-click {#context-menu}

        **Open**, **Add to Applications** (or **Remove from Applications**), **Pin to Dock** (or **Unpin from Dock**),
        and — greyed out at the bottom — the exact command the app runs, for the curious.
        """#)

    static let openingApps = HelpArticle(
        id: "opening-apps", title: "Opening a Linux app", symbol: "play.rectangle",
        summary: "Double-click a tile, and a Linux app opens as a Mac window with its own Dock tile.",
        keywords: ["open app", "launch", "run app", "double click", "start app", "gui"],
        related: ["linux-windows", "trouble-apps", "add-to-applications"],
        body: #"""
        Double-click a tile, click its **▶**, or right-click and choose **Open**.

        If the instance isn't running, it starts first. A moment later the app appears as a normal Mac window — with its
        own tile in the Dock, its own name in the menu bar, and its own place in Mission Control and ⌘-Tab.

        ## Three ways in, one path {#one-path}

        | From | How |
        |---|---|
        | The Applications tab | Double-click or ▶. |
        | Spotlight or Finder | Once you've [added it to Applications](help:add-to-applications). |
        | The Dock | Once you've [pinned it](help:pin-to-dock). |

        When an app has been added to Applications, opening it from the grid goes through that same Mac app — so if it
        works from one place, it works from all of them.

        > [!TIP] The MSL window doesn't need to stay open
        > Linux apps are run by MSL's background service, not by this window. Close MSL and the apps carry on.

        ## If it doesn't open {#fails}

        An orange banner says "Couldn't start *app*" with the reason. The usual causes, and what to do, are in
        [Linux apps won't appear or open](help:trouble-apps).
        """#)

    static let addToApplications = HelpArticle(
        id: "add-to-applications", title: "Adding apps to your Applications folder", symbol: "folder.badge.plus",
        summary: "Turn a Linux app into a real Mac app that Spotlight, Finder and Launchpad can find.",
        keywords: ["add to applications", "spotlight", "launchpad", "finder", "app bundle", ".app", "install app", "~/Applications/MSL", "generated apps"],
        related: ["pin-to-dock", "generated-apps", "opening-apps"],
        body: #"""
        **Add to Applications** — the folder button on a tile, or the right-click menu — writes a small, real Mac app
        for the Linux program into `~/Applications/MSL/<instance>/`.

        A banner confirms it: "*App* added to your Applications — It's in ~/Applications/MSL/*instance* and searchable
        from Spotlight." The tile gets a blue tick.

        From then on it behaves like any other Mac app: find it with Spotlight, open it from Finder, drag it wherever you
        like. Opening it starts the instance if needed, then the app — with the MSL window closed or open.

        ## A sharper icon {#icon}

        The grid uses modest icons so it fills quickly. When you add an app, MSL fetches the best icon the app has from
        inside Linux, so the Mac app looks right at every size. That can mean starting the instance for a moment.

        > [!NOTE] When every slot is full
        > If starting the instance would go over the [four-instance limit](help:concurrency), MSL still adds the app,
        > using the icon it already has, and says "Using *app*'s existing icon". Add it again later for the sharp one.

        ## Removing it {#remove}

        **Remove from Applications** deletes that Mac app, and unpins it from the Dock if it was pinned. Deleting the
        app in Finder does the same thing. Nothing inside Linux changes — the Linux program stays installed.

        > [!TIP] Tidy up after an instance
        > Removing an instance deletes every Mac app made for it, so nothing is left pointing at a machine that no
        > longer exists. See [Removing an instance](help:removing-instances).
        """#)

    static let pinToDock = HelpArticle(
        id: "pin-to-dock", title: "Pinning to the Dock", symbol: "pin",
        summary: "Keep a Linux app in your Dock, like any Mac app.",
        keywords: ["dock", "pin", "unpin", "keep in dock", "dock tile", "favourite", "favorite"],
        related: ["add-to-applications", "linux-windows"],
        body: #"""
        **Pin to Dock** — the pin button on a tile, or the right-click menu — puts the app in your Dock. **Unpin from
        Dock** takes it out.

        Pinning needs a real Mac app to point at, so if the app isn't in your Applications folder yet, MSL
        [adds it](help:add-to-applications) first. Pinning implying "add" is less surprising than refusing.

        > [!NOTE] The Dock restarts once
        > macOS has no way for an app to add a Dock tile directly, so MSL updates the Dock's settings and restarts it —
        > once per pin or unpin. You'll see the Dock blink away and come back. That's expected.

        Unpinning never starts an instance. Pinned apps work with the MSL window closed.
        """#)

    static let appSources = HelpArticle(
        id: "app-sources", title: "Where apps come from", symbol: "shippingbox",
        summary: "System, User, Flatpak and Snap — and how to tell two copies of one app apart.",
        keywords: ["flatpak", "snap", "system apps", "user apps", "source", "packaging", "duplicate apps", "badge", "filter"],
        related: ["apps-tab", "first-app"],
        body: #"""
        Linux apps can be installed several ways, and MSL finds all of them:

        | Source | Installed by | Badge |
        |---|---|---|
        | **System** | the distro's package manager (`apt`, `apk`, `pacman`, `dnf`) | none — most apps are these |
        | **User** | you, for your Linux user only (`~/.local/share/applications`) | User |
        | **Flatpak** | `flatpak install` | Flatpak |
        | **Snap** | `snap install` | Snap |

        Only non-system apps get a badge; on most instances every app is a system one, and a badge on all of them
        would be noise.

        ## The same app twice {#duplicates}

        Install GIMP from the package manager *and* from Flatpak and you'll see two GIMP tiles — one plain, one badged
        **Flatpak**. They're genuinely different installs, and each can be added to Applications or pinned separately.

        When there's more than one source, a picker appears in the toolbar — **All · System · User · Flatpak · Snap** —
        to show just one. Typing `flatpak` or `snap` in the search field does the same.
        """#)

    static let linuxWindows = HelpArticle(
        id: "linux-windows", title: "Living with Linux windows", symbol: "macwindow.on.rectangle",
        summary: "How Linux app windows behave on a Mac — Dock, menu bar, closing, copy and paste.",
        keywords: ["linux window", "x11", "mslgd", "dock tile", "menu bar", "mission control", "close window", "copy paste", "clipboard", "scroll", "middle click", "experimental"],
        related: ["how-it-works", "trouble-apps", "sandbox-gates", "power-events"],
        body: #"""
        Linux app windows are drawn by [mslgd](help:how-it-works#mslgd), MSL's own display server, as real Mac windows.
        This is the most experimental part of MSL — here's what to expect.

        ## Each app is its own Mac app {#own-app}

        - **Its own Dock tile**, with its own icon.
        - **Its own name** in the menu bar when it's in front.
        - **Its own place** in Mission Control and ⌘-Tab.

        That works because each Linux app runs in its own small helper process on your Mac: macOS gives exactly one
        Dock tile per process.

        ## Input {#input}

        Keyboard, clicking, dragging, the scroll wheel and trackpad scrolling, and middle-click all reach the app.

        ## Closing {#closing}

        Clicking a window's close button asks the app to close that window, the same as its own close button would on
        Linux — so an app with unsaved work gets its chance to ask "Save changes?".

        ## Copy and paste {#clipboard}

        > [!IMPORTANT] Not across apps yet
        > Copy and paste works *within* one Linux app. Between two different Linux apps, or between a Linux app and a
        > Mac app, it doesn't yet — that bridge isn't built. To move text across for now, save it to a file in your
        > home folder (Linux sees it at [/mnt/mac](help:home-share)).

        ## While apps are open {#awake}

        An instance with a Linux app open stays awake — it isn't [suspended for being idle](help:idle) while an app is
        running.

        ## When the Mac shuts down {#shutdown}

        > [!WARNING] Save Linux work before shutting down
        > When your Mac shuts down, restarts or logs out, MSL asks open Linux apps to close first, so apps with unsaved
        > work can ask to save. Then it saves the instance. But the windows themselves don't come back afterwards —
        > even though the instance resumes, the connection each window had to your Mac is gone. See
        > [Sleep, shutdown and battery](help:power-events).

        ## Things that affect windows {#sandbox}

        - The **Graphics** gate on the [Sandbox tab](help:sandbox-gates) stops *new* windows opening; open ones keep
          drawing.
        - The **Keyboard & mouse** gate stops input reaching them; they keep drawing.

        > [!ASIDE] If an app draws strangely
        > Some apps use corners of X11 that mslgd doesn't draw perfectly yet. That's mslgd's fault, not yours, and not
        > the app's. Trying the same app from another source (a Flatpak instead of the package, say) occasionally
        > helps. ( ˘•ω•˘ )
        """#)
}
