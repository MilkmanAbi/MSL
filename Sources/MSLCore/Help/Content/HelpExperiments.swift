import Foundation

// Chapter. The Experimental Features window, flag by flag.

extension HelpChapter {
    static let experiments = HelpChapter(
        id: "experiments", title: "Experimental Features", symbol: "flask", tint: .purple,
        blurb: "The switches that make Linux apps behave like Mac apps — what each one does, and what it can still get wrong.",
        articles: [.experiments, .macKeyboard, .sharedClipboard, .mslFilesIntegration,
                   .globalMenuBar, .signInPages, .gpuAcceleration, .nativeScaling, .retinaRendering, .cameraAndMic])
}

extension HelpArticle {
    static let experiments = HelpArticle(
        id: "experiments", title: "What experimental means here", symbol: "flask",
        summary: "Why these are switches rather than simply how MSL works, and what to do when one misbehaves.",
        keywords: ["experimental", "flags", "features", "experiments", "beta", "toggle", "switch", "unstable"],
        related: ["mac-keyboard", "shared-clipboard", "msl-files-integration", "global-menu-bar"],
        body: #"""
        **Experimental Features** is in the sidebar, under the instance list. It is the only place any of these
        change, and it says how many are on.

        ## They are on, and they still might bite {#stability}

        Most of these start **on**, because MSL is much less pleasant without them: a Mac keyboard that does
        nothing in Linux apps, a clipboard that stops at the window edge, menus drawn inside the window instead of
        in the menu bar.

        They are still called experimental, and that word is doing real work:

        > [!IMPORTANT] What "experimental" is warning you about
        > Each of these reaches *into* software MSL did not write — a toolkit's idea of where its file dialog comes
        > from, an app's idea of what Ctrl+C means, a desktop's idea of who owns the menus. MSL can be completely
        > correct and an app can still do something odd, because the app has its own opinion.
        >
        > So they can have **occasional stability issues**: an app whose menus do not appear, a dialog that opens
        > in the wrong place, a shortcut that lands somewhere unexpected. None of it damages anything, and every
        > one of them is a switch.

        **If something behaves strangely, turn the matching switch off.** Everything goes back to how that app
        behaves on an ordinary Linux desktop. That is the whole point of them being switches, and it is a better
        first move than working around the symptom.

        ## When a change takes effect {#applies}

        Each switch carries a small badge saying when it applies:

        | Badge | Means |
        |---|---|
        | **Live** | Straight away, including for apps already open. |
        | **New apps** | Apps launched after the change. Ones already running keep the old behaviour. |
        | **Restart** | The instance has to be restarted. |

        A switch that says **New apps** has not failed if nothing changes in the window you are looking at — close
        the app and open it again.

        ## Grouped by what they change {#groups}

        | Group | What it covers |
        |---|---|
        | **Graphics and input (mslgd)** | How Linux windows look and how they take the keyboard and mouse. |
        | **Peripherals (mslps)** | The Mac's camera and microphone, for Linux apps. |
        | **MSL** | Where Linux and the Mac meet: links, files, the clipboard, the menu bar. |

        **Reset all** at the top puts every switch back to what MSL ships.

        > [!NOTE] Settings you have chosen are kept
        > When a later version of MSL turns something on by default, it changes only that switch. Anything you
        > have set for yourself stays as you left it.
        """#)

    static let macKeyboard = HelpArticle(
        id: "mac-keyboard", title: "The Mac keyboard in Linux apps", symbol: "keyboard",
        summary: "Command-key shortcuts, Mac text navigation, and why terminals are treated differently.",
        keywords: ["keyboard", "cmd", "command", "ctrl", "shortcut", "copy", "paste", "undo", "text navigation",
                   "option", "alt", "altgr", "screenshot", "terminal", "keymap"],
        related: ["experiments", "shared-clipboard", "shortcuts", "trouble-apps"],
        body: #"""
        Three switches, all on by default, that let a Mac keyboard drive a Linux app.

        ## Mac shortcuts in Linux apps {#shortcuts}

        Command-key shortcuts arrive as the Control-key ones Linux apps expect.

        | You press | The Linux app sees |
        |---|---|
        | **⌘C**, **⌘V**, **⌘X** | Ctrl+C, Ctrl+V, Ctrl+X |
        | **⌘Z**, **⇧⌘Z** | Ctrl+Z, Ctrl+Shift+Z |
        | **⌘S**, **⌘O**, **⌘N**, **⌘W** | Ctrl+S, Ctrl+O, Ctrl+N, Ctrl+W |
        | **⌘F**, **⌘A**, **⌘P** | Ctrl+F, Ctrl+A, Ctrl+P |

        Anything else with Command follows the same rule, keeping Shift and Option.

        ## macOS keeps its own {#reserved}

        Some shortcuts never reach Linux, because they are the Mac's:

        | Kept by macOS | What it still does |
        |---|---|
        | **⌘Q** | Quits the app, with its usual "save your work?" prompt |
        | **⌘H**, **⌥⌘H** | Hide, Hide Others |
        | **⌘M**, **⌥⌘M** | Minimise, Minimise All |
        | **⌘`** | Cycle that app's windows |
        | **anything with ⌃⌘** | Full screen, lock screen, the character picker |
        | **⌘Space**, **⌘Tab** | Spotlight and app switching, which macOS takes first |

        Plain **Control** is never touched — it is Linux's own modifier, and Ctrl+C in a Linux app means what it
        has always meant.

        ## Terminals are different, on purpose {#terminals}

        In a terminal, Ctrl+C is not copy. It interrupts whatever is running. A straight Command-to-Control
        mapping would mean pressing ⌘C to copy killed your build, ⌘D closed the shell and ⌘Z suspended it.

        So MSL recognises terminal emulators and treats them separately:

        | Terminal | What ⌘C does |
        |---|---|
        | GNOME Terminal, Konsole, kitty, alacritty, foot, Tilix, Terminator and similar | Arrives as **Ctrl+Shift+C**, which is what those terminals bind copy to |
        | **xterm**, **urxvt**, **st** | **Nothing at all** |

        > [!IMPORTANT] Why xterm gets nothing
        > Ctrl+Shift+C is a convention the newer terminals adopted; the classic X terminals never did. In those,
        > Shift does not change the character sent, so Ctrl+Shift+C would arrive as a plain Ctrl+C and interrupt
        > the running command anyway. Doing nothing is the safe answer.
        >
        > Those terminals have never copied with a key combination: select text with the mouse to copy it, and
        > paste with the middle button.

        In the terminals that do bind them, **⌘⌫** clears to the start of the line and **⌥⌫** deletes the word
        before the cursor, which is what a shell prompt understands.

        ## Mac text navigation {#text}

        The Mac's text moves, translated for Linux text fields:

        | You press | The Linux app sees |
        |---|---|
        | **⌘←** / **⌘→** | Home / End |
        | **⌘↑** / **⌘↓** | Ctrl+Home / Ctrl+End (start and end of the document) |
        | **⌥←** / **⌥→** | Ctrl+← / Ctrl+→ (a word at a time) |
        | **⌘⌫** | Delete to the start of the line |
        | **⌥⌫** | Delete the word before the cursor |

        Holding Shift extends the selection, as it does everywhere else.

        ## The Option keys {#option}

        A Mac's Option key does two jobs a PC keyboard splits between two keys: it is Alt for shortcuts, and it
        types characters like a-acute and the trademark sign. The **Option keys** choice decides which job each
        one does in Linux apps:

        | Choice | Left Option | Right Option |
        |---|---|---|
        | **Like a PC** (default) | Alt | Types special characters (AltGr) |
        | **Both are Alt** | Alt | Alt |
        | **Like a Mac app** | Special characters | Special characters |

        ## Screenshot keys {#screenshots}

        With this on, **⇧⌘3**, **⇧⌘4** and **⇧⌘5** are sent through to Linux as Print, Shift+Print and Alt+Print
        — the keys Linux screenshot tools listen for.

        > [!NOTE] macOS takes these first
        > It is on by default and usually does nothing, because macOS claims those combinations for its own
        > screenshots before any app sees them. It only takes effect once you have turned the macOS ones off in
        > System Settings, under Keyboard, Keyboard Shortcuts, Screenshots.
        """#)

    static let sharedClipboard = HelpArticle(
        id: "shared-clipboard", title: "The shared clipboard", symbol: "doc.on.clipboard",
        summary: "Copy in Linux and paste on the Mac, and back again — text, images and files.",
        keywords: ["clipboard", "copy", "paste", "pasteboard", "image", "screenshot", "files", "cut", "primary"],
        related: ["experiments", "mac-keyboard", "msl-files-integration", "home-share"],
        body: #"""
        Copy something in a Linux app and it is on your Mac's clipboard immediately. Copy on the Mac and Linux
        apps can paste it. On by default.

        It is also what lets two Linux apps share a clipboard at all: every Linux app gets its own process, and
        X11 clipboards are passed directly between programs rather than stored anywhere, so without a bridge the
        two could not see each other.

        ## What crosses {#what}

        | Copied | Linux to Mac | Mac to Linux |
        |---|---|---|
        | **Text** | Yes | Yes |
        | **Images** | Yes, as PNG | Yes, as PNG |
        | **Files** | Use MSL Files | Yes, from your Mac home folder |

        A copy that is both text and a picture keeps both, so whichever an app asks for is the one it gets.

        ## Files, from the Mac {#files}

        Copy a file in Finder and a Linux app can paste it. The path a Linux app receives points into
        `/mnt/mac`, which is where your Mac home folder appears inside every instance.

        > [!IMPORTANT] Only files under your Mac home folder
        > A file on an external disk, or in another user's home folder, has no Linux equivalent — Linux genuinely
        > cannot reach it. Those are left out rather than handed over as a path that does not exist.

        It is always a **copy**, never a move, whatever you pressed. Nothing crossing this boundary will delete
        the original on the other side.

        Going the other way — Linux files onto the Mac's clipboard — is [MSL Files](help:files-window)' job. It is the
        file browser for both sides and can put real files on the clipboard itself.

        ## What it does not cover {#limits}

        > [!NOTE] Selecting text is not copying
        > X11 has a second clipboard: text you have merely *selected* with the mouse, pasted with the middle
        > button. MSL deliberately does not bridge it, because it changes every time you drag across any text —
        > mirroring that onto the Mac would overwrite whatever you had copied, constantly.
        >
        > Programs that only use it, like `xterm` and some very old ones, will not reach the Mac's clipboard.
        > Copy from their own menu where they have one.

        Items marked private by password managers are skipped on purpose, so they are never carried into an
        instance.
        """#)

    static let mslFilesIntegration = HelpArticle(
        id: "msl-files-integration", title: "MSL Files as the Linux file browser", symbol: "folder.badge.gearshape",
        summary: "What turning Linux's file manager and file dialogs into MSL Files actually changes.",
        keywords: ["files", "file manager", "dialog", "open", "save", "picker", "chooser", "nautilus", "dolphin",
                   "portal", "default", "browser"],
        related: ["experiments", "files-window", "files-open-in-msl", "shared-clipboard"],
        body: #"""
        With **Set MSL Files as the default file browser for Linux** on — which it is by default — Linux apps use
        MSL Files instead of a Linux file manager.

        ## What changes {#what}

        | In a Linux app | You get |
        |---|---|
        | Opening a folder, or "show in folder" | MSL Files, at that folder |
        | An app's **Open** or **Save As** dialog | MSL Files, as the dialog |
        | Starting the file manager from the Linux applications menu | MSL Files, at that instance's home folder |

        The dialog is the same browser as the rest of [MSL Files](help:files-window) — the same sidebar, view modes,
        sorting and search — with Cancel and Open along the bottom. It can see your Mac's disk as well as the
        instance's, which a Linux file chooser cannot.

        ## Why it is experimental {#why}

        > [!IMPORTANT] It reaches into each toolkit
        > There is no single way to ask "every Linux app" where its file dialog comes from. MSL uses four
        > different mechanisms for GTK, Qt, Firefox and sandboxed apps, and an app that does something unusual
        > can end up with its own dialog anyway — or, rarely, with one that behaves oddly.
        >
        > If an app's Open or Save starts acting strangely, turn this off. Everything goes back to that app's own
        > dialog, which always works.

        Some apps will keep their own dialog whatever this is set to, because they draw it themselves in a way
        nothing outside them can redirect. That is not a fault; those apps simply work as they do on Linux.

        ## Turning it off {#off}

        With it off, folders open in whatever Linux file manager is installed (Nautilus, Dolphin, and so on), and
        Open and Save dialogs are the app's own. MSL Files still works as a Mac app — it is only the Linux side
        that stops pointing at it.
        """#)

    static let globalMenuBar = HelpArticle(
        id: "global-menu-bar", title: "Linux menus in the Mac menu bar", symbol: "menubar.rectangle",
        summary: "Moving an app's File and Edit menus to the top of the screen, and which apps can do it.",
        keywords: ["menu", "menubar", "global menu", "file menu", "edit menu", "dbus", "appmenu", "gtk", "qt"],
        related: ["experiments", "linux-windows", "opening-apps", "trouble-apps"],
        body: #"""
        A Linux app's menus — File, Edit, View — appear in the Mac's menu bar at the top of the screen, the way a
        Mac app's do, instead of being drawn inside the window. On by default.

        This is what makes a Linux window feel like a window rather than a window with a menu bar inside it.

        ## When there are more menus than fit {#fitting}

        A long menu bar runs into a MacBook's notch. MSL keeps what fits and tucks the rest behind one final
        menu, so nothing is lost on a smaller screen.

        ## Not every app can do it {#support}

        > [!IMPORTANT] The app has to publish its menus
        > MSL reads menus over D-Bus, which means the app has to export them. Most GTK and Qt applications do.
        > Some do not, and a few publish only part of what they show.
        >
        > When an app does not, its menus stay inside its window and everything still works — you have just not
        > gained anything for that app.

        If an app's menus are missing from the menu bar **and** from its window, that is worth turning the switch
        off for: some apps hide their in-window menu bar as soon as anything claims to be handling menus for
        them, and then publish nothing.

        Applies to **apps launched after** the change, so close an app and reopen it to see the difference.
        """#)

    static let gpuAcceleration = HelpArticle(
        id: "gpu-acceleration", title: "GPU acceleration for OpenGL", symbol: "cpu",
        summary: "Running Linux OpenGL on the Mac's real GPU, and the version ceiling that decides whether you want to.",
        keywords: ["opengl", "gl", "gpu", "metal", "virgl", "3d", "graphics", "acceleration", "blender", "games"],
        related: ["experiments", "opengl-apps", "libgl-tricks", "trouble-apps"],
        body: #"""
        Off by default. With it on, Linux OpenGL is rendered on your Mac's real GPU through Metal instead of on
        the CPU.

        ## The ceiling, which is the whole decision {#ceiling}

        > [!WARNING] The GPU path stops at OpenGL 4.1
        > The Mac side goes through Apple's OpenGL, which caps at **4.1**. The CPU path — the default — offers
        > **4.5**. So anything that needs newer than 4.1 will not run on the GPU at all, while it runs fine on
        > the CPU.
        >
        > Blender is the usual example: it wants 4.3 and reports unsupported hardware on the GPU, while working
        > on the CPU.

        | Good on the GPU | Better on the CPU |
        |---|---|
        | Chromium's GL, many games, older CAD | Blender and anything else needing OpenGL 4.2 or newer |
        | Anything that stays at OpenGL 4.1 or below | Anything that renders incorrectly on the GPU |

        ## It needs a piece that is installed separately {#renderer}

        The GPU path needs a renderer on the Mac side. Without it this switch does nothing at all and apps stay
        on the CPU — quietly, which is the right failure: you get working software rather than a broken window.

        ## Per-app, not just global {#per-app}

        This switch is the default for every app, but each app can be set on its own from its right-click menu in
        the Applications tab — see [The app right-click menu](help:app-menu). An app pinned to the CPU stays
        there whatever this switch says, which is how you keep Blender working while everything else uses the
        GPU.

        Takes effect after the instance restarts.
        """#)

    static let retinaRendering = HelpArticle(
        id: "retina-rendering", title: "Retina rendering", symbol: "sparkle.magnifyingglass",
        summary: "Drawing Linux windows at your Mac's real pixel density, so they look as sharp as Mac apps.",
        keywords: ["retina", "hidpi", "sharp", "crisp", "blurry", "fuzzy", "dpi", "192", "density",
                   "pixel", "resolution", "text quality"],
        related: ["native-scaling", "experiments", "linux-windows"],
        body: #"""
        Off by default. Linux windows are normally drawn one X pixel per point — and on a Retina screen a point
        is **four physical pixels**, so every X pixel is stretched across all four. That is why Linux text can
        look softer than the Mac's own. With this on, each X pixel is one physical pixel instead, and Linux
        apps draw at the detail your screen actually has.

        ## What changes {#what}

        | | Off | On |
        |---|---|---|
        | Each X pixel covers | 1 point — 4 physical pixels | 1 physical pixel |
        | MSL tells Linux the screen is | 96 dpi | 192 dpi |
        | Pixels an app draws | — | four times as many |

        Windows stay the **same physical size**. The screen MSL reports grows by exactly as much as each pixel
        shrinks, so an app lays out for the same amount of glass — it simply has four times the pixels to say
        it with.

        ## What it costs {#cost}

        Four times the pixels, and every one of them crosses the connection between Linux and your Mac. Expect
        it to cost speed, most obviously on large windows and on anything drawing in software rather than on
        the GPU. That is the whole reason it is off by default rather than simply on.

        > [!tip]
        > If MSL's apps feel slower with this on, try [GPU acceleration](help:gpu-acceleration) alongside it —
        > the extra pixels are exactly the kind of work a GPU is for.

        ## With Native scaling {#both}

        They answer the same question, so **Retina rendering wins** when both are on.
        [Native scaling](help:native-scaling) makes Linux windows smaller at the detail they already had;
        this keeps them the size they are and gives them more detail.

        ## If some apps change and others do not {#partial}

        Toolkits disagree about where to read the display's density from. MSL publishes it both ways — as the
        screen's physical size, and as the `Xft.dpi` resource that Qt, Tk and xterm read — but an app that
        hardcodes 96 will ignore both and keep its old size. Nothing breaks; it just will not have grown
        sharper with the rest.

        Applies to apps opened after turning it on. One already on screen keeps the density it started with.
        """#)

    static let nativeScaling = HelpArticle(
        id: "native-scaling", title: "Native scaling", symbol: "arrow.up.left.and.arrow.down.right",
        summary: "Drawing Linux windows closer to the Mac's own interface size.",
        keywords: ["scale", "scaling", "hidpi", "retina", "dpi", "size", "resolution", "small", "tiny"],
        related: ["experiments", "linux-windows", "gpu-acceleration"],
        body: #"""
        Off by default. Linux windows are normally drawn one X pixel per point, which is what every app has been
        tested at. With this on they are drawn closer to the Mac's own interface size.

        Worth trying if Linux apps look small next to Mac ones. Some apps lay out well when scaled and some do
        not — toolkits vary in how much they believe the display's reported size — which is why it is off by
        default rather than on.

        Applies to apps launched after the change.
        """#)

    static let cameraAndMic = HelpArticle(
        id: "camera-and-mic", title: "The camera and microphone prompt", symbol: "camera",
        summary: "Skipping MSL's own permission prompt when a Linux app opens the camera or microphone.",
        keywords: ["camera", "microphone", "mic", "webcam", "permission", "prompt", "privacy", "ros2", "cheese"],
        related: ["experiments", "trouble-apps"],
        body: #"""
        Off by default. When a Linux app opens the camera or the microphone, MSL Peripherals asks you first. With
        this on, it does not.

        Right for something that starts camera nodes over and over — robotics work is the usual case — and wrong
        if you would rather be asked. The normal answer to "a Linux app wants your camera" is to be asked.

        > [!NOTE] macOS still asks, and the lights still show
        > This only skips *MSL's* prompt. macOS asks for its own permission once, which nothing can skip, and the
        > camera light and the microphone indicator still appear whenever something is actually capturing.
        """#)

    static let signInPages = HelpArticle(
        id: "sign-in-pages", title: "Signing in to Linux apps", symbol: "person.badge.key",
        summary: "Why a sign-in page opens in Linux when every other link opens on your Mac.",
        keywords: ["sign in", "signin", "login", "oauth", "account", "zoom", "discord", "slack",
                   "browser", "redirect", "callback", "authorise"],
        related: ["experiments", "mac-keyboard", "shared-clipboard", "trouble-network"],
        body: #"""
        Links from Linux apps open on your Mac - that is the point of the
        integration. **Sign-in pages are the one exception**, and they have to be.

        ## Why the Mac cannot finish a sign-in {#why}

        A "sign in with..." flow ends by handing its answer back to *the machine that
        started it*, in one of two ways:

        | How it comes back | What it means |
        |---|---|
        | To `127.0.0.1` on some port | The Linux app is listening there. Your Mac is not. |
        | To a private address like `discord://` | Only Linux knows which app that belongs to. |

        Open that page on your Mac and the answer arrives on your Mac: the browser
        either shows an error, or silently hands it to a *Mac* app of the same name.
        The Linux app never hears anything and waits forever.

        So the sign-in page - and only that page - opens in the instance's own
        browser, where the whole round trip stays on one machine.

        ## What you will see {#what}

        1. You press "Sign in" in a Linux app.
        2. A browser window opens **inside Linux**, not on your Mac.
        3. You sign in there.
        4. The app picks up where it left off.

        The one cost is that this browser is not your Mac's, so it has none of your
        saved passwords. It is usually a one-time step per app.

        ## What still opens on your Mac {#ordinary}

        Everything else. MSL decides by reading the link, and only diverts one that
        carries the marks of an authorisation request - a sign-in address to return
        to, or an app identifier with a response type. An ordinary link, a
        documentation page, a search result, a link in an email: all still open in
        your own browser.

        > [!NOTE] It needs a browser in the instance
        > With no browser installed in Linux there is nothing to open the page in, so
        > the link goes to your Mac as before. That will not complete the sign-in, but
        > a page that opens somewhere beats a page that opens nowhere.

        ## If it gets one wrong {#wrong}

        This is new, and it judges by reading the link. If an ordinary page starts
        opening in the guest's browser, turn off **Sign-in pages open in Linux** in
        [Experimental Features](help:experiments) - every link then goes to your Mac
        again, and sign-ins go back to not completing.
        """#)
}
