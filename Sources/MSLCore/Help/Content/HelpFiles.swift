import Foundation

// Chapter 9. MSL Files: a Finder work-alike that can see both sides.

extension HelpChapter {
    static let files = HelpChapter(
        id: "files", title: "MSL Files", symbol: "folder", tint: .mango,
        blurb: "Browse your Mac and your Linux instances side by side, and move files between them.",
        articles: [.filesWindow, .filesSidebar, .filesViews, .filesMoving, .filesGit, .filesTags, .filesDeleting, .filesOpenInMSL])
}

extension HelpArticle {
    static let filesGit = HelpArticle(
        id: "files-git", title: "Git in MSL Files", symbol: "point.3.filled.connected.trianglepath.dotted",
        summary: "See a folder's branch, changes and history without leaving the file browser.",
        keywords: ["git", "repository", "repo", "branch", "commit", "history", "origin",
                   "untracked", "staged", "git init", "version control"],
        related: ["files-moving", "files-window", "instances-forward"],
        body: #"""
        ## The dot {#dot}

        A folder that is a git repository carries a dot in the listing:

        | | |
        |---|---|
        | A green ring | Nothing has changed |
        | A filled red dot | Something has — hover it for the branch and a count |
        | No dot | Not a repository, or MSL could not read it |

        That last row matters. **No dot never means "clean"** — a repository MSL could not read in time produces no
        dot at all, rather than a green one on the strength of an answer nobody got.

        The dots are read when you open a folder, when you come back to the MSL Files window, and when you close the
        Git panel. They are deliberately not on a timer: inside an instance every check is a command sent to Linux,
        and asking on a loop would stop an idle instance ever going to sleep. So if you change something in a
        terminal, click back into MSL Files and the dot catches up.

        ## The panel {#panel}

        Right-click a folder and choose **Git…**, or press ⌃⌘G. MSL Files shows what git knows about it:
        the branch, the origin with a button to copy it, how far ahead or behind the upstream, the working
        tree split into conflicted, staged, changed and untracked, and the last fifty commits.

        It works on Mac folders and on folders inside an instance, and it looks the same either way.

        ## Where git actually runs {#where}

        For a folder inside an instance, **git runs inside that instance**, not on your Mac. This matters
        more than it sounds:

        | | Why |
        |---|---|
        | The share MSL mounts does not carry real Linux permissions | Mac-side git would report every file as changed |
        | A status check stats every file | Doing that over the share is slow enough to be unusable |
        | The repository's own config, hooks and ignore rules live in Linux | They are what should apply |

        So the instance has to be running. A stopped one says so rather than guessing, because MSL will
        not start an instance just to decorate a folder.

        ## It reads, and does not write {#readonly}

        There is no commit, push, pull or fetch, and that is the design rather than a gap. Anything that
        talks to a remote may need a password, and MSL has nowhere to ask for one — so it would hang
        rather than prompt. Anything that rewrites history deserves a terminal, where you can see what
        happened and undo it.

        The one thing it will create is a repository where there is none: a folder that is not one offers
        **Initialise a repository here**, which is `git init` and nothing else.

        ## The remote {#remote}

        The panel shows `origin` if there is one, with buttons to copy it and — for addresses that certainly have a
        web page — open it in your Mac browser. **Change** edits it; a repository with no remote offers **Add one**
        instead. Clearing the box removes the remote.

        This only writes the address into the repository's own config. It does not contact anything, and there is
        still no push or pull here for the reason above.

        > [!note]
        > A repository created this way belongs to you, not to root — even though MSL's background
        > service runs as root. A `.git` owned by root inside your home folder would make your very next
        > commit fail, which would be a strange thing for a button offering to set git up.

        ## If the panel says git is not installed {#nogit}

        That is the instance talking, not your Mac. Install it the way that distro does — `apk add git`,
        `apt install git`, `dnf install git` — and open the panel again.

        On the Mac side, git comes with Xcode's Command Line Tools. MSL checks for them first rather than
        running `/usr/bin/git`, because without them that command does not fail: it opens a system dialog
        offering to install them, and a dialog appearing because you opened a folder is not what anyone
        wants from a file browser.

        > [!note]
        > MSL runs git as the owner of the folder, never as the administrator — even though the background service
        > that carries the request is one. A repository's own configuration can name programs git will run, and the
        > dots are read simply because you opened a folder. Running those as the administrator would mean a
        > repository you merely browsed past deciding what your computer does.
        """#)

    static let filesWindow = HelpArticle(
        id: "files-window", title: "The MSL Files window", symbol: "folder",
        summary: "A Finder work-alike that shows your Mac and your running Linux instances side by side.",
        keywords: ["files", "file browser", "finder", "browse", "explorer", "⌥⌘F", "guest files", "linux files"],
        related: ["files-sidebar", "files-moving", "home-share"],
        body: #"""
        **MSL Files** is a file browser that can see both sides of MSL: your Mac's folders and the filesystem inside
        every running instance, in one window. Open it with **Window ▸ MSL Files**, or **⌥⌘F**.

        It deliberately *is* a Finder look-alike — the same four views, the same sidebar, the same shortcuts — so there's
        nothing new to learn. What it adds is the part Finder can't do.

        > [!NOTE] Why not just Finder?
        > Finder *can* reach a running instance — its files are served to your Mac as a real network volume — but it
        > appears under a loopback IP address with no hint of which instance it is. MSL Files shows each instance by
        > name, next to your own folders, and lets you drag between them.

        ## The window {#layout}

        - **The sidebar** — Recents, your folders, **Linux** (one entry per running instance), and your Finder tags.
          See [The Files sidebar](help:files-sidebar).
        - **The toolbar** — back, forward, enclosing folder, open; the four view buttons; sort; new folder, Quick Look,
          share, tags, trash; and a search field.
        - **The path bar** under the toolbar — every folder above this one, each clickable.
        - **The status bar** at the bottom — how many items (or "3 of 12 selected"), whether the place is read-only,
          and how much space is available.

        With no instance running and nothing selected, it says "Nothing to browse — Start an instance to see its Linux
        filesystem here."

        ## Searching {#search}

        The search field in the toolbar (⌘F) filters what's in the current folder by name, as you type. For searching
        everything, use **Recents** or a **tag** in the sidebar, which are Spotlight searches over your home folder.

        ## Finder's shortcuts {#shortcuts}

        Every Finder shortcut you know works here. They're all listed in
        [Keyboard shortcuts](help:shortcuts#files).
        """#)

    static let filesSidebar = HelpArticle(
        id: "files-sidebar", title: "The Files sidebar", symbol: "sidebar.left",
        summary: "Recents, your folders, your Linux instances by name, and your tags.",
        keywords: ["sidebar", "favorites", "favourites", "locations", "recents", "linux section", "read only", "lock"],
        related: ["files-window", "files-tags"],
        body: #"""
        From top to bottom:

        | Section | Contains |
        |---|---|
        | *(no heading)* | **Recents** — files you've used lately, from Spotlight. |
        | **Favorites** | Your home folder, Desktop, Documents, Downloads and Applications — whichever exist. |
        | **Locations** | **Macintosh HD**, your Mac's whole disk. |
        | **Linux** | Each **running** instance, by name, with an orange icon. "No running instances" when there are none. |
        | **Tags** | Your Finder tags, each with its colour dot. Clicking one lists everything with that tag. |

        A small **lock** beside a place means it's read-only for you; the status bar says "Read-only" too, and anything
        that would change it is greyed out.

        > [!TIP] Tagging by dropping
        > Drop files onto a tag in the sidebar to apply that tag, just like Finder.

        ## Instances come and go {#instances}

        The Linux section follows your instances: start one and it appears; stop or suspend it and it leaves. MSL
        Files never starts an instance by itself. The **Go** menu lists them too, under Finder's usual destinations.
        """#)

    static let filesViews = HelpArticle(
        id: "files-views", title: "Views, sorting and getting around", symbol: "square.grid.2x2",
        summary: "Icons, list, columns and gallery; sorting and grouping; back, forward and Go to Folder.",
        keywords: ["icon view", "list view", "column view", "gallery view", "sort", "group", "hidden files", "path bar", "status bar", "go to folder", "navigate", "back", "forward"],
        related: ["shortcuts", "files-window"],
        body: #"""
        ## The four views {#views}

        | View | Shortcut |
        |---|---|
        | as Icons | ⌘1 |
        | as List | ⌘2 |
        | as Columns | ⌘3 |
        | as Gallery | ⌘4 |

        Or use the view buttons in the toolbar, or the **View** menu.

        ## Sorting and grouping {#sorting}

        The arrows button in the toolbar (or **View ▸ Sort By** and **Group By**):

        - **Group by** — None, Name, Kind, Date Modified, Size, or Tags.
        - **Sort by** — Name, Size, Kind, Date Modified, or Date Added.
        - **Ascending**, and **Keep Folders on Top**.
        - **Show Hidden Files** — also ⇧⌘., Finder's own shortcut for it.

        ## Showing and hiding {#show}

        | | Shortcut |
        |---|---|
        | Hide or show the sidebar | ⌃⌘S |
        | Show Path Bar | ⌥⌘P |
        | Show Status Bar | ⌘/ |
        | Show Hidden Files | ⇧⌘. |

        ## Getting around {#navigating}

        | | Shortcut |
        |---|---|
        | Back | ⌘[ |
        | Forward | ⌘] |
        | Enclosing folder | ⌘↑ |
        | Open the selection | ⌘↓, or double-click |
        | Go to Folder… | ⇧⌘G — type a path like `/` or `~/` |
        | Recents | ⇧⌘F |
        | Documents · Desktop · Home | ⇧⌘O · ⇧⌘D · ⇧⌘H |
        | Downloads | ⌥⌘L |
        | Computer · Applications · Utilities | ⇧⌘C · ⇧⌘A · ⇧⌘U |
        | iCloud Drive | ⇧⌘I, if you use it |

        Click any folder in the path bar to jump straight to it. The **Go** menu also lists every running instance.

        > [!NOTE] Return renames, like Finder
        > Return starts renaming the selected item; it doesn't open it. ⌘↓ or a double-click opens.
        """#)

    static let filesMoving = HelpArticle(
        id: "files-moving", title: "Moving files between Mac and Linux", symbol: "arrow.left.arrow.right",
        summary: "Drag, copy and paste, duplicate, new folders, rename, compress, share.",
        keywords: ["copy", "paste", "drag and drop", "transfer", "move files", "upload", "duplicate", "new folder", "rename", "compress", "zip", "share"],
        related: ["home-share", "files-deleting", "files-git"],
        body: #"""
        ## Drag and drop {#drag}

        Drag files from Finder, or from anywhere in MSL Files, into a folder — on your Mac or inside an instance.

        | Dragging | What happens |
        |---|---|
        | Within your Mac, or within one instance | **Moved**, as in Finder |
        | Between your Mac and an instance, or between two instances | **Copied** — the original stays |
        | Holding ⌥ | **Copied**, always |

        The rule is the same one Finder uses, and it is not arbitrary: a move is only possible within a single
        filesystem, and an instance's files are a separate one from your Mac's.

        Drop them **anywhere in the window**: onto a folder to put them inside it, into the empty space to put them
        in the folder you're looking at, or onto a place in the sidebar — Downloads, Desktop, an instance — to send
        them there without navigating first. Dropping onto a tag applies the tag instead.

        Dropping onto a name that is already taken is refused rather than overwritten, and so is dropping a folder
        into itself. Places that are read-only won't accept a drop.

        > [!tip]
        > A script dragged into an instance stays executable. The share MSL mounts cannot carry Linux permissions,
        > so MSL puts the executable bit back afterwards — without it, a program you dropped in would land
        > unrunnable and Linux would tell you permission was denied on your own file.

        ## Copy and paste {#copy-paste}

        Select files and press **⌘C**, go somewhere else, and press **⌘V** — within MSL Files, across the Mac–Linux
        boundary either way. The Edit menu's **Select All Items** (⌥⌘A) selects everything in the folder.

        ## Making and changing things {#editing}

        | Action | How |
        |---|---|
        | New folder | ⇧⌘N, or the toolbar's folder button |
        | New folder containing the selection | ⌃⌘N |
        | Rename | Return, or right-click ▸ Rename… |
        | Duplicate | ⌘D |
        | Compress into a zip | File ▸ Compress |
        | Share | the toolbar's share button, or File ▸ Share… |
        | Copy the path | ⌥⌘C (File ▸ Copy as Pathname) |

        ## Looking closer {#looking}

        - **Quick Look** — Space, or ⌘Y. A preview opens; **Done** closes it.
        - **Get Info** — ⌘I. The item's thumbnail and name; **General** (Kind, Size, Where, Created, Modified); and
          **Tags**, as colour swatches to click.
        - **Reveal in Finder** — ⌘R shows it in a real Finder window.

        > [!TIP] The other way round
        > Linux can already reach your Mac home folder at `/mnt/mac`, so for files under your home folder there's often
        > nothing to copy at all. See [Your home folder inside Linux](help:home-share).
        """#)

    static let filesTags = HelpArticle(
        id: "files-tags", title: "Tags", symbol: "tag",
        summary: "Finder tags that work in both directions, on your Mac's files.",
        keywords: ["tags", "tag", "colour", "color", "label", "finder tags", "red", "orange", "yellow", "green", "blue", "purple", "gray"],
        related: ["files-sidebar", "files-moving"],
        body: #"""
        MSL Files uses Finder's real tags — tag something here and Finder sees it, and the other way round.

        ## Adding and removing {#adding}

        - The **tag** button in the toolbar, **File ▸ Tags**, or **right-click ▸ Tags**: choose a tag to add it; choose
          one with a tick to remove it. **Clear Tags** removes them all.
        - **Get Info** (⌘I) shows the standard colours as swatches — click one to toggle it.
        - Drop files onto a tag in the sidebar.

        ## Finding tagged things {#finding}

        Each tag in the sidebar lists everything carrying it, using Spotlight across your home folder. **Group by ▸
        Tags** groups a folder's contents by tag.
        """#)

    static let filesDeleting = HelpArticle(
        id: "files-deleting", title: "Deleting files", symbol: "trash",
        summary: "The Trash on your Mac, and permanent deletion inside Linux.",
        keywords: ["delete", "trash", "remove file", "permanently", "undo delete", "⌘⌫", "no trash"],
        related: ["files-moving", "snapshots"],
        body: #"""
        **Move to Trash** — ⌘⌫, the toolbar's trash button, or right-click — works as you'd expect on your Mac's files:
        they go to the Trash, and you can get them back.

        > [!DANGER] Inside Linux there's no Trash
        > An instance's filesystem has no Trash. Deleting there asks first — "This volume has no Trash." with **Delete
        > *n* Items Permanently** — and "Deleting here cannot be undone" means exactly that.

        > [!TIP] A safety net for big clean-ups
        > Before deleting a lot inside Linux, consider a [snapshot](help:snapshots) — or copy what matters to your Mac
        > first.
        """#)

    static let filesOpenInMSL = HelpArticle(
        id: "files-open-in-msl", title: "Opening a folder in a Linux shell", symbol: "terminal.fill",
        summary: "Right-click a folder to open a Linux shell already sitting in it.",
        keywords: ["open folder in msl", "open in terminal", "shell here", "cd", "terminal here", "right click"],
        related: ["home-share", "terminal-app"],
        body: #"""
        Right-click a folder in MSL Files for two ways into a terminal:

        - **Open Folder in MSL** — a *Linux* shell in Terminal.app, already in that folder.
        - **Open in Terminal** — a normal *Mac* shell in Terminal.app, in that folder.

        ## Which instance? {#which}

        | The folder is… | Open Folder in MSL… |
        |---|---|
        | Inside an instance | opens there: "Open Folder in MSL (*work*)". |
        | Under your Mac home folder, one instance running | opens in that one, through `/mnt/mac`. |
        | Under your home folder, several running | offers a submenu to choose. |
        | Under your home folder, none running | is greyed out — `/mnt/mac` only exists inside a running instance. |
        | Outside your home folder (`/Applications`, another drive) | is greyed out — Linux can't see it. |

        So a project in `~/Code/thing` opens as `/mnt/mac/Code/thing` inside Linux: same files, Linux tools.
        """#)
}
