import Foundation

// Chapter 12. Things to look up rather than read.

extension HelpChapter {
    static let reference = HelpChapter(
        id: "reference", title: "Reference", symbol: "books.vertical", tint: .gray,
        blurb: "Every shortcut, every command, every file, every word.",
        articles: [.shortcuts, .mslCommand, .whereThingsLive, .glossary, .credits])
}

extension HelpArticle {
    static let shortcuts = HelpArticle(
        id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard",
        summary: "Every keyboard shortcut in MSL, in one place.",
        keywords: ["shortcuts", "keys", "keyboard", "hotkeys", "key bindings", "⌘", "command key", "cheat sheet"],
        related: ["files-views", "using-help"],
        body: #"""
        ## Everywhere {#everywhere}

        @keys ⌘N | New Instance
        @keys ⌘R | Refresh (main window)
        @keys ⌥⌘F | MSL Files
        @keys ⇧⌘? | Open the Help menu — MSL Help is in it
        @keys ⌘W | Close the window
        @keys ⌘Q | Quit MSL — instances keep running

        ## Main window {#main}

        @keys ⇧⌘T | Traffic Monitor (while the Sandbox tab is showing)
        @keys ↩ | Create, in the New Instance sheet
        @keys ⎋ | Cancel, in the New Instance sheet

        ## MSL Help {#help}

        @keys ⌘F | Search the guide
        @keys ⎋ | Clear the search

        ## MSL Files {#files}

        Finder's own shortcuts, deliberately.

        ### Views

        @keys ⌘1 | as Icons
        @keys ⌘2 | as List
        @keys ⌘3 | as Columns
        @keys ⌘4 | as Gallery
        @keys ⌃⌘S | Hide or show the sidebar
        @keys ⇧⌘. | Show Hidden Files
        @keys ⌥⌘P | Show Path Bar
        @keys ⌘/ | Show Status Bar

        ### Getting around

        @keys ⌘[ | Back
        @keys ⌘] | Forward
        @keys ⌘↑ | Enclosing folder
        @keys ⌘↓ | Open the selection
        @keys ⇧⌘G | Go to Folder…
        @keys ⇧⌘F | Recents
        @keys ⇧⌘O | Documents
        @keys ⇧⌘D | Desktop
        @keys ⌥⌘L | Downloads
        @keys ⇧⌘H | Home
        @keys ⇧⌘C | Computer
        @keys ⇧⌘A | Applications
        @keys ⇧⌘U | Utilities
        @keys ⇧⌘I | iCloud Drive
        @keys ⌘F | Search this folder

        ### Files

        @keys ⌘O | Open
        @keys ⇧⌘N | New Folder
        @keys ⌃⌘N | New Folder with Selection
        @keys ↩ | Rename
        @keys ⌘D | Duplicate
        @keys ⌘C | Copy
        @keys ⌘V | Paste
        @keys ⌥⌘A | Select All Items
        @keys ⌥⌘C | Copy as Pathname
        @keys ⌘I | Get Info
        @keys Space | Quick Look
        @keys ⌘Y | Quick Look
        @keys ⌘R | Reveal in Finder
        @keys ⌘⌫ | Move to Trash

        ## Reading the symbols {#symbols}

        | Symbol | Key |
        |---|---|
        | ⌘ | Command |
        | ⇧ | Shift |
        | ⌥ | Option |
        | ⌃ | Control |
        | ↩ | Return |
        | ⎋ | Escape |
        | ⌫ | Delete |
        """#)

    static let mslCommand = HelpArticle(
        id: "msl-command", title: "msl command reference", symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Every msl subcommand, what it does, and its options.",
        keywords: ["msl commands", "cli reference", "usage", "subcommands", "options", "flags", "arguments", "man page"],
        related: ["command-line", "logs-and-doctor", "linux-users"],
        body: #"""
        `msl` talks to the same background service as the app. Run `msl help` for this list in your terminal.

        ## Shells and commands {#shells}

        | Command | Does |
        |---|---|
        | `msl [instance]` | An interactive shell. An instance named after a distro (`msl fedora`) needs no setup. |
        | `msl [instance] <command>…` | Runs one command, like `ssh`; its exit code is returned. |
        | `msl -- <command>…` | The same, on the default instance. |
        | `-u`, `--user <name>` | Which Linux user. Every distro also has an unprivileged `msl` user. |
        | `-d`, `--distro <distro>` | Which distro, for an instance being used for the first time. |

        ## Instances {#instances}

        | Command | Does |
        |---|---|
        | `msl list` (or `ls`, `instances`) | Every instance. |
        | `msl new <name> [--distro <d>] [--cpus <n>] [--memory <size>] [--disk <size>]` | Creates an instance, sized, without opening a shell. `--memory 2G-8G` makes it dynamic. |
        | `msl resources [instance]` | Its CPUs, memory and disk. Also `msl config`. |
        | `msl resources <instance> --cpus 4 --memory 6G --disk 128G` | Changes them — the same settings as the Resources and Storage cards. `--disk-fixed <size>` reserves the space up front. |
        | `msl remove <instance> [--keep-disk]` | Removes it and its saved state. Removing a distro's last instance also deletes its disk, unless `--keep-disk`. |
        | `msl status [instance]` | Its state. |
        | `msl suspend [instance]` | Freezes it in memory. |
        | `msl resume [instance]` | Unfreezes or starts it. |
        | `msl hibernate [instance]` | Saves it to disk and stops it. |
        | `msl --hibernate [instance]` | The same — for every running instance if none is named. |
        | `msl --shutdown [instance]` | Asks Linux to power off, then stops it — every running instance if none is named. |

        ## Distros, disks and snapshots {#setup}

        | Command | Does |
        |---|---|
        | `msl install <distro> [--manifest <url>]` | Downloads, verifies and installs a distro: `alpine`, `debian`, `ubuntu`, `kali`, `arch`, `fedora`, `rocky`, `alma`, `centos`, `oracle`, `opensuse` or `nix`. |
        | `msl storage [instance] show` | Shows its disk settings. |
        | `msl storage [instance] dynamic <size>` | A disk that takes only what it has written, up to `<size>`. |
        | `msl storage [instance] fixed <size>` | A disk that reserves `<size>` up front. |
        | `msl snapshot save <instance> <name>` | Saves a snapshot. |
        | `msl snapshot restore <instance> <name>` | Restores one. |
        | `msl snapshot list [instance]` | Lists them. |

        ## Apps {#apps}

        | Command | Does |
        |---|---|
        | `msl apps list [instance]` | Its Linux GUI apps, from the last scan. |
        | `msl apps scan [instance]` | Reads them from the guest again. |
        | `msl apps install <instance> <app>` | Makes a Mac app for it in `~/Applications/MSL`. |
        | `msl apps install-all [instance]` | The same, for every app found. |
        | `msl apps uninstall <instance> <app>` | Removes that Mac app. |
        | `msl apps pin <instance> <app>` / `unpin` | Adds or removes its Dock tile. |

        ## Connecting and checking {#other}

        | Command | Does |
        |---|---|
        | `msl ssh [instance] [--print]` | Connects over SSH, setting it up on first use. `--print` shows the command instead. |
        | `msl doctor [--fix]` | Checks the installation; `--fix` deletes only what it listed. |
        | `msl power-test <event>` | Runs MSL's response to `sleep`, `shutdown`, `logout`, `switchaway`, `switchback`, `lowbattery` or `wake` by hand; `battery` shows what the battery watcher sees. |
        | `msl install-tools` | From a build: installs MSL's tools and its login item. |

        > [!NOTE] Experimental commands
        > `msl gui`, `msl gui-native` and a few `cage-` commands are experiments from MSL's development, for trying
        > other ways of showing Linux graphics. The Applications tab is the supported way to run Linux apps.
        """#)

    static let whereThingsLive = HelpArticle(
        id: "where-things-live", title: "Where MSL keeps things", symbol: "folder.badge.gearshape",
        summary: "Every folder and file MSL uses on your Mac.",
        keywords: ["paths", "files", "folders", "locations", "application support", "library", "where is", "data", "config"],
        related: ["reclaim-space", "logs-and-doctor", "ssh"],
        body: #"""
        | Where | What |
        |---|---|
        | `~/Library/Application Support/MSL` | Everything MSL keeps: distro disks, hibernated sessions, snapshots, repair backups, settings. |
        | …`/rootfs*.img` | The distro disks. See [Reclaiming disk space](help:reclaim-space). |
        | …`/vm-<instance>.state` | Hibernated sessions. |
        | …`/vm-<instance>-<snapshot>.state` | Snapshots. |
        | …`/<disk>.pre-repair` | Backups from disk repairs. |
        | …`/ssh/msl_ed25519` | MSL's own SSH key. |
        | …`/AppCatalog/<instance>` | Each instance's cached list of Linux apps, and their icons. |
        | …`/bin` | MSL's command-line tools, including `msl`. |
        | `~/Library/Logs/MSL` | Logs, including `mslhd.log`. |
        | `~/Applications/MSL/<instance>` | Mac apps made for Linux apps. |
        | `~/Library/LaunchAgents/com.msl.mslhd.plist` | The login item that starts the background service. |
        | `~/.ssh/config` | One `Host msl-<instance>` entry per instance with SSH set up. |

        Inside Linux, your Mac home folder is at `/mnt/mac`.
        """#)

    static let glossary = HelpArticle(
        id: "glossary", title: "Glossary", symbol: "character.book.closed.fill",
        summary: "Every term in MSL, A to Z.",
        keywords: ["glossary", "definitions", "terms", "dictionary", "meaning", "what does it mean"],
        related: ["vocabulary", "how-it-works"],
        body: #"""
        | Term | Meaning |
        |---|---|
        | **Balloon** | How [dynamic memory](help:memory-dynamic) hands memory back: a device inside Linux that inflates to return memory to your Mac and deflates to give it back. |
        | **Check at start** | An optional disk check before every start. See [Checking at every start](help:check-at-start). |
        | **Distro** | A Linux distribution: Alpine, Debian, Ubuntu, Arch, Fedora, Rocky and more — see [Choosing a distro](help:choosing-distro). |
        | **Dynamic disk** | A disk that only takes the space Linux has written, up to a limit. |
        | **Dynamic memory** | Memory that starts at a maximum and gives back what isn't used. |
        | **e2fsck, e2fsprogs** | The Linux filesystem checker, and the package it comes in. Installed on a Mac with `brew install e2fsprogs`. |
        | **Fixed disk** | A disk whose whole size is reserved on your Mac up front. |
        | **Gate** | One of the four [Sandbox](help:sandbox-gates) switches. |
        | **Guest** | Linux, inside the virtual machine. |
        | **Hibernate** | Save an instance's memory to disk and stop it; starting resumes exactly where it was. |
        | **Host** | Your Mac. |
        | **Image** | A distro's disk, as one file on your Mac. Shared by every instance of that distro. |
        | **Instance** | One named Linux machine. |
        | **Maintenance boot** | Starting Linux in a minimal mode to check its own disk. |
        | **Manual memory** | A fixed amount of memory, reserved while the instance runs. |
        | **msl** | MSL's command-line tool. |
        | **mslgd** | MSL's own X11 display server, which turns Linux windows into Mac windows. |
        | **mslhd** | MSL's background service, which runs every instance. |
        | **/mnt/mac** | Where your Mac home folder appears inside Linux. |
        | **Posture** | The Sandbox tab's summary: Open, Partly sealed or Sealed. |
        | **Slot** | One of the four instances MSL will run at once. |
        | **Snapshot** | A saved machine state under a name. |
        | **Stall** | Time Linux programs spend waiting for memory — a sign of memory pressure. |
        | **Suspend** | Freeze an instance in memory; resuming is almost instant. |
        | **vCPU** | A virtual processor. |
        | **vsock** | The direct channel between your Mac and a virtual machine, which doesn't use the network. |
        | **X11** | The protocol Linux GUI apps draw with. |
        """#)

    static let credits = HelpArticle(
        id: "credits", title: "Credits and licences", symbol: "heart",
        summary: "Who made MSL, the licences it's under, and where to read more.",
        keywords: ["credits", "licence", "license", "gpl", "mit", "contributors", "author", "about", "mascot", "illustrator", "open source"],
        related: ["welcome", "how-it-works"],
        body: #"""
        The full story is in the **About MSL** window — choose **MSL ▸ About MSL**.

        ## In the About window {#about-window}

        - **About** — the melon, MSL's logo; the version; and the mascot, illustrated by neekocat_2025.
        - **Licence** — the full text, and why one repository has two licences.
        - **Contributors** — everyone who has landed a commit, read live from GitHub, each with their own colour.
        - **Extras** — what MSL is for, and the story of writing an X11 server from scratch.

        ## Licences {#licences}

        MSL is free software.

        - **mslgd** — the X11 server, its per-app window hosts and the guest-side tunnel, and anything derived from
          them — is under the **GNU General Public License v3**. Use it, change it, share it; if you share changes,
          share their source too. The app ships with mslgd built in, so the app as a whole is GPL v3.
        - **Everything else** — the app, the `msl` command, the background service, MSL Files, the guest daemons and
          the virtual-machine plumbing — is under the **MIT licence**, so anyone can use it for anything.

        > [!ASIDE] Thank you
        > For trying a small, stubborn project that set out to make Linux feel at home on a Mac. If something in this
        > guide is wrong, or missing, that's a bug too. ♡ (˶ᵔ ᵕ ᵔ˶)
        """#)
}
