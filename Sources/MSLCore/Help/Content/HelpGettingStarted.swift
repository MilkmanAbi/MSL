import Foundation

// Chapter 2. From nothing to a running Linux app.

extension HelpChapter {
    static let gettingStarted = HelpChapter(
        id: "getting-started", title: "Getting Started", symbol: "flag.checkered", tint: .rind,
        blurb: "From nothing to a running Linux app, one step at a time.",
        articles: [.installDistro, .createInstance, .firstStart, .choosingDistro, .firstApp, .customImages])
}

extension HelpArticle {
    static let installDistro = HelpArticle(
        id: "install-distro", title: "Installing a distro", symbol: "arrow.down.circle",
        summary: "Download a distro's disk image once, and every instance using it can start.",
        keywords: ["download", "install", "image", "setup", "get linux", "fetch", "first time"],
        related: ["create-instance", "choosing-distro", "reclaim-space"],
        body: #"""
        Before an instance can start, its distro's disk image has to be on your Mac. It's a one-time download of a few
        hundred megabytes per distro, shared by every instance that uses that distro.

        ## From the app {#from-the-app}

        1. Select an instance whose distro isn't downloaded yet. Its header shows **Install *Distro*** where Start
           would normally be.
        2. Click **Install *Distro***. The button changes to **Downloading…**, and the Applications tab shows the
           live progress line from the installer.
        3. When it finishes, a green banner says "*Distro* installed — Instances using it can start now." The button
           becomes **Start**.

        The Applications tab offers the same **Install *Distro*** button while the instance has nothing installed.

        > [!NOTE] Verified as it downloads
        > MSL checks each image against the checksum in its manifest before putting it in place, so a download that
        > was cut short or corrupted is refused instead of becoming a broken disk.

        ## From Terminal {#from-terminal}

        The New Instance sheet mentions this route, and it does exactly the same thing:

        ```shell
        msl install debian
        ```

        The name is one of `alpine`, `debian`, `ubuntu`, `kali`, `arch`, `fedora`, `rocky`, `alma`, `centos`,
        `oracle`, `opensuse` or `nix`.

        ## Where images live {#where}

        In `~/Library/Application Support/MSL`, one image file per distro. The Storage card on each instance's Overview
        tab shows how much space its image really takes on your Mac — often far less than its size, because images
        only take the space they've actually written. See [Disk size and storage](help:storage).

        > [!TIP] Getting space back
        > Deleting an image frees its space immediately, and the next start downloads it fresh. Every instance of that
        > distro starts over from a clean disk, so only do it for distros whose files you don't need. See
        > [Reclaiming disk space](help:reclaim-space).
        """#)

    static let createInstance = HelpArticle(
        id: "create-instance", title: "Creating an instance", symbol: "plus.square.on.square",
        summary: "Name a new Linux machine and pick its distro. It's instant.",
        keywords: ["new instance", "create", "add", "make", "name", "⌘N", "new machine"],
        related: ["first-start", "choosing-distro", "shared-disks"],
        body: #"""
        An instance is one Linux machine with its own name. Creating one takes two decisions and no time at all —
        nothing boots and nothing downloads until you start it.

        ## Steps {#steps}

        1. Press **⌘N**, choose **File ▸ New Instance…**, or click **New Instance** at the bottom of the sidebar.
        2. Type a **Name**.
        3. Pick a **Distribution** from the grid of six. Each tile has its colour, symbol and a one-line description.
        4. Click **Create** (or press Return).

        A green banner says "Created *name*", and the new instance appears in the sidebar, stopped.

        ## Naming rules {#names}

        - Letters, digits, hyphens and underscores only — `work`, `gimp-box`, `test_2`.
        - Each name must be unique, ignoring case: `Work` and `work` count as the same.

        The line under the name field tells you as you type, turning orange if the name won't work: "There's already
        an instance called …" or "Use letters, digits, hyphens and underscores only."

        ## If the distro isn't downloaded yet {#not-downloaded}

        The sheet says so under the distro grid. Creating the instance still works — you'll get an
        **Install *Distro*** button on it afterwards. See [Installing a distro](help:install-distro).

        > [!IMPORTANT] Same distro, same disk
        > The sheet says it too: instances of the same distro share one disk, so only one of them can run at a time.
        > If you want two Linux machines up together, give them different distros. See
        > [Shared disks](help:shared-disks).

        > [!TIP] Why have several instances at all?
        > Each keeps its own settings — CPUs and memory, sandbox switches, SSH shortcut, apps added to your Dock. A
        > sealed `untrusted` instance and an open `work` instance can be the same distro; you just can't run both at
        > once.
        """#)

    static let firstStart = HelpArticle(
        id: "first-start", title: "Your first start and your Linux user", symbol: "person.crop.circle.badge.plus",
        summary: "Starting an instance, and the one-time question about your Linux username and password.",
        keywords: ["first run", "start", "boot", "username", "password", "user account", "root", "welcome", "kitty", "greeter", "login"],
        related: ["linux-users", "terminal-tab", "first-app"],
        body: #"""
        ## Starting {#starting}

        Click **Start** in the instance's header. The dot turns yellow, then green. A first start takes a little
        longer than later ones; after that, starts are quick and resuming a suspended instance is nearly instant.

        You don't always need Start: opening the **Terminal** tab, clicking **Find Apps**, or opening a Linux app all
        start the instance for you.

        > [!NOTE] Start is greyed out?
        > Either the instance is busy with something else (there's a small spinner beside it), or every running slot
        > is taken — MSL runs at most four instances at once, and the capacity pill at the top of the sidebar turns
        > orange when it's full. See [Starting doesn't work](help:trouble-wont-start).

        ## Your Linux user {#user}

        The first time a distro starts, MSL asks you to create your everyday Linux account — a username and a
        password, just like setting up a fresh Linux install. It's an administrator account: it joins the distro's
        admin group, and `sudo` asks for its password.

        ### In the app {#user-app}

        Clicking **Start**, **Find Apps** or opening a Linux app on a distro that has no account yet brings up
        **Create your Linux account** first:

        1. **Username** — it's filled in with your Mac's short name if that works on Linux. Change it if you like;
           it doesn't need to match.
        2. **Password**, and **Retype password**.
        3. **Create Account**. MSL starts the instance, creates the account, and then carries on with whatever you
           were doing. A banner confirms it.

        **Cancel** leaves the distro without an account; you'll be asked again next time.

        ### In a terminal {#user-terminal}

        The first interactive shell — the **Terminal** tab, Terminal.app, or `msl work` — asks in the terminal
        itself, with a small ASCII kitty:

        ```
        Welcome to MSL - debian!
        Please create a default UNIX user account. The username does not need
        to match your Mac username. It becomes your login for debian from now
        on, and its password is the one sudo asks for.
        (root is always available from the Mac: msl <instance> -u root)

        New UNIX username:
        ```

        Type a **username**, then a **password** twice. Nothing appears while you type the password — that's
        normal.

        ## The rules {#user-rules}

        - A username starts with a lowercase letter or an underscore, and uses only lowercase letters, digits, `_`
          or `-` — at most 32 characters.
        - Names the system already uses (`root`, `nobody`, the built-in `msl` account, and so on) are refused, and so
          is a name that already exists in that distro.

        From then on, every shell on that distro — in the app, in Terminal.app, from the `msl` command, over SSH —
        logs you in as that user.

        > [!IMPORTANT] One user per distro, not per instance
        > The account belongs to the distro's disk, which every instance of that distro shares. Create it once on
        > `work`, and `scratch` (also Debian) already has it.

        > [!NOTE] If it can't be created
        > The sheet or the terminal says why. From the terminal, that one shell runs as root instead, and MSL asks
        > again next time.

        More on users, root and `sudo`: [Linux users and root](help:linux-users).

        ## The greeting {#greeting}

        Every interactive shell opens with a short banner — `msl@debian` in colour — and a dimmed one-line greeting
        under it, never the same one twice in a row. Some are sweet, some are cursed, one is extremely tsundere about
        your uptime. None of them are emoji; MSL speaks kaomoji. (≧▽≦)
        """#)

    static let choosingDistro = HelpArticle(
        id: "choosing-distro", title: "Choosing a distro", symbol: "square.stack.3d.up",
        summary: "Twelve distributions, from tiny Alpine to the Enterprise Linux family — what each is like and which to pick.",
        keywords: ["distribution", "alpine", "debian", "ubuntu", "kali", "arch", "fedora", "rocky", "alma", "almalinux", "centos", "stream", "oracle", "opensuse", "suse", "leap", "nix", "nixos", "rhel", "red hat", "enterprise linux", "which distro", "compare", "package manager", "version", "release"],
        related: ["create-instance", "install-distro", "guest-utilities"],
        body: #"""
        MSL runs twelve distributions. Each has its own colour and symbol everywhere in the app, so you can tell them
        apart at a glance.

        | Distro | In the app | Installs software with | Good for |
        |---|---|---|---|
        | **Alpine** | "Tiny and fast. The default." | `apk add` | Small, quick shells; it's what MSL picks first. |
        | **Debian** | "Stable and familiar." | `apt install` | Things that should just keep working. |
        | **Ubuntu** | "Debian, with more batteries." | `apt install` | Following tutorials, which mostly assume Ubuntu. |
        | **Kali** | "Debian, with security tooling." | `apt install` | Security and penetration-testing tools. |
        | **Arch** | "Rolling release, current packages." | `pacman -S` | The newest versions of everything. |
        | **Fedora** | "Recent kernels and toolchains." | `dnf install` | Up-to-date compilers and developer tools. |
        | **Rocky** | "Enterprise Linux, community-built." | `dnf install` | Matching servers that run Red Hat Enterprise Linux. |
        | **AlmaLinux** | "Enterprise Linux, forever free." | `dnf install` | The same, from a different community. |
        | **CentOS Stream** | "Where Enterprise Linux is made." | `dnf install` | Seeing what the next Enterprise Linux release will contain. |
        | **Oracle Linux** | "Enterprise Linux from Oracle." | `dnf install` | Oracle's database and cloud tooling. |
        | **openSUSE** | "SUSE's community release." | `zypper install` | SUSE's packages and conventions. |
        | **Nix** | "Nix packages on a Debian base." | `nix profile install` | Environments you can rebuild exactly. |

        ## Which releases {#releases}

        The current images are **Alpine 3.24**, **Debian 13**, **Ubuntu 26.04 LTS**, **Kali** (rolling), **Arch Linux
        ARM** (rolling), **Fedora 44**, **Rocky Linux 10**, **AlmaLinux 10**, **CentOS Stream 10**, **Oracle Linux 10**
        and **openSUSE Leap 16.0**. Nix is the Nix package manager on Debian 13.

        ## If you're not sure {#unsure}

        - For **Linux GUI apps**, Debian or Ubuntu have the widest choice of desktop programs.
        - For **a quick shell and command-line tools**, Alpine is tiny and starts fastest.
        - For **the latest versions of things**, Arch or Fedora.
        - For **matching a Red Hat Enterprise Linux server**, Rocky or AlmaLinux.

        > [!NOTE] Why there's no Red Hat Enterprise Linux
        > RHEL itself needs a Red Hat subscription, and Red Hat's freely shareable base image is missing tools MSL
        > depends on. Rocky, AlmaLinux, CentOS Stream and Oracle Linux are all built from the same sources.

        > [!NOTE] Nix isn't NixOS
        > The Nix instance is Debian with the Nix package manager installed — `nix-shell`, `nix profile` and
        > reproducible environments all work, and `apt` does too. It doesn't boot NixOS's own system configuration.

        You aren't stuck with the choice: make another instance with a different distro any time. Different distros
        can run side by side; [instances of the same distro can't](help:shared-disks).

        > [!NOTE] One quirk of Alpine
        > Alpine uses a leaner C library (musl) than the others (glibc). Almost everything packaged for Alpine works
        > perfectly; software downloaded as a ready-made Linux binary from a website sometimes expects glibc and
        > won't run. If that happens, a Debian or Ubuntu instance will run it.
        """#)

    static let firstApp = HelpArticle(
        id: "first-app", title: "Your first Linux app", symbol: "wand.and.stars",
        summary: "Install a Linux GUI app, find it in MSL, and open it as a Mac window.",
        keywords: ["gui app", "install app", "gimp", "desktop app", "find apps", "open app", "graphical", "tutorial"],
        related: ["apps-tab", "opening-apps", "add-to-applications", "pin-to-dock"],
        body: #"""
        A fresh distro has few or no GUI apps. Here's how to add one and open it — using GIMP, the image editor, as the
        example.

        ## 1. Install it inside Linux {#install}

        Open the **Terminal** tab and install it with the distro's package manager:

        | Distro | Command |
        |---|---|
        | Alpine | `sudo apk add gimp` |
        | Debian, Ubuntu, Kali, Nix | `sudo apt install gimp` |
        | Arch | `sudo pacman -S gimp` |
        | Fedora | `sudo dnf install gimp` |
        | Rocky, AlmaLinux, CentOS Stream, Oracle Linux | GIMP isn't packaged for Enterprise Linux 10, even in EPEL — `sudo dnf install firefox` works the same way |
        | openSUSE | `sudo zypper install gimp` |

        `sudo` asks for your [Linux user](help:first-start#user)'s password — the one you chose when you set it up.

        ## 2. Find it in MSL {#find}

        Switch to the **Applications** tab and click **Find Apps** (or **Refresh** if the grid already has apps). MSL
        reads every installed app's `.desktop` entry from inside Linux — the same thing a Linux desktop's app menu
        reads — and shows each one with its real icon.

        ## 3. Open it {#open}

        Double-click GIMP's tile, or hover over it and click the ▶ button. A few moments later it opens as a Mac
        window, with its own tile in the Dock and its own name in the menu bar.

        ## 4. Make it feel at home {#keep}

        - **Add to Applications** puts a real GIMP app in `~/Applications/MSL`, so Spotlight finds it. See
          [Adding apps to your Applications folder](help:add-to-applications).
        - **Pin to Dock** keeps it in your Dock. See [Pinning to the Dock](help:pin-to-dock).

        Both work with the MSL window closed.

        > [!TIP] Nothing showing up?
        > If **Find Apps** says "No GUI applications found", nothing installed so far has a `.desktop` entry —
        > command-line programs don't. Install a GUI app, then **Refresh**. More in
        > [Linux apps won't appear or open](help:trouble-apps).
        """#)

    static let customImages = HelpArticle(
        id: "custom-images", title: "Custom images", symbol: "shippingbox",
        summary: "Run your own Linux: a folder with a kernel, an initramfs and a disk.",
        keywords: ["custom", "own image", "my image", "kernel", "initramfs", "rootfs", "build", "community",
                   "distro not listed", "image.json", "fork", "copy distro"],
        related: ["create-instance", "choosing-distro", "install-distro"],
        body: #"""
        Besides MSL's own distros, an instance can run a Linux image you made yourself — any distro, any setup,
        your dotfiles baked in. A custom image is just a folder with three files, and MSL runs it the way it runs
        its own.

        ## The quickest way: start from a distro {#start-from-distro}

        In **New Instance**, open **Start a custom image from a distro**, pick an installed distro, give the image
        a name and choose **Create Image**. MSL copies that distro into **Custom Images** as your own image. The
        copy is instant and takes no extra space until it changes, and everything MSL needs is already inside.

        Then create an instance from it, install whatever you like, and it stays that way — changes to your image
        never touch the distro it came from.

        From Terminal: `msl images new my-image --distro debian`, then `msl new work --distro custom:my-image`.

        ## Making one from scratch {#from-scratch}

        Choose **Open Folder** under **Custom images** in New Instance (or run `msl images open`). MSL opens
        **Custom Images** in Finder, with a README and a guest kit inside. Make a folder — its name is the image's
        id, in letters, digits, `-` and `_` — and put in:

        | File | What it is |
        | --- | --- |
        | `Image` | The kernel: a raw **arm64** kernel `Image`, not a compressed `vmlinuz`. |
        | `initramfs` | An initramfs that can mount ext4 on an NVMe disk. |
        | `rootfs.img` | The root filesystem: a raw ext4 image with no partition table. |
        | `image.json` | Optional: a name, a description, and a `kernelCommandLine` if yours needs one. |

        Choose **Rescan**, and the image appears. If something's wrong — a compressed kernel, a partitioned disk, a
        missing file — MSL lists the image with exactly what to fix.

        > [!IMPORTANT] MSL's guest daemons
        > MSL talks to Linux through small programs inside the image. An image without them boots, but MSL can't
        > reach it: no terminal, no apps, no files. Run `_MSL Guest Kit/provision/provision-msl.sh` as root inside
        > the image before packing it (in a container or chroot). Starting from a distro avoids this entirely.

        ## Removing one {#remove}

        Right-click an instance and choose **Remove … Image**. Its instances go; **the folder and its files stay**
        — MSL never deletes anything in Custom Images. Delete the folder yourself when you're done with it.

        > [!NOTE] Good to know
        > Instances of the same image share its disk, so only one runs at a time. Only arm64 Linux runs on Apple
        > silicon.
        """#)
}
