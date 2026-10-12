import Foundation

// Chapter. Linux graphics on a Mac: OpenGL, the display server's quirks, and
// the environment variables that rescue a stubborn app.

extension HelpChapter {
    static let graphics = HelpChapter(
        id: "graphics", title: "Graphics & mslgd", symbol: "display", tint: .indigo,
        blurb: "How Linux windows get onto your screen, what OpenGL apps need, and the tricks for the stubborn ones.",
        articles: [.mslgd, .openglApps, .libglTricks, .mslgdQuirks])
}

extension HelpArticle {
    static let mslgd = HelpArticle(
        id: "mslgd", title: "mslgd, the display server", symbol: "display",
        summary: "What draws Linux windows on your Mac, and why each app gets its own process.",
        keywords: ["mslgd", "x11", "display", "server", "window", "graphics", "wayland"],
        related: ["linux-windows", "opengl-apps", "mslgd-quirks", "sandbox-gates"],
        body: #"""
        Linux apps draw through **mslgd**, an X11 display server written for MSL. It is not XQuartz and does not
        need it: a Linux app connects to mslgd, and mslgd puts a real Mac window on your screen.

        ## One process per app {#per-app}

        Every Linux app runs in its own process on the Mac side. That is what gives each one its own Dock tile,
        its own icon, its own name in the menu bar and its own tiles in Mission Control — instead of everything
        appearing as "MSL".

        It has one visible consequence: two Linux apps cannot see each other's clipboard directly, because X11
        clipboards pass between programs rather than being stored anywhere. [The shared
        clipboard](help:shared-clipboard) is what joins them up, through the Mac's.

        ## What it supports {#support}

        Enough of X11 that ordinary desktop applications work: windows, input, fonts, images, shaped windows,
        the extensions toolkits check for on startup, and OpenGL through GLX. GTK, Qt and the toolkits built on
        them are what it is tested against.

        > [!NOTE] X11, not Wayland
        > Apps that only speak Wayland will not find a display. Most Linux desktop software still speaks X11, or
        > speaks both and will use X11 when that is what it finds.

        ## Turning it off for one instance {#gate}

        The Sandbox tab's **Graphics** gate stops an instance opening new windows at all — see [The four
        gates](help:sandbox-gates). Windows already open keep drawing.
        """#)

    static let openglApps = HelpArticle(
        id: "opengl-apps", title: "Running OpenGL apps", symbol: "cube",
        summary: "How 3D apps render here, which path suits which app, and what to do when one refuses to start.",
        keywords: ["opengl", "gl", "3d", "glx", "mesa", "llvmpipe", "blender", "games", "render", "glxgears", "glxinfo"],
        related: ["gpu-acceleration", "libgl-tricks", "app-menu", "trouble-apps"],
        body: #"""
        OpenGL apps work. There are two ways they can render, and which is better depends on the app.

        ## The two paths {#paths}

        | Path | OpenGL version | Good for |
        |---|---|---|
        | **CPU** (the default) | 4.5 | Anything, including apps needing newer OpenGL. Slower for heavy 3D. |
        | **GPU** (opt in) | 4.1 | Apps that stay at 4.1 or below and want the speed. |

        The CPU path is software rendering — correct, complete, and slow in proportion to how much the app
        draws. The GPU path sends OpenGL to your Mac's real graphics hardware, and is capped at OpenGL 4.1 by
        the Mac side of it.

        > [!WARNING] Newer than 4.1 will not run on the GPU
        > This is the single most useful thing to know here. Blender wants OpenGL 4.3: on the GPU it reports
        > unsupported hardware and will not start properly, and on the CPU it runs. If a 3D app refuses to start
        > only when GPU acceleration is on, this is why.

        Turning the GPU path on at all is [GPU acceleration for OpenGL](help:gpu-acceleration) in Experimental
        Features. Individual apps can override it from [their right-click menu](help:app-menu), which is how you
        keep one app on the CPU while everything else uses the GPU.

        ## Checking what an app is getting {#checking}

        From a terminal in the instance:

        ```
        glxinfo | grep -E "OpenGL (vendor|renderer|version)"
        ```

        A renderer naming **llvmpipe** is the CPU path. Anything else is the GPU path. `glxgears` is the quickest
        way to see whether GL works at all.

        If `glxinfo` is missing, install `mesa-utils`.

        ## When an app will not start {#wont-start}

        | It says | Try |
        |---|---|
        | Unsupported hardware, or needs OpenGL 4.2 or newer | Put that app on the **CPU** |
        | Cannot open display | Check the Graphics gate on the Sandbox tab |
        | Nothing, and exits immediately | Launch it from a terminal to see its own message |
        | Lost connection to rendering server | The GPU renderer is not reachable; use the CPU |

        Launching from a terminal in the instance is worth doing early. A Linux app that fails on startup almost
        always says why, and that message never reaches the Mac side.
        """#)

    static let libglTricks = HelpArticle(
        id: "libgl-tricks", title: "Environment tricks for stubborn apps", symbol: "wrench.and.screwdriver",
        summary: "The handful of variables that rescue an app which will not render, scale or start.",
        keywords: ["libgl", "LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER", "mesa", "environment", "variable",
                   "GSK_RENDERER", "QT_QUICK_BACKEND", "love", "sdl", "gdk", "export"],
        related: ["opengl-apps", "gpu-acceleration", "mslgd-quirks", "terminal-tab"],
        body: #"""
        Most apps need none of this. When one misbehaves, these are the levers, and they are the same ones you
        would use on any Linux machine with software rendering.

        Run an app with a variable set from a terminal in the instance:

        ```
        LIBGL_ALWAYS_SOFTWARE=1 some-app
        ```

        Or, from your Mac, through the `msl` command:

        ```
        msl <instance> env LIBGL_ALWAYS_SOFTWARE=1 some-app
        ```

        ## The useful ones {#variables}

        | Variable | What it does | Reach for it when |
        |---|---|---|
        | `LIBGL_ALWAYS_SOFTWARE=1` | Forces Mesa's software renderer | An app renders wrongly on the GPU path |
        | `GALLIUM_DRIVER=llvmpipe` | Picks the software driver outright | The same, more firmly |
        | `GSK_RENDERER=cairo` | GTK4 draws without OpenGL | A GTK4 app shows a blank or black window |
        | `QT_QUICK_BACKEND=software` | Qt Quick draws without OpenGL | A Qt app's interface is blank or garbled |
        | `SDL_VIDEODRIVER=x11` | Stops SDL choosing Wayland | An SDL game exits saying it cannot find a display |
        | `SDL_RENDER_DRIVER=software` | SDL draws without GL | An SDL game opens a window and draws nothing |
        | `GDK_BACKEND=x11` | Stops GTK choosing Wayland | A GTK app cannot find a display |
        | `QT_QPA_PLATFORM=xcb` | The same for Qt | A Qt app cannot find a display |

        MSL already sets the first few of these for apps it launches, so an app started from the Applications
        tab usually has sensible values. These are for when you are running something by hand, or an app needs
        something unusual.

        ## Older games and LOVE apps {#love}

        Older games, and anything built on an old LOVE (love2d) runtime, are the most common thing to need help.
        They tend to ask for an OpenGL setup that assumes a real graphics card and give up quietly when they do
        not get it.

        In rough order of what to try:

        1. Run it from a terminal, so you can see what it actually says.
        2. `SDL_VIDEODRIVER=x11` — many exit immediately without this because they try Wayland first.
        3. `LIBGL_ALWAYS_SOFTWARE=1` — on the CPU path, where OpenGL 4.5 is available.
        4. `SDL_RENDER_DRIVER=software` if it opens a window but draws nothing.
        5. If it is packaged as a Flatpak or Snap, try the plain distribution package instead: sandboxed
           packages bring their own graphics libraries, which is one more thing between the app and mslgd.

        > [!NOTE] Flatpaks and Snaps are a different environment
        > A sandboxed app cannot see `/tmp` the way an ordinary one can, and brings its own copy of Mesa. When
        > an app works as a distribution package and not as a Flatpak, that difference is usually why — it is
        > not a fault in either.

        ## Making it stick {#persisting}

        Adding a line to your shell profile in the instance makes a variable apply to everything you start from
        a shell:

        ```
        echo 'export LIBGL_ALWAYS_SOFTWARE=1' >> ~/.profile
        ```

        For a single app, a better place is the app's own `.desktop` entry, so launching it from the
        Applications tab gets the same treatment.
        """#)

    static let mslgdQuirks = HelpArticle(
        id: "mslgd-quirks", title: "Known quirks", symbol: "exclamationmark.triangle",
        summary: "The rough edges worth recognising, so you can tell a quirk from something broken.",
        keywords: ["quirk", "bug", "known issue", "glitch", "redraw", "window", "menu", "cursor", "wayland"],
        related: ["mslgd", "opengl-apps", "libgl-tricks", "trouble-apps"],
        body: #"""
        mslgd is a display server written from scratch, and a few things are still rough. None of these damage
        anything; they are worth recognising so you do not spend time chasing them.

        ## Things you might meet {#quirks}

        | What you see | What it is |
        |---|---|
        | A Wayland-only app finds no display | mslgd is X11. Try `GDK_BACKEND=x11` or `QT_QPA_PLATFORM=xcb`, or use an X11 build. |
        | An app repaints only part of its window | Usually an OpenGL app on the GPU path. Try it on the CPU. |
        | Menus in the window *and* in the menu bar | The app publishes menus and also draws them. Turn off [the menu bar switch](help:global-menu-bar) for now. |
        | An app's menus are missing entirely | The same switch, the other way: turn it off and the app draws its own again. |
        | A dialog opens behind its window | Some toolkits place dialogs themselves; moving it is harmless. |
        | Very old toolkits look plain | Motif and similar are supported enough to run, not to look modern. |

        ## Reading what an app actually said {#logs}

        Each Linux app that MSL launches keeps its own log. If an app closes on its own or never appears, the
        log is where its last words are — see [Logs and doctor](help:logs-and-doctor) for where to find them.

        Starting the app from a terminal inside the instance is the other half of this, and often quicker: you
        see its output as it happens.

        > [!TIP] Try it without MSL's help first
        > If an app behaves oddly, run it from a terminal in the instance with nothing set. That separates "this
        > app is unhappy here" from "one of MSL's switches does not suit this app", and the two have very
        > different fixes.
        """#)
}
