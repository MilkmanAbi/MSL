# MSL Help

The complete guide that ships inside MSL (Help ▸ MSL Help), as one page: 13 chapters, 77 articles.

## Contents

1. **[Welcome](#chapter-welcome)** · What MSL is, a quick tour, and the words you'll keep seeing.
    - [Welcome to MSL](#welcome)
    - [A two-minute tour](#tour)
    - [Words you'll see](#vocabulary)
    - [Under the hood](#how-it-works)
    - [What's ready, what's experimental](#whats-ready)
    - [Using this guide](#using-help)
2. **[Getting Started](#chapter-getting-started)** · From nothing to a running Linux app, one step at a time.
    - [Installing a distro](#install-distro)
    - [Creating an instance](#create-instance)
    - [Your first start and your Linux user](#first-start)
    - [Choosing a distro](#choosing-distro)
    - [Your first Linux app](#first-app)
    - [Custom images](#custom-images)
3. **[The Main Window](#chapter-main-window)** · The sidebar, the header, the tabs, and the banners that come and go.
    - [The main window](#main-window)
    - [The sidebar](#sidebar)
    - [The instance header](#instance-header)
    - [Banners and messages](#banners)
4. **[Applications Tab](#chapter-applications)** · Linux GUI apps as real Mac windows - find them, open them, keep them in your Dock.
    - [The Applications tab](#apps-tab)
    - [Opening a Linux app](#opening-apps)
    - [Adding apps to your Applications folder](#add-to-applications)
    - [Pinning to the Dock](#pin-to-dock)
    - [Where apps come from](#app-sources)
    - [Living with Linux windows](#linux-windows)
5. **[Terminal & Shells](#chapter-terminal)** · A real Linux shell in the app, in Terminal.app, over SSH, or from the msl command.
    - [The Terminal tab](#terminal-tab)
    - [Using Terminal.app](#terminal-app)
    - [Linux users and root](#linux-users)
    - [Connecting over SSH](#ssh)
    - [The msl command](#command-line)
6. **[Overview Tab](#chapter-overview)** · CPUs, memory, disk, the shared home folder - what each instance is made of.
    - [The Overview tab](#overview-tab)
    - [Virtual CPUs](#processors)
    - [Memory: manual mode](#memory)
    - [Memory: dynamic mode](#memory-dynamic)
    - [Disk size and storage](#storage)
    - [Your home folder inside Linux](#home-share)
    - [How many can run at once](#concurrency)
7. **[Tools Tab](#chapter-tools)** · The background service, snapshots, stopping and removing, and disk check and repair.
    - [The Tools tab](#tools-tab)
    - [The background service](#background-service)
    - [Generated apps](#generated-apps)
    - [Snapshots](#snapshots)
    - [Suspend, hibernate or shut down?](#stopping-instances)
    - [Removing an instance](#removing-instances)
    - [Uninstalling MSL](#uninstalling-msl)
    - [The Maintenance card](#maintenance)
    - [Checking a disk](#disk-check)
    - [Repairing a disk](#disk-repair)
    - [Checking the disk at every start](#check-at-start)
    - [Maintenance boot](#maintenance-boot)
    - [Utilities for a running instance](#guest-utilities)
8. **[Sandbox Tab](#chapter-sandbox)** · Cut an instance off from the network, your files, graphics or input - and watch what it says.
    - [The Sandbox tab](#sandbox)
    - [The four gates](#sandbox-gates)
    - [The Traffic Monitor](#traffic-monitor)
9. **[MSL Files](#chapter-files)** · Browse your Mac and your Linux instances side by side, and move files between them.
    - [The MSL Files window](#files-window)
    - [The Files sidebar](#files-sidebar)
    - [Views, sorting and getting around](#files-views)
    - [Moving files between Mac and Linux](#files-moving)
    - [Tags](#files-tags)
    - [Deleting files](#files-deleting)
    - [Opening a folder in a Linux shell](#files-open-in-msl)
10. **[Power & Lifecycle](#chapter-power)** · What happens when your Mac sleeps or shuts down, when instances sit idle, and why distros share.
    - [Sleep, shutdown and battery](#power-events)
    - [Idle instances](#idle)
    - [Shared disks](#shared-disks)
11. **[Troubleshooting](#chapter-troubleshooting)** · Symptoms first, then what to do - and where to look when that isn't enough.
    - [An instance won't start](#trouble-wont-start)
    - [The service isn't running](#trouble-service)
    - [Linux apps won't appear or open](#trouble-apps)
    - [SSH won't connect](#trouble-ssh)
    - [The disk is full](#trouble-disk)
    - [Filesystem errors](#trouble-filesystem)
    - [The clock is wrong](#trouble-clock)
    - [The Maintenance card says…](#trouble-maintenance)
    - [Memory trouble](#trouble-memory)
    - [Logs and msl doctor](#logs-and-doctor)
    - [Reclaiming disk space](#reclaim-space)
12. **[Command line](#chapter-cli)** · Everything msl --help prints, here.
    - [msl --help](#cli-help)
13. **[Reference](#chapter-reference)** · Every shortcut, every command, every file, every word.
    - [Keyboard shortcuts](#shortcuts)
    - [msl command reference](#msl-command)
    - [Where MSL keeps things](#where-things-live)
    - [Glossary](#glossary)
    - [Credits and licences](#credits)

---

<a id="chapter-welcome"></a>

## 1. Welcome

*What MSL is, a quick tour, and the words you'll keep seeing.*

<a id="welcome"></a>

### Welcome to MSL

*Real Linux on your Mac, as close to native as one project could get it.*

MSL - the **Mac Subsystem for Linux** - runs real Linux distributions on your Mac. Not an emulator and not a compatibility layer: an actual Linux kernel with an actual Linux userland, running on Apple's own Virtualization framework, so there's no emulation in the way and no virtual-machine window to look after.

You get a real Linux shell in about a second, and - experimentally - Linux apps with windows of their own, each with its own Dock tile, its own icon and its own name in the menu bar. ヽ(・∀・)ﾉ

> **A small offering** (´･ω･`)
> macOS already has plenty of good ways to reach Linux: Docker, UTM, Lima, OrbStack, a VM in a window. MSL isn't here to replace any of them. It's another path - one that tries to make Linux feel like it belongs on the Mac, with a lot of engineering effort, care and getting-it-wrong-first poured into it. If it suits the way you work, lovely. If one of the others suits you better, that's lovely too.

<a id="welcome--what-you-can-do"></a>

#### What you can do with it

- **Open a Linux shell**: A real login shell with job control, colours and line editing, inside the app or in Terminal.app.
- **Run Linux apps**: Linux GUI programs open as ordinary Mac windows, each with its own Dock tile.
- **Share files both ways**: Your Mac home folder appears inside Linux at /mnt/mac, and MSL Files browses both sides.
- **Size each machine**: Choose CPUs, a fixed or dynamic amount of memory, and how big each disk may grow.
- **Save and roll back**: Snapshots, hibernation, and disk check-and-repair tools with automatic backups.
- **Cut things off**: Sandbox switches that detach the network, the home share, graphics or input.

<a id="welcome--next"></a>

#### Where to go next

- New here? The [two-minute tour](#tour) walks the whole app from left to right.
- Ready to go? [Install a distro](#install-distro), then [create an instance](#create-instance).
- Curious how it works? [Under the hood](#how-it-works) explains the moving parts in plain words.
- Want to know what's solid and what's still experimental? [What's ready](#whats-ready) is honest about it.

> [!TIP]
> **Searching this guide**
> The search field at the top of the sidebar finds any word in the guide - and it's forgiving: it copes with typos, finishes words as you type, and knows that "RAM" means memory and "VM" means instance. Press **⌘F** in this window to jump to it. More in [Using this guide](#using-help).

**Related:** [A two-minute tour](#tour) · [Installing a distro](#install-distro) · [What's ready, what's experimental](#whats-ready)

<a id="tour"></a>

### A two-minute tour

*Every window and panel in MSL, in the order you'll meet them.*

MSL has one main window, a file browser, and a few smaller windows. Here's all of it, left to right.

<a id="tour--main"></a>

#### The main window

A sidebar-and-detail window, like Mail or Notes.

- **The sidebar** lists your [instances](#vocabulary--instance) - each is one Linux machine with its own name. A coloured badge shows the distro; a small dot shows whether it's running. At the top, a pill like `1/4` shows how many are running out of the most MSL will run at once. At the bottom: **New Instance**, and a strip of the people who built MSL.
- **The header** across the top of the right-hand side shows the selected instance's name, distro and state, with **Terminal** and **Start** (or **Suspend**/**Resume**, or **Install** if its distro isn't downloaded).
- **Five tabs** sit under the header. More on each below.

More detail: [The main window](#main-window).

<a id="tour--tabs"></a>

#### The five tabs

| Tab | What it's for |
|---|---|
| **Applications** | The Linux GUI apps inside the instance, with their real icons. Open them, add them to your Applications folder, pin them to the Dock. |
| **Terminal** | A full terminal with a real Linux shell in it. |
| **Overview** | The instance's settings: SSH, CPUs and memory, disk size, the shared home folder. |
| **Tools** | The background service, generated apps, snapshots, maintenance and repair, and suspend/hibernate/shut down/remove. |
| **Sandbox** | Switches that cut the instance off from the network, your files, graphics or input - plus the Traffic Monitor. |

<a id="tour--other-windows"></a>

#### The other windows

- **MSL Files** (⌥⌘F): a Finder work-alike that shows your Mac and your running Linux instances side by side, so you can drag files across. See [MSL Files](#files-window).
- **Traffic Monitor**: a live log of what MSL and an instance are saying to each other. Opened from the Sandbox tab. See [Traffic Monitor](#traffic-monitor).
- **About MSL**: what MSL is, its licences, the people who built it, and some stories. It's in the MSL menu.
- **MSL Help**: this. It's in the Help menu.

<a id="tour--automatic"></a>

#### Things that happen on their own

- MSL's background service, `mslhd`, starts when you log in. It's what actually runs every instance, and it keeps running when the MSL window is closed - Linux apps you've added to your Dock work without MSL open.
- When you close the last terminal session on an instance, MSL suspends it a few seconds later so it stops using your processor. Opening a shell or an app wakes it again. See [Idle instances](#idle).
- When your Mac sleeps, shuts down or logs out, MSL freezes every running instance first so nothing is mid-write. See [Sleep, shutdown and battery](#power-events).

**Related:** [The main window](#main-window) · [The MSL Files window](#files-window) · [Keyboard shortcuts](#shortcuts)

<a id="vocabulary"></a>

### Words you'll see

*Instance, distro, image, guest, host, mslhd, mslgd - what each one means here.*

A handful of words come up everywhere in MSL. Here they are in the order they start to matter. The [glossary](#glossary) has the full list, A to Z.

<a id="vocabulary--instance"></a>

#### Instance

One Linux machine, with a name you chose - `work`, `scratch`, `gimp-box`. Each instance has its own settings, its own saved state, its own apps list and its own sandbox switches. You can have as many as you like.

<a id="vocabulary--distro"></a>

#### Distro

Short for *distribution* - the flavour of Linux: Alpine, Debian, Ubuntu, Arch, Fedora, Rocky and more. Every instance is one distro, chosen when you create it. See [Choosing a distro](#choosing-distro).

<a id="vocabulary--image"></a>

#### Image

A distro's disk: one big file on your Mac that holds the whole Linux filesystem. You download it once per distro.

> [!IMPORTANT]
> **Instances of the same distro share one disk**
> Two Debian instances use the same Debian image. That keeps your Mac's disk from filling with copies - and it means **only one instance of a given distro can run at a time**, because two running machines writing to one disk would wreck it. Different distros run side by side happily. See [Shared disks](#shared-disks).

<a id="vocabulary--guest-host"></a>

#### Guest and host

The **guest** is Linux, inside the virtual machine. The **host** is your Mac. "Guest-side" means something happens inside Linux; "host-side" means your Mac does it from outside, where Linux can't interfere.

<a id="vocabulary--states"></a>

#### Running, suspended, hibernated, stopped

| State | Dot | What it means |
|---|---|---|
| **Running** | green | Linux is up. |
| **Starting…** | yellow | On its way up or down. |
| **Suspended** | orange | Frozen in memory. Resumes almost instantly, but still holds its memory on your Mac. |
| **Stopped** | grey | Not running. It may have a hibernated session saved to disk - then starting it picks up exactly where it left off. |

The difference between suspend, hibernate and shut down is covered properly in [Suspend, hibernate or shut down?](#stopping-instances).

<a id="vocabulary--mslhd"></a>

#### mslhd

MSL's **background service**. It hosts every instance, starts at login, and keeps running when the MSL window is closed. If it isn't running, nothing can start. See [The background service](#background-service).

<a id="vocabulary--mslgd"></a>

#### mslgd

MSL's own **X11 display server** - the part that turns a Linux app's drawing into a real Mac window. It was written from scratch for MSL. See [Under the hood](#how-it-works--mslgd).

<a id="vocabulary--snapshot"></a>

#### Snapshot

A saved copy of a whole running machine - memory and disk - that you can go back to. See [Snapshots](#snapshots).

<a id="vocabulary--gate"></a>

#### Gate

One of the four [Sandbox](#sandbox) switches: network, Mac home share, graphics, keyboard & mouse. A gate is either open or cut.

**Related:** [Glossary](#glossary) · [Under the hood](#how-it-works)

<a id="how-it-works"></a>

### Under the hood

*The moving parts - the VM, the service, the display server, the per-app processes - in plain words.*

You never need to know any of this to use MSL. But when something behaves in a way that seems odd, the reason is usually here.

<a id="how-it-works--vm"></a>

#### A real virtual machine

Each running instance is a lightweight virtual machine made with Apple's **Virtualization framework** - the same technology behind most Mac virtualisation apps. Your Mac's processor runs Linux directly; nothing is translated or emulated. That's why a shell opens in about a second, and why Linux programs run at close to full speed.

The virtual machine has no window of its own. Everything you see - the terminal, the app windows, the files - reaches your Mac through MSL, not through a screen.

<a id="how-it-works--service"></a>

#### The background service

`mslhd` runs every virtual machine. It's installed as a login item, so it starts when you log in and keeps going when the MSL window is closed. The app, the `msl` command, and the Linux apps in your Dock all ask it to do things - start this, suspend that, open a shell - over a private connection on your Mac.

Its log is at `~/Library/Logs/MSL/mslhd.log`. See [The background service](#background-service).

<a id="how-it-works--vsock"></a>

#### Talking to Linux

The Mac and each guest talk over **vsock**, a direct channel between a virtual machine and its host that doesn't go through the network at all. Shells, file access, app launching and window traffic all use it.

This is why cutting the network in the [Sandbox](#sandbox) doesn't stop `msl` shells from working: detaching the network card doesn't touch vsock.

<a id="how-it-works--files"></a>

#### Your files, both ways

- **Mac → Linux:** your home folder is shared into every running instance at `/mnt/mac`.
- **Linux → Mac:** each running instance's filesystem is served back to your Mac as a network volume. Finder can see it, but it's named after a loopback address rather than the instance, which is why [MSL Files](#files-window) exists: it shows each instance by name, beside your Mac's folders.

<a id="how-it-works--mslgd"></a>

#### Windows for Linux apps

Linux GUI apps draw through a protocol called **X11**. On most Macs the X11 answer is XQuartz, which works well - but under it, every Linux app is a window belonging to XQuartz: one Dock tile, one menu bar, one app.

MSL tried the other thing. **mslgd** is an X11 server written from scratch in Swift, drawing straight into AppKit and Core Graphics, so each Linux window becomes a real Mac window. And because macOS gives exactly one Dock tile per process, **each Linux app runs in its own small helper process** on your Mac - that's how it gets its own tile, icon, name and place in Mission Control.

> **Honest footnote** (´･ω･`)
> This is the part MSL exists to attempt, rather than a finished claim about how well it does it. Plenty of apps work nicely; some still draw oddly. The About window's Extras section has the full story, swearing included. ( ͡° ᴥ ͡°)

<a id="how-it-works--bundles"></a>

#### Apps as Mac apps

When you [add a Linux app to your Applications folder](#add-to-applications), MSL writes a real, tiny `.app` into `~/Applications/MSL/<instance>/`. Opening it asks the background service to start the instance if it needs to, then runs the Linux program. That's why Spotlight and the Dock can launch Linux apps with the MSL window closed.

**Related:** [Words you'll see](#vocabulary) · [Living with Linux windows](#linux-windows) · [The background service](#background-service)

<a id="whats-ready"></a>

### What's ready, what's experimental

*An honest map of what's solid and what's still experimental.*

This is MSL-1.0.0 - still held together with love. Here's where things stand, so nothing catches you out.

<a id="whats-ready--solid"></a>

#### Solid

- Installing distros and creating instances.
- Shells - in the app, in Terminal.app, over SSH, and with the `msl` command.
- Suspend, hibernate, shut down, snapshots, and protecting instances when your Mac sleeps or shuts down.
- CPU count, manual memory, disk sizing and automatic disk growth.
- Your home folder inside Linux at `/mnt/mac`, and MSL Files.
- The Sandbox gates and the MSL side of the Traffic Monitor.
- Checking and repairing a disk from the Mac, with automatic backups (needs one free tool - see [Checking a disk](#disk-check)).

<a id="whats-ready--experimental"></a>

#### Experimental

- **Linux GUI apps as Mac windows.** Many apps work well; some draw imperfectly. It's the most ambitious part of MSL and the most likely to surprise you.
- **Everything in Experimental Features** (**Window ▸ Experimental Features**). Every experiment lives there, and each says whether it starts on or off: - **Open links on the Mac** (on) - web and email links from Linux apps open in your Mac's browser and mail app, with attachments. - **Show folders in MSL Files** (on) - "Open containing folder" and friends open MSL Files instead of a Linux file manager. Nautilus, Dolphin and the rest still run when you start them yourself. - **Linux app menus in the menu bar** (off) - a Linux app's menus move into the Mac menu bar. Qt and KDE apps support it on their own; GTK apps need `appmenu-gtk3-module` in the instance. - **Mac shortcuts, text navigation, screenshot keys and Option keys** (off) - how Linux apps receive your keyboard.

Experiments aren't promises: a future version may build one in properly, change it, or remove it, depending on what the community prefers. The list is specific to each version.

**Related:** [The Maintenance card says…](#trouble-maintenance) · [Memory: dynamic mode](#memory-dynamic) · [The Maintenance card](#maintenance)

<a id="using-help"></a>

### Using this guide

*How search works, what the coloured boxes mean, and the keys for getting around.*

Open this guide from anywhere in MSL with **Help ▸ MSL Help**. From the keyboard, **⇧⌘?** opens the Help menu in any Mac app - then choose MSL Help. The same menu also jumps straight to Getting Started, Keyboard Shortcuts, Troubleshooting, and what's ready or experimental.

<a id="using-help--searching"></a>

#### Searching

Type in the search field at the top of the sidebar. Results appear as you type, each one pointing at the exact section that matches - click one and the guide scrolls there, with your words highlighted.

Search is deliberately forgiving:

- **Every word counts.** `memory dynamic` finds places that mention both. If nothing mentions all of them, you get the places that mention some.
- **Half-typed words work.** `snaps` already finds snapshots.
- **Other forms work.** `restoring`, `restored` and `restores` all find each other.
- **Typos work.** A letter missing, doubled or swapped with its neighbour still finds the word you meant.
- **Everyday words work.** `ram` finds memory, `vm` finds instances, `delete` finds remove, `fsck` finds disk repair, `wifi` finds the network gate, `wireshark` finds the Traffic Monitor.
- **Keys work.** Search for `⌘` or `shortcut` to find keyboard shortcuts.

| Keys | Does |
|---|---|
| ⌘F | Jump to the search field |
| ⎋ | Clear the search |
| ⇧⌘? | Open the Help menu, in any Mac app |

<a id="using-help--reading"></a>

#### Reading

Each article starts with a one-line summary and an "On this page" list of its sections - click any of them to jump. Blue links go to other parts of the guide. **Related** at the bottom suggests where to read next, and the arrows at the very end step through the whole guide in order.

<a id="using-help--callouts"></a>

#### The coloured boxes

> [!TIP]
> **Tip**
> A shortcut, or a nicer way to do something.

> [!NOTE]
> **Note**
> Extra detail worth knowing.

> [!IMPORTANT]
> **Important**
> Something that changes how a feature behaves.

> [!WARNING]
> **Warning**
> Something that can cost you time or work if you miss it.

> [!CAUTION]
> **Danger**
> Something you can't undo.

> **Aside** (´･ω･`)
> MSL being a person for a moment. (˶ᵔ ᵕ ᵔ˶)

**Related:** [Keyboard shortcuts](#shortcuts) · [Glossary](#glossary)

---

<a id="chapter-getting-started"></a>

## 2. Getting Started

*From nothing to a running Linux app, one step at a time.*

<a id="install-distro"></a>

### Installing a distro

*Download a distro's disk image once, and every instance using it can start.*

Before an instance can start, its distro's disk image has to be on your Mac. It's a one-time download of a few hundred megabytes per distro, shared by every instance that uses that distro.

<a id="install-distro--from-the-app"></a>

#### From the app

1. Select an instance whose distro isn't downloaded yet. Its header shows **Install *Distro*** where Start would normally be.
2. Click **Install *Distro***. The button changes to **Downloading…**, and the Applications tab shows the live progress line from the installer.
3. When it finishes, a green banner says "*Distro* installed - Instances using it can start now." The button becomes **Start**.

The Applications tab offers the same **Install *Distro*** button while the instance has nothing installed.

> [!NOTE]
> **Verified as it downloads**
> MSL checks each image against the checksum in its manifest before putting it in place, so a download that was cut short or corrupted is refused instead of becoming a broken disk.

<a id="install-distro--from-terminal"></a>

#### From Terminal

The New Instance sheet mentions this route, and it does exactly the same thing:

```sh
msl install debian
```

The name is one of `alpine`, `debian`, `ubuntu`, `kali`, `arch`, `fedora`, `rocky`, `alma`, `centos`, `oracle`, `opensuse` or `nix`.

<a id="install-distro--where"></a>

#### Where images live

In `~/Library/Application Support/MSL`, one image file per distro. The Storage card on each instance's Overview tab shows how much space its image really takes on your Mac - often far less than its size, because images only take the space they've actually written. See [Disk size and storage](#storage).

> [!TIP]
> **Getting space back**
> Deleting an image frees its space immediately, and the next start downloads it fresh. Every instance of that distro starts over from a clean disk, so only do it for distros whose files you don't need. See [Reclaiming disk space](#reclaim-space).

**Related:** [Creating an instance](#create-instance) · [Choosing a distro](#choosing-distro) · [Reclaiming disk space](#reclaim-space)

<a id="create-instance"></a>

### Creating an instance

*Name a new Linux machine and pick its distro. It's instant.*

An instance is one Linux machine with its own name. Creating one takes two decisions and no time at all - nothing boots and nothing downloads until you start it.

<a id="create-instance--steps"></a>

#### Steps

1. Press **⌘N**, choose **File ▸ New Instance…**, or click **New Instance** at the bottom of the sidebar.
2. Type a **Name**.
3. Pick a **Distribution** from the grid of six. Each tile has its colour, symbol and a one-line description.
4. Click **Create** (or press Return).

A green banner says "Created *name*", and the new instance appears in the sidebar, stopped.

<a id="create-instance--names"></a>

#### Naming rules

- Letters, digits, hyphens and underscores only - `work`, `gimp-box`, `test_2`.
- Each name must be unique, ignoring case: `Work` and `work` count as the same.

The line under the name field tells you as you type, turning orange if the name won't work: "There's already an instance called …" or "Use letters, digits, hyphens and underscores only."

<a id="create-instance--not-downloaded"></a>

#### If the distro isn't downloaded yet

The sheet says so under the distro grid. Creating the instance still works - you'll get an **Install *Distro*** button on it afterwards. See [Installing a distro](#install-distro).

> [!IMPORTANT]
> **Same distro, same disk**
> The sheet says it too: instances of the same distro share one disk, so only one of them can run at a time. If you want two Linux machines up together, give them different distros. See [Shared disks](#shared-disks).

> [!TIP]
> **Why have several instances at all?**
> Each keeps its own settings - CPUs and memory, sandbox switches, SSH shortcut, apps added to your Dock. A sealed `untrusted` instance and an open `work` instance can be the same distro; you just can't run both at once.

**Related:** [Your first start and your Linux user](#first-start) · [Choosing a distro](#choosing-distro) · [Shared disks](#shared-disks)

<a id="first-start"></a>

### Your first start and your Linux user

*Starting an instance, and the one-time question about your Linux username and password.*

<a id="first-start--starting"></a>

#### Starting

Click **Start** in the instance's header. The dot turns yellow, then green. A first start takes a little longer than later ones; after that, starts are quick and resuming a suspended instance is nearly instant.

You don't always need Start: opening the **Terminal** tab, clicking **Find Apps**, or opening a Linux app all start the instance for you.

> [!NOTE]
> **Start is greyed out?**
> Either the instance is busy with something else (there's a small spinner beside it), or every running slot is taken - MSL runs at most four instances at once, and the capacity pill at the top of the sidebar turns orange when it's full. See [Starting doesn't work](#trouble-wont-start).

<a id="first-start--user"></a>

#### Your Linux user

The first time a distro starts, MSL asks you to create your everyday Linux account - a username and a password, just like setting up a fresh Linux install. It's an administrator account: it joins the distro's admin group, and `sudo` asks for its password.

<a id="first-start--user-app"></a>

##### In the app

Clicking **Start**, **Find Apps** or opening a Linux app on a distro that has no account yet brings up **Create your Linux account** first:

1. **Username**: it's filled in with your Mac's short name if that works on Linux. Change it if you like; it doesn't need to match.
2. **Password**, and **Retype password**.
3. **Create Account**. MSL starts the instance, creates the account, and then carries on with whatever you were doing. A banner confirms it.

**Cancel** leaves the distro without an account; you'll be asked again next time.

<a id="first-start--user-terminal"></a>

##### In a terminal

The first interactive shell - the **Terminal** tab, Terminal.app, or `msl work` - asks in the terminal itself, with a small ASCII kitty:

```
Welcome to MSL - debian!
Please create a default UNIX user account. The username does not need
to match your Mac username. It becomes your login for debian from now
on, and its password is the one sudo asks for.
(root is always available from the Mac: msl <instance> -u root)

New UNIX username:
```

Type a **username**, then a **password** twice. Nothing appears while you type the password - that's normal.

<a id="first-start--user-rules"></a>

#### The rules

- A username starts with a lowercase letter or an underscore, and uses only lowercase letters, digits, `_` or `-` - at most 32 characters.
- Names the system already uses (`root`, `nobody`, the built-in `msl` account, and so on) are refused, and so is a name that already exists in that distro.

From then on, every shell on that distro - in the app, in Terminal.app, from the `msl` command, over SSH - logs you in as that user.

> [!IMPORTANT]
> **One user per distro, not per instance**
> The account belongs to the distro's disk, which every instance of that distro shares. Create it once on `work`, and `scratch` (also Debian) already has it.

> [!NOTE]
> **If it can't be created**
> The sheet or the terminal says why. From the terminal, that one shell runs as root instead, and MSL asks again next time.

More on users, root and `sudo`: [Linux users and root](#linux-users).

<a id="first-start--greeting"></a>

#### The greeting

Every interactive shell opens with a short banner - `msl@debian` in colour - and a dimmed one-line greeting under it, never the same one twice in a row. Some are sweet, some are cursed, one is extremely tsundere about your uptime. None of them are emoji; MSL speaks kaomoji. (≧▽≦)

**Related:** [Linux users and root](#linux-users) · [The Terminal tab](#terminal-tab) · [Your first Linux app](#first-app)

<a id="choosing-distro"></a>

### Choosing a distro

*Twelve distributions, from tiny Alpine to the Enterprise Linux family - what each is like and which to pick.*

MSL runs twelve distributions. Each has its own colour and symbol everywhere in the app, so you can tell them apart at a glance.

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

<a id="choosing-distro--releases"></a>

#### Which releases

The current images are **Alpine 3.24**, **Debian 13**, **Ubuntu 26.04 LTS**, **Kali** (rolling), **Arch Linux ARM** (rolling), **Fedora 44**, **Rocky Linux 10**, **AlmaLinux 10**, **CentOS Stream 10**, **Oracle Linux 10** and **openSUSE Leap 16.0**. Nix is the Nix package manager on Debian 13.

<a id="choosing-distro--unsure"></a>

#### If you're not sure

- For **Linux GUI apps**, Debian or Ubuntu have the widest choice of desktop programs.
- For **a quick shell and command-line tools**, Alpine is tiny and starts fastest.
- For **the latest versions of things**, Arch or Fedora.
- For **matching a Red Hat Enterprise Linux server**, Rocky or AlmaLinux.

> [!NOTE]
> **Why there's no Red Hat Enterprise Linux**
> RHEL itself needs a Red Hat subscription, and Red Hat's freely shareable base image is missing tools MSL depends on. Rocky, AlmaLinux, CentOS Stream and Oracle Linux are all built from the same sources.

> [!NOTE]
> **Nix isn't NixOS**
> The Nix instance is Debian with the Nix package manager installed - `nix-shell`, `nix profile` and reproducible environments all work, and `apt` does too. It doesn't boot NixOS's own system configuration.

You aren't stuck with the choice: make another instance with a different distro any time. Different distros can run side by side; [instances of the same distro can't](#shared-disks).

> [!NOTE]
> **One quirk of Alpine**
> Alpine uses a leaner C library (musl) than the others (glibc). Almost everything packaged for Alpine works perfectly; software downloaded as a ready-made Linux binary from a website sometimes expects glibc and won't run. If that happens, a Debian or Ubuntu instance will run it.

**Related:** [Creating an instance](#create-instance) · [Installing a distro](#install-distro) · [Utilities for a running instance](#guest-utilities)

<a id="first-app"></a>

### Your first Linux app

*Install a Linux GUI app, find it in MSL, and open it as a Mac window.*

A fresh distro has few or no GUI apps. Here's how to add one and open it - using GIMP, the image editor, as the example.

<a id="first-app--install"></a>

#### 1. Install it inside Linux

Open the **Terminal** tab and install it with the distro's package manager:

| Distro | Command |
|---|---|
| Alpine | `sudo apk add gimp` |
| Debian, Ubuntu, Kali, Nix | `sudo apt install gimp` |
| Arch | `sudo pacman -S gimp` |
| Fedora | `sudo dnf install gimp` |
| Rocky, AlmaLinux, CentOS Stream, Oracle Linux | GIMP isn't packaged for Enterprise Linux 10, even in EPEL - `sudo dnf install firefox` works the same way |
| openSUSE | `sudo zypper install gimp` |

`sudo` asks for your [Linux user](#first-start--user)'s password - the one you chose when you set it up.

<a id="first-app--find"></a>

#### 2. Find it in MSL

Switch to the **Applications** tab and click **Find Apps** (or **Refresh** if the grid already has apps). MSL reads every installed app's `.desktop` entry from inside Linux - the same thing a Linux desktop's app menu reads - and shows each one with its real icon.

<a id="first-app--open"></a>

#### 3. Open it

Double-click GIMP's tile, or hover over it and click the ▶ button. A few moments later it opens as a Mac window, with its own tile in the Dock and its own name in the menu bar.

<a id="first-app--keep"></a>

#### 4. Make it feel at home

- **Add to Applications** puts a real GIMP app in `~/Applications/MSL`, so Spotlight finds it. See [Adding apps to your Applications folder](#add-to-applications).
- **Pin to Dock** keeps it in your Dock. See [Pinning to the Dock](#pin-to-dock).

Both work with the MSL window closed.

> [!TIP]
> **Nothing showing up?**
> If **Find Apps** says "No GUI applications found", nothing installed so far has a `.desktop` entry - command-line programs don't. Install a GUI app, then **Refresh**. More in [Linux apps won't appear or open](#trouble-apps).

**Related:** [The Applications tab](#apps-tab) · [Opening a Linux app](#opening-apps) · [Adding apps to your Applications folder](#add-to-applications) · [Pinning to the Dock](#pin-to-dock)

<a id="custom-images"></a>

### Custom images

*Run your own Linux: a folder with a kernel, an initramfs and a disk.*

Besides MSL's own distros, an instance can run a Linux image you made yourself - any distro, any setup, your dotfiles baked in. A custom image is just a folder with three files, and MSL runs it the way it runs its own.

<a id="custom-images--start-from-distro"></a>

#### The quickest way: start from a distro

In **New Instance**, open **Start a custom image from a distro**, pick an installed distro, give the image a name and choose **Create Image**. MSL copies that distro into **Custom Images** as your own image. The copy is instant and takes no extra space until it changes, and everything MSL needs is already inside.

Then create an instance from it, install whatever you like, and it stays that way - changes to your image never touch the distro it came from.

From Terminal: `msl images new my-image --distro debian`, then `msl new work --distro custom:my-image`.

<a id="custom-images--from-scratch"></a>

#### Making one from scratch

Choose **Open Folder** under **Custom images** in New Instance (or run `msl images open`). MSL opens **Custom Images** in Finder, with a README and a guest kit inside. Make a folder - its name is the image's id, in letters, digits, `-` and `_` - and put in:

| File | What it is |
|---|---|
| `Image` | The kernel: a raw **arm64** kernel `Image`, not a compressed `vmlinuz`. |
| `initramfs` | An initramfs that can mount ext4 on an NVMe disk. |
| `rootfs.img` | The root filesystem: a raw ext4 image with no partition table. |
| `image.json` | Optional: a name, a description, and a `kernelCommandLine` if yours needs one. |

Choose **Rescan**, and the image appears. If something's wrong - a compressed kernel, a partitioned disk, a missing file - MSL lists the image with exactly what to fix.

> [!IMPORTANT]
> **MSL's guest daemons**
> MSL talks to Linux through small programs inside the image. An image without them boots, but MSL can't reach it: no terminal, no apps, no files. Run `_MSL Guest Kit/provision/provision-msl.sh` as root inside the image before packing it (in a container or chroot). Starting from a distro avoids this entirely.

<a id="custom-images--remove"></a>

#### Removing one

Right-click an instance and choose **Remove … Image**. Its instances go; **the folder and its files stay** - MSL never deletes anything in Custom Images. Delete the folder yourself when you're done with it.

> [!NOTE]
> **Good to know**
> Instances of the same image share its disk, so only one runs at a time. Only arm64 Linux runs on Apple silicon.

**Related:** [Creating an instance](#create-instance) · [Choosing a distro](#choosing-distro) · [Installing a distro](#install-distro)

---

<a id="chapter-main-window"></a>

## 3. The Main Window

*The sidebar, the header, the tabs, and the banners that come and go.*

<a id="main-window"></a>

### The main window

*One sidebar of instances, one detail pane with five tabs.*

MSL's main window is a sidebar on the left listing your instances, and a detail pane on the right for the one you've selected.

<a id="main-window--detail"></a>

#### The detail pane

From top to bottom:

1. **The header**: the instance's name, distro and state, and its main buttons. See [The instance header](#instance-header).
2. **The tab bar**: Applications · Terminal · Overview · Tools · Sandbox.
3. **The tab itself.**

- **Applications**: Linux GUI apps inside the instance - open, add to Applications, pin to Dock.
- **Terminal**: A real Linux shell, right in the window.
- **Overview**: SSH, CPUs and memory, storage, the shared home folder.
- **Tools**: The service, snapshots, maintenance and repair, suspend and shut down.
- **Sandbox**: Four switches that cut the instance off, and the Traffic Monitor.

> [!NOTE]
> **Tabs start on Applications**
> Selecting a different instance opens it on its Applications tab. Terminal sessions aren't lost when you switch - each instance keeps its own shell running in the background until you end it.

<a id="main-window--empty"></a>

#### With nothing selected

The detail pane says "No instance selected" and offers **New Instance…**. If MSL's background service isn't running, it says that instead and offers **Start it** - see [The background service](#background-service).

<a id="main-window--refresh"></a>

#### Refreshing

MSL keeps itself up to date: instance states refresh every few seconds on their own. **View ▸ Refresh** (⌘R) asks right away, which is handy after doing something from Terminal with the `msl` command.

**Related:** [The sidebar](#sidebar) · [The instance header](#instance-header) · [A two-minute tour](#tour)

<a id="sidebar"></a>

### The sidebar

*Your instances, how many are running, New Instance, and the people who built MSL.*

<a id="sidebar--rows"></a>

#### Instance rows

Each row shows:

- **The distro badge**: a rounded square in the distro's colour with its symbol.
- **The name**, and the distro under it.
- **A status dot** on the right: green running, orange suspended, yellow starting, grey stopped. While the instance is busy - starting, suspending, restoring a snapshot - a small spinner replaces the dot.

Click a row to show that instance in the detail pane.

<a id="sidebar--capacity"></a>

#### The capacity pill

Beside the **Instances** heading, a pill like `2/4` shows how many instances are running (or suspended) out of the most MSL will run at once. It turns **orange** when every slot is taken, and hovering over it explains.

Suspended instances count because they still hold their memory on your Mac. See [How many can run at once](#concurrency).

<a id="sidebar--context-menu"></a>

#### Right-click menu

Right-click (or Control-click) any instance:

| Item | What it does |
|---|---|
| **Start** | Starts or resumes it. Only shown when it isn't running, greyed out when every slot is taken. |
| **Suspend** | Freezes it in memory. Only shown while running. |
| **Shut Down** | Stops it straight away. Only shown while running - read [the note on Shut Down](#stopping-instances--shut-down) first. |
| **Open in Terminal.app** | Opens a shell on it in a Terminal.app window. |
| **Show Apps in Finder** | Opens the folder of Mac apps MSL has made for it. |
| **Remove…** | Removes the instance. See the warning below. |

> [!CAUTION]
> **Remove happens straight away**
> Despite the "…", **Remove…** doesn't ask first. It unregisters the instance, deletes its saved state and snapshots, and deletes the Mac apps made for it. The distro's disk image - and every file in it - is untouched. See [Removing an instance](#removing-instances).

<a id="sidebar--new"></a>

#### New Instance

At the bottom of the list. Same as ⌘N. See [Creating an instance](#create-instance).

<a id="sidebar--built-by"></a>

#### Built by

Under that, a strip of small avatars: everyone who has landed a commit in MSL's repository, read live from GitHub. Hover to see their names; click to open the contributors page. If GitHub can't be reached, the strip quietly doesn't appear - nothing in the sidebar ever nags about it. The About window's **Contributors** section has everyone in full, each with their own colour. ٩(ˊᗜˋ*)و

**Related:** [How many can run at once](#concurrency) · [Suspend, hibernate or shut down?](#stopping-instances) · [Removing an instance](#removing-instances)

<a id="instance-header"></a>

### The instance header

*The name, the state, and the buttons that change with it: Start, Suspend, Resume, Install.*

Across the top of the detail pane: a large distro badge, the instance's name, and "*Distro* · *State*" under it. On the right, the buttons - which ones depends on the state.

<a id="instance-header--buttons"></a>

#### The buttons

**Terminal** is always there. It switches to the Terminal tab, which opens a shell (starting the instance if needed).

The second button changes:

| When the instance is… | You see | Clicking it… |
|---|---|---|
| Stopped, distro downloaded | **Start** | starts it (or resumes a hibernated session). |
| Stopped, distro not downloaded | **Install *Distro*** | downloads the image. Shows **Downloading…** meanwhile. |
| Running | **Suspend** ▾ | freezes it. |
| Suspended | **Resume** ▾ | unfreezes it, almost instantly. |

**Suspend** and **Resume** are split buttons: click the main part for the action, or the small arrow for the same menu as right-clicking the instance in the sidebar - Shut Down, Open in Terminal.app, Show Apps in Finder and Remove….

> [!NOTE]
> **Why Start is sometimes grey**
> It's disabled while the instance is busy (a spinner shows beside the buttons) and when every running slot is already taken. Hovering over it says which.

<a id="instance-header--busy"></a>

#### Busy

While MSL works on an instance - starting, suspending, hibernating, restoring a snapshot - a small spinner appears in the header and on its sidebar row, and the buttons wait until it's done.

**Related:** [Suspend, hibernate or shut down?](#stopping-instances) · [Installing a distro](#install-distro) · [The Terminal tab](#terminal-tab)

<a id="banners"></a>

### Banners and messages

*The notices that drop in from the top of the window, and which ones stay.*

When something finishes or goes wrong, MSL says so in a banner that slides down from the top of the window, rather than an alert you'd have to click away.

| Banner | Icon | Goes away |
|---|---|---|
| **Success**: "Created work", "Saved 'before-upgrade'" | green tick | by itself, after a few seconds |
| **Information**: "No GUI applications found in work" | blue info | by itself, after a few seconds |
| **Error**: "Couldn't start work", with the reason under it | orange triangle | only when you close it |

Errors stay on purpose: an error you missed is one you'll hit again. Close any banner with the **×** on its right.

> [!TIP]
> **Errors with a long reason**
> The detail under an error is the actual reason from MSL's background service. If it's cryptic, the service's log usually has more - see [Logs and msl doctor](#logs-and-doctor).

<a id="banners--in-cards"></a>

#### Messages inside cards

Some parts of the app report in place instead, right where you clicked: the Maintenance card shows its results in a coloured box under its buttons (green, orange, red or blue), the Storage card shows problems in orange under its controls, and the Terminal tab shows "Session ended" over the terminal.

**Related:** [An instance won't start](#trouble-wont-start) · [Logs and msl doctor](#logs-and-doctor)

---

<a id="chapter-applications"></a>

## 4. Applications Tab

*Linux GUI apps as real Mac windows - find them, open them, keep them in your Dock.*

<a id="apps-tab"></a>

### The Applications tab

*A grid of the Linux GUI apps inside an instance, with their real icons.*

The Applications tab shows the graphical apps installed inside an instance - the programs a Linux desktop would list in its app menu. It's the tab MSL opens first.

<a id="apps-tab--finding"></a>

#### Finding apps

The first time, the tab is empty with a **Find Apps** button. Clicking it:

1. starts the instance if it isn't running ("Starting an instance for the first time can take a moment"),
2. reads every installed app's `.desktop` entry from inside Linux - the same file a Linux desktop reads to put an app in its menu,
3. fetches each app's icon, and fills the grid.

After that the button says **Refresh**, and "Updated *5 minutes ago*" beside it says when the list was last read. Refresh after installing or removing software inside Linux.

> [!NOTE]
> **Only apps with windows**
> Command-line programs have no `.desktop` entry, so they don't appear here - use them from the [Terminal](#terminal-tab). If nothing at all turns up, MSL says "No GUI applications found" and suggests installing some.

> [!TIP]
> **Or just type its name**
> Any shell MSL opens - the Terminal tab, or `msl` in Terminal.app - can start GUI apps too: type `gnome-chess` or `gimp` at the prompt and it opens as a Mac window. From a Mac terminal, `msl debian gimp` does the same in one step.

<a id="apps-tab--toolbar"></a>

#### The toolbar

- **Search**: "Search *N* apps". Matches app names and descriptions, and the packaging: typing `flatpak` shows only Flatpak apps.
- **Source picker**: All · System · User · Flatpak · Snap. It only appears when the instance has apps from more than one source. See [Where apps come from](#app-sources).
- **Find Apps / Refresh** on the right.

<a id="apps-tab--tiles"></a>

#### Each tile

| Part | Means |
|---|---|
| The icon | The app's own icon, drawn from its vector artwork when it has one, so it stays crisp. |
| The name | Up to two lines. |
| A small grey badge | Where it came from - only shown for User, Flatpak and Snap apps. |
| A blue tick in the corner | It's in your Applications folder. |
| A small spinner in the corner | MSL is fetching a sharper icon for it. |

Hover over a tile to reveal three small buttons: **▶** open, **folder** add to or remove from Applications, and **pin** pin or unpin from the Dock. Hovering also shows the app's description.

<a id="apps-tab--context-menu"></a>

#### Right-click

**Open**, **Add to Applications** (or **Remove from Applications**), **Pin to Dock** (or **Unpin from Dock**), and - greyed out at the bottom - the exact command the app runs, for the curious.

**Related:** [Your first Linux app](#first-app) · [Opening a Linux app](#opening-apps) · [Where apps come from](#app-sources)

<a id="opening-apps"></a>

### Opening a Linux app

*Double-click a tile, and a Linux app opens as a Mac window with its own Dock tile.*

Double-click a tile, click its **▶**, or right-click and choose **Open**.

If the instance isn't running, it starts first. A moment later the app appears as a normal Mac window - with its own tile in the Dock, its own name in the menu bar, and its own place in Mission Control and ⌘-Tab.

<a id="opening-apps--one-path"></a>

#### Three ways in, one path

| From | How |
|---|---|
| The Applications tab | Double-click or ▶. |
| Spotlight or Finder | Once you've [added it to Applications](#add-to-applications). |
| The Dock | Once you've [pinned it](#pin-to-dock). |

When an app has been added to Applications, opening it from the grid goes through that same Mac app - so if it works from one place, it works from all of them.

> [!TIP]
> **The MSL window doesn't need to stay open**
> Linux apps are run by MSL's background service, not by this window. Close MSL and the apps carry on.

<a id="opening-apps--fails"></a>

#### If it doesn't open

An orange banner says "Couldn't start *app*" with the reason. The usual causes, and what to do, are in [Linux apps won't appear or open](#trouble-apps).

**Related:** [Living with Linux windows](#linux-windows) · [Linux apps won't appear or open](#trouble-apps) · [Adding apps to your Applications folder](#add-to-applications)

<a id="add-to-applications"></a>

### Adding apps to your Applications folder

*Turn a Linux app into a real Mac app that Spotlight, Finder and Launchpad can find.*

**Add to Applications**: the folder button on a tile, or the right-click menu - writes a small, real Mac app for the Linux program into `~/Applications/MSL/<instance>/`.

A banner confirms it: "*App* added to your Applications - It's in ~/Applications/MSL/*instance* and searchable from Spotlight." The tile gets a blue tick.

From then on it behaves like any other Mac app: find it with Spotlight, open it from Finder, drag it wherever you like. Opening it starts the instance if needed, then the app - with the MSL window closed or open.

<a id="add-to-applications--icon"></a>

#### A sharper icon

The grid uses modest icons so it fills quickly. When you add an app, MSL fetches the best icon the app has from inside Linux, so the Mac app looks right at every size. That can mean starting the instance for a moment.

> [!NOTE]
> **When every slot is full**
> If starting the instance would go over the [four-instance limit](#concurrency), MSL still adds the app, using the icon it already has, and says "Using *app*'s existing icon". Add it again later for the sharp one.

<a id="add-to-applications--remove"></a>

#### Removing it

**Remove from Applications** deletes that Mac app, and unpins it from the Dock if it was pinned. Deleting the app in Finder does the same thing. Nothing inside Linux changes - the Linux program stays installed.

> [!TIP]
> **Tidy up after an instance**
> Removing an instance deletes every Mac app made for it, so nothing is left pointing at a machine that no longer exists. See [Removing an instance](#removing-instances).

**Related:** [Pinning to the Dock](#pin-to-dock) · [Generated apps](#generated-apps) · [Opening a Linux app](#opening-apps)

<a id="pin-to-dock"></a>

### Pinning to the Dock

*Keep a Linux app in your Dock, like any Mac app.*

**Pin to Dock**: the pin button on a tile, or the right-click menu - puts the app in your Dock. **Unpin from Dock** takes it out.

Pinning needs a real Mac app to point at, so if the app isn't in your Applications folder yet, MSL [adds it](#add-to-applications) first. Pinning implying "add" is less surprising than refusing.

> [!NOTE]
> **The Dock restarts once**
> macOS has no way for an app to add a Dock tile directly, so MSL updates the Dock's settings and restarts it - once per pin or unpin. You'll see the Dock blink away and come back. That's expected.

Unpinning never starts an instance. Pinned apps work with the MSL window closed.

**Related:** [Adding apps to your Applications folder](#add-to-applications) · [Living with Linux windows](#linux-windows)

<a id="app-sources"></a>

### Where apps come from

*System, User, Flatpak and Snap - and how to tell two copies of one app apart.*

Linux apps can be installed several ways, and MSL finds all of them:

| Source | Installed by | Badge |
|---|---|---|
| **System** | the distro's package manager (`apt`, `apk`, `pacman`, `dnf`) | none - most apps are these |
| **User** | you, for your Linux user only (`~/.local/share/applications`) | User |
| **Flatpak** | `flatpak install` | Flatpak |
| **Snap** | `snap install` | Snap |

Only non-system apps get a badge; on most instances every app is a system one, and a badge on all of them would be noise.

<a id="app-sources--duplicates"></a>

#### The same app twice

Install GIMP from the package manager *and* from Flatpak and you'll see two GIMP tiles - one plain, one badged **Flatpak**. They're genuinely different installs, and each can be added to Applications or pinned separately.

When there's more than one source, a picker appears in the toolbar - **All · System · User · Flatpak · Snap** - to show just one. Typing `flatpak` or `snap` in the search field does the same.

**Related:** [The Applications tab](#apps-tab) · [Your first Linux app](#first-app)

<a id="linux-windows"></a>

### Living with Linux windows

*How Linux app windows behave on a Mac - Dock, menu bar, closing, copy and paste.*

Linux app windows are drawn by [mslgd](#how-it-works--mslgd), MSL's own display server, as real Mac windows. This is the most experimental part of MSL - here's what to expect.

<a id="linux-windows--own-app"></a>

#### Each app is its own Mac app

- **Its own Dock tile**, with its own icon.
- **Its own name** in the menu bar when it's in front.
- **Its own place** in Mission Control and ⌘-Tab.

That works because each Linux app runs in its own small helper process on your Mac: macOS gives exactly one Dock tile per process.

<a id="linux-windows--input"></a>

#### Input

Keyboard, clicking, dragging, the scroll wheel and trackpad scrolling, and middle-click all reach the app.

<a id="linux-windows--closing"></a>

#### Closing

Clicking a window's close button asks the app to close that window, the same as its own close button would on Linux - so an app with unsaved work gets its chance to ask "Save changes?".

<a id="linux-windows--clipboard"></a>

#### Copy and paste

> [!IMPORTANT]
> **Not across apps yet**
> Copy and paste works *within* one Linux app. Between two different Linux apps, or between a Linux app and a Mac app, it doesn't yet - that bridge isn't built. To move text across for now, save it to a file in your home folder (Linux sees it at [/mnt/mac](#home-share)).

<a id="linux-windows--awake"></a>

#### While apps are open

An instance with a Linux app open stays awake - it isn't [suspended for being idle](#idle) while an app is running.

<a id="linux-windows--shutdown"></a>

#### When the Mac shuts down

> [!WARNING]
> **Save Linux work before shutting down**
> When your Mac shuts down, restarts or logs out, MSL asks open Linux apps to close first, so apps with unsaved work can ask to save. Then it saves the instance. But the windows themselves don't come back afterwards - even though the instance resumes, the connection each window had to your Mac is gone. See [Sleep, shutdown and battery](#power-events).

<a id="linux-windows--sandbox"></a>

#### Things that affect windows

- The **Graphics** gate on the [Sandbox tab](#sandbox-gates) stops *new* windows opening; open ones keep drawing.
- The **Keyboard & mouse** gate stops input reaching them; they keep drawing.

> **If an app draws strangely** (´･ω･`)
> Some apps use corners of X11 that mslgd doesn't draw perfectly yet. That's mslgd's fault, not yours, and not the app's. Trying the same app from another source (a Flatpak instead of the package, say) occasionally helps. ( ˘•ω•˘ )

**Related:** [Under the hood](#how-it-works) · [Linux apps won't appear or open](#trouble-apps) · [The four gates](#sandbox-gates) · [Sleep, shutdown and battery](#power-events)

---

<a id="chapter-terminal"></a>

## 5. Terminal & Shells

*A real Linux shell in the app, in Terminal.app, over SSH, or from the msl command.*

<a id="terminal-tab"></a>

### The Terminal tab

*A full terminal inside the window, with a real Linux login shell in it.*

The Terminal tab is a complete terminal with a real Linux shell in it - job control, colours, line editing and full-screen programs like `vim` and `htop` all work, because it's a real terminal talking to a real shell.

<a id="terminal-tab--opening"></a>

#### Opening a shell

Just open the tab. It connects straight away, starting the instance if it isn't running - or click **Terminal** in the header from any tab.

If the instance can't start (every running slot is taken, say), the reason is printed right there in the terminal, where you're already looking.

<a id="terminal-tab--appearance"></a>

#### Appearance

The terminal uses the system's monospaced font and follows light and dark mode with the rest of MSL, rather than being a black rectangle in a light window.

<a id="terminal-tab--toolbar"></a>

#### The toolbar buttons

While the Terminal tab is showing, two buttons appear in the window's toolbar:

- **End Session**: closes the shell. It sends the same hang-up signal a terminal window sends when you close it, so programs inside wind down the way they normally would.
- **Open in Terminal**: opens another shell on the same instance in Terminal.app. See [Using Terminal.app](#terminal-app).

<a id="terminal-tab--ended"></a>

#### When the session ends

Type `exit`, or end the session, and a panel appears over the terminal: "Session ended" (or "Session ended (exit *n*)" if it ended with an error), and a **Reconnect** button. The scrollback stays visible behind it, so anything printed on the way out is still readable.

<a id="terminal-tab--persistent"></a>

#### Sessions keep running

Each instance has its own terminal session, kept alive in the background. Switch tabs, switch instances, come back - the shell is exactly where you left it, scrollback and all. Removing an instance ends its session.

> [!NOTE]
> **An open shell keeps the instance awake**
> While any shell is open on an instance, it isn't [suspended for being idle](#idle). When the last one closes, MSL suspends it a few seconds later.

**Related:** [Using Terminal.app](#terminal-app) · [Linux users and root](#linux-users) · [The msl command](#command-line) · [Idle instances](#idle)

<a id="terminal-app"></a>

### Using Terminal.app

*Open an instance's shell in Terminal.app, or type msl there yourself.*

Prefer Terminal.app, or want several shells side by side? Any of these opens a Terminal.app window running a shell on the instance:

- **Open in Terminal.app** in the instance's right-click menu in the sidebar (or the header's Suspend/Resume menu).
- **Open in Terminal** in the toolbar while the Terminal tab is showing.

> [!NOTE]
> **The first time, macOS asks**
> MSL opens the window by asking Terminal.app to run a command, so the first time macOS asks whether MSL may control Terminal. Allow it. If you said no by accident, turn it back on in **System Settings ▸ Privacy & Security ▸ Automation**.

<a id="terminal-app--typing"></a>

#### Or just type it

In any terminal app - Terminal, iTerm, whatever you use - this opens a shell on an instance called `work`:

```sh
msl work
```

Every new tab can do the same; each is its own shell. And one-off commands work like `ssh`:

```sh
msl work uname -a
msl work ls -la /mnt/mac/Desktop
```

The exit code comes back too, so `msl` fits in scripts. Everything else it can do is in [The msl command](#command-line).

**Related:** [The msl command](#command-line) · [The Terminal tab](#terminal-tab) · [Connecting over SSH](#ssh)

<a id="linux-users"></a>

### Linux users and root

*Your everyday Linux user, sudo and its password, root, and the extra 'msl' user.*

<a id="linux-users--default"></a>

#### Your default user

The first interactive shell on a distro asks you to create a user - see [Your first start](#first-start--user). That user becomes the **default login for the distro**: every shell, in the app or out of it, logs in as them.

It belongs to the distro, not the instance, because instances of a distro share one disk. Set it up once on any Debian instance, and every Debian instance has it.

<a id="linux-users--sudo"></a>

#### sudo

Your account is an administrator, the usual Linux way: it's in the distro's admin group - `sudo` on Debian, Ubuntu, Kali and Nix, `wheel` on the rest - and `sudo` asks for **its password**:

```sh
sudo apt install gimp
[sudo] password for abi:
```

After that, `sudo` remembers you for a few minutes, so a run of commands only asks once.

<a id="linux-users--root"></a>

#### Root

From the Mac, `-u` picks the user - and `-u root` needs no password, because the Mac is the machine's owner. It's the same escape hatch WSL has with `wsl -u root`:

```sh
msl work -u root
msl work -u root apk add htop
```

<a id="linux-users--forgot-password"></a>

#### Forgot your password?

Set a new one as root, from the Mac:

```sh
msl work -u root passwd abi
```

Replace `abi` with your username. It asks for the new password twice.

<a id="linux-users--one-off"></a>

#### One-off commands

`msl work <command>` runs as the default user too, once there is one - before that, as root.

<a id="linux-users--msl-user"></a>

#### The msl user

Every distro also has an ordinary unprivileged user called `msl`, for when you want a clean account with no admin rights: `msl work -u msl`.

**Related:** [Your first start and your Linux user](#first-start) · [The msl command](#command-line) · [Connecting over SSH](#ssh)

<a id="ssh"></a>

### Connecting over SSH

*One command, nothing to configure - for scp, VS Code Remote-SSH, and anything else that speaks SSH.*

The **Connect over SSH** card on the Overview tab gives every instance a ready-made SSH shortcut. MSL does all the setup; you get one command:

```sh
ssh msl-work
```

It works anywhere SSH does - a terminal, `scp`, `rsync`, and editors like VS Code's Remote-SSH, which will list `msl-work` as a host.

<a id="ssh--what"></a>

#### What MSL sets up

1. **Its own key**, at `~/Library/Application Support/MSL/ssh/msl_ed25519`. MSL never touches your personal `~/.ssh` keys - a key MSL owns can be replaced without affecting anything else you use.
2. **The key inside Linux**, for your Linux account - so `ssh` logs you in as you. (Before the distro has an account, it uses the built-in `msl` one; **Set up again** switches it once yours exists.)
3. **The SSH server inside Linux**, started.
4. **A shortcut**: a `Host msl-work` entry in `~/.ssh/config`. Nothing else in that file is touched.

Then it checks the address actually answers before calling it ready.

<a id="ssh--automatic"></a>

#### Automatically

**Set this up automatically when an instance starts** (on by default, and it applies to all instances) does all of the above whenever an instance starts, so the shortcut is just there. Turn it off and each card offers **Set up now** instead, which works while the instance is running.

<a id="ssh--card"></a>

#### Reading the card

| You see | Means |
|---|---|
| "Not set up yet" | Nothing's been done. **Set up now** needs the instance running. |
| "Setting up…" | Working on it. |
| Green tick, "Ready." | Checked just now and answering. **Open Terminal** connects in Terminal.app. |
| Grey clock, "Last known details…" | From the last time it ran - it's checked again once the instance is up. |
| Orange triangle, "isn't answering on port 22" | Set up, but not reachable right now. |

Under the command: the **Address** (user and IP), the **Key** path, and the **Host key** fingerprint. **Copy** copies the command; **Copy all details** copies everything; **Set up again** redoes it all.

> [!NOTE]
> **Addresses move; the shortcut follows**
> An instance's address can change between runs. MSL rechecks it at start and rewrites the `~/.ssh/config` entry in place, so `ssh msl-work` keeps working.

> [!TIP]
> **Not answering?**
> The usual reason is the **Network** gate on the Sandbox tab - cutting it unplugs the network SSH uses. The app's own terminal still works regardless. More in [SSH won't connect](#trouble-ssh).

From the command line, `msl ssh work` connects - setting everything up first if it's the first time - and `msl ssh work --print` just prints the command.

**Related:** [SSH won't connect](#trouble-ssh) · [The four gates](#sandbox-gates) · [Using Terminal.app](#terminal-app)

<a id="command-line"></a>

### The msl command

*Everything the app does, from any terminal - and a few things it doesn't.*

The app and the `msl` command are two faces of the same thing: both ask MSL's background service to do the work. Anything you do in one shows up in the other. The full list is in the reference - [msl command reference](#msl-command) - but these are the ones you'll use:

| Command | Does |
|---|---|
| `msl work` | A shell on `work`. |
| `msl work <command>` | Runs one command, like `ssh`. Its exit code comes back. |
| `msl fedora` | An instance named after a distro just works - no setup needed. |
| `msl work -u root` | A shell as root. |
| `msl list` | Every instance. |
| `msl status work` | Running, suspended or stopped. |
| `msl suspend work` / `msl resume work` | Freeze and unfreeze. |
| `msl hibernate work` | Save to disk and stop. |
| `msl --shutdown work` | Shut Linux down properly. With no name, every running instance. |
| `msl install debian` | Download a distro. |
| `msl ssh work` | Connect over SSH, setting it up if needed. |
| `msl doctor` | Check the installation for problems. See [Logs and msl doctor](#logs-and-doctor). |

> [!TIP]
> **Typos are caught**
> `msl lsit` doesn't quietly create an instance called "lsit" - it says "no instance named 'lsit' - did you mean `msl list`?" To really make an instance with an odd name, use `msl new <name>`.

Run `msl help` for the complete usage.

**Related:** [Using Terminal.app](#terminal-app) · [msl command reference](#msl-command) · [Logs and msl doctor](#logs-and-doctor)

---

<a id="chapter-overview"></a>

## 6. Overview Tab

*CPUs, memory, disk, the shared home folder - what each instance is made of.*

<a id="overview-tab"></a>

### The Overview tab

*Six cards describing and configuring one instance.*

The Overview tab is a stack of cards, top to bottom:

| Card | What's on it | More |
|---|---|---|
| **Instance** | Name, distribution and current state. | - |
| **Connect over SSH** | A ready-made `ssh` command for this instance, and its details. | [SSH](#ssh) |
| **Processor & memory** | How many virtual CPUs, and how much memory - fixed or dynamic. | [CPUs](#processors), [Memory](#memory) |
| **Storage** | How full the disk is, how big it may get, and what it really costs on your Mac. | [Storage](#storage) |
| **Shared with macOS** | Where your Mac home folder appears inside Linux. | [Home folder](#home-share) |
| **Concurrency** | How many instances are running out of the most MSL allows. | [Concurrency](#concurrency) |

> [!IMPORTANT]
> **Most settings apply at the next start**
> A virtual machine's CPUs, memory and disk size are fixed when it boots. Change them while an instance is running and MSL saves the change for its next start - each card says so in its footnote.

**Related:** [Virtual CPUs](#processors) · [Memory: manual mode](#memory) · [Disk size and storage](#storage)

<a id="processors"></a>

### Virtual CPUs

*How many processors an instance gets, and why it's fine to be generous.*

The **Virtual CPUs** row at the top of the **Processor & memory** card sets how many processors Linux sees. Use the stepper arrows; the number beside them is the current value.

<a id="processors--how-many"></a>

#### How many to choose

The stepper goes from 1 up to this Mac's number of logical cores - the caption under it tells you how many that is.

If you've never changed it, an instance gets **half of your Mac's cores, but at least 2 and never more than 8**. That's a good default for almost everything; compiling large projects is the main reason to go higher.

> [!TIP]
> **CPUs are shared, not reserved**
> As the caption says: vCPUs are time-shared, not reserved. An instance with 8 vCPUs that's sitting idle costs your Mac nothing, and several instances can each have several. Unlike memory, being generous here doesn't take anything away from macOS until Linux is actually busy.

<a id="processors--apply"></a>

#### Applying it

Click **Apply** at the bottom of the card. The change takes effect the next time the instance starts; a green **Saved** confirms it. **Revert** puts back what was saved.

> [!WARNING]
> **A hibernated session is discarded**
> If the instance was hibernated, its saved session can't be resumed into a machine of a different size, so it's discarded and the instance starts fresh. Save your work inside Linux first.

**Related:** [Memory: manual mode](#memory) · [How many can run at once](#concurrency)

<a id="memory"></a>

### Memory: manual mode

*A fixed amount of memory, and why MSL warns above three fifths of your Mac's RAM.*

The **Memory** picker on the **Processor & memory** card has two modes: **Manual** and **Dynamic**. This page is about Manual; [Dynamic](#memory-dynamic) has its own.

**Manual** is a fixed amount, reserved on your Mac the whole time the instance is running. Type a number of megabytes in the **Memory** field and click **Apply**.

| Megabytes | Is |
|---|---|
| 1024 | 1 GB |
| 2048 | 2 GB |
| 4096 | 4 GB |
| 8192 | 8 GB |

If you've never changed it, an instance gets **a sixth of your Mac's memory, at least 1 GB and at most 8 GB** - enough for desktop apps, and small enough that four instances together can't crowd macOS out.

<a id="memory--warnings"></a>

#### The warnings

MSL checks the number as you type and explains anything worrying in a coloured box under it.

> [!WARNING]
> **Orange: more than three fifths of your Mac's memory**
> A virtual machine's memory is *wired down* - macOS can't compress it or page it out to make room for anything else. Give an instance more than three fifths of your Mac and macOS is left with the rest for itself and everything you're running. Expect heavy paging, beachballs, and possibly an unstable machine. MSL still lets you - the box says "It will still start."

> [!CAUTION]
> **Red: numbers that can't work**
> Too small for the Virtualization framework to start a VM, more than it allows for one VM, or more than your Mac has in total. **Apply** stays greyed out until the number is possible.

Pressing Return in the field also snaps a value that's out of range back to the nearest allowed one.

<a id="memory--when"></a>

#### When it takes effect

At the instance's next start. A running instance keeps the memory it booted with; a hibernated session is discarded rather than resumed into a differently sized machine.

**Related:** [Memory: dynamic mode](#memory-dynamic) · [Virtual CPUs](#processors) · [Memory trouble](#trouble-memory)

<a id="memory-dynamic"></a>

### Memory: dynamic mode

*Start at a maximum and hand back whatever Linux isn't using, continuously.*

**Dynamic** memory gives an instance a **Minimum** and a **Maximum**. It starts with the maximum, and MSL keeps watching how much Linux actually needs, handing back what it isn't using and letting it have more again as it needs it - never above the maximum, never below the minimum.

<a id="memory-dynamic--numbers"></a>

#### Choosing the numbers

- **Maximum** is what your Mac sets aside when the instance starts, and the most it can ever have.
- **Minimum** is as far down as MSL will ever squeeze it.

The same [warnings as manual mode](#memory--warnings) apply to the maximum, and the minimum can't be larger than the maximum.

> [!IMPORTANT]
> **It can only give back, never grow past the maximum**
> The Virtualization framework fixes a VM's size when it boots. Dynamic memory works by letting Linux return memory it isn't using - a *balloon* inside the guest that inflates to hand memory back to your Mac and deflates to give it back to Linux. The balloon moves *within* the maximum; nothing can take an instance above it. So set the maximum to the most you'd ever want it to have.

<a id="memory-dynamic--how"></a>

#### How MSL decides

Rather than guessing from one number, MSL looks at how much memory Linux is really using, how much it could free if it had to, and - most tellingly - whether programs inside are **stalling** while they wait for memory. It gives memory back gently when there's plenty spare, and returns it quickly the moment Linux starts to struggle. Linux images don't use swap, so MSL never squeezes an instance below what its programs are actually holding.

<a id="memory-dynamic--live"></a>

#### The live readout

While a dynamic instance is running, the bottom of the card updates every few seconds:

| Row | Meaning |
|---|---|
| **Allocated right now** | What Linux currently has from your Mac. |
| **Guest is using** | What its programs are really using, out of what it can see. |
| **Guest stalling on memory** | The share of time programs spend waiting for memory. Only shown when it isn't zero. |
| **Last change** | Why MSL last moved the number, in words. |
| **Adjustments this session** | How many times it has moved since the instance started. |

If the guest has swap turned on, a note says so: MSL still sizes it conservatively, but swap changes what running out of memory feels like.

<a id="memory-dynamic--when"></a>

#### When it takes effect

Switching between Manual and Dynamic, or changing the numbers, applies at the next start - like every memory change.

**Related:** [Memory: manual mode](#memory) · [What's ready, what's experimental](#whats-ready) · [Memory trouble](#trouble-memory)

<a id="storage"></a>

### Disk size and storage

*How full the disk is, how big it may get, dynamic versus fixed, and automatic growth.*

The **Storage** card on the Overview tab shows how full an instance's disk is and sets how big it may get.

> [!IMPORTANT]
> **Storage belongs to the distro**
> Every instance of a distro shares one disk, so this card is really about that distro's disk. Resize it from `work` and `scratch` (the same distro) gets the bigger disk too.

<a id="storage--reading"></a>

#### Reading the card

- **The usage bar**: "*X* used inside *name*" and "*N*% of *total*", with when it was last measured. The bar turns **orange** once the disk is 85% full. Until the instance has run once, it says "Start this instance once and MSL will measure how full it is."
- **Guest disk size**: how big Linux thinks its disk is.
- **Actually used on your Mac**: what the image file really takes on your Mac right now. For a dynamic disk this is usually far smaller than the disk size; a fixed disk adds "(reserved)".

<a id="storage--modes"></a>

#### Dynamic or fixed

|  | **Dynamic** (the default) | **Fixed** |
|---|---|---|
| On your Mac | Takes only the space Linux has actually written. | Reserves the whole size up front. |
| The slider sets | the **Limit** | the **Size** |
| Good for | Almost everyone. | Making sure the space is there, however full your Mac gets. |

A new disk is dynamic, with a 64 GB limit.

> [!WARNING]
> **Switching to fixed takes a while**
> Reserving space means writing out the whole disk - "Reserving space on your Mac… this writes the whole disk, so it can take a while." For a large disk that can be minutes. The card stays usable; the rest of the app does too.

<a id="storage--bigger"></a>

#### Making it bigger

Drag the slider (4 GB to 512 GB, in steps of 4) and let go. If the instance is stopped, the image grows right away; if it's running, the change waits for its next start. Either way, Linux's filesystem is stretched to fill the new size during the next start, and until then the card says "The guest filesystem is extended the next time this instance starts."

> [!CAUTION]
> **Disks only grow**
> A disk can be made bigger but never smaller. Drag below its current size and the card says so and puts the slider back.

<a id="storage--auto-grow"></a>

#### Growing automatically

With a dynamic disk, **Grow automatically when it runs low** (on by default) looks after a disk that's smaller than its limit: whenever the instance starts with its disk at least 85% full, MSL grows it by 8 GB, up to the limit. When it's already at the limit, nothing grows and the log notes it.

<a id="storage--free-space"></a>

#### Your Mac's free space

The footnote shows how much space is free on your Mac. A dynamic disk can't grow past what your Mac has room for, so keep an eye on both. See [The disk is full](#trouble-disk).

**Related:** [Reclaiming disk space](#reclaim-space) · [The disk is full](#trouble-disk) · [Shared disks](#shared-disks)

<a id="home-share"></a>

### Your home folder inside Linux

*Your Mac home folder appears at /mnt/mac in every running instance.*

Every running instance can see your Mac home folder at `/mnt/mac`. The **Shared with macOS** card on the Overview tab shows both ends:

|  |  |
|---|---|
| **Home folder** (inside Linux) | `/mnt/mac` |
| **Host path** (on your Mac) | your home folder, e.g. `/Users/you` |

So `~/Documents/report.txt` on your Mac is `/mnt/mac/Documents/report.txt` in Linux. Changes on either side show up on the other straight away - it's the same file, not a copy.

```sh
cd /mnt/mac/Desktop
ls
```

<a id="home-share--scope"></a>

#### Only your home folder

Folders outside your home - `/Applications`, other drives, `/usr/local` - aren't visible inside Linux. That's why [MSL Files](#files-open-in-msl) greys out **Open Folder in MSL** for them.

<a id="home-share--off"></a>

#### Turning it off

The **Mac home share** gate on the [Sandbox](#sandbox-gates) tab revokes it for one instance: `/mnt/mac` stops resolving. Anything in the middle of reading a file there sees I/O errors rather than a clean unmount, so close things first.

> [!TIP]
> **The other direction**
> To reach Linux's files from your Mac, use [MSL Files](#files-window) (⌥⌘F).

**Related:** [The MSL Files window](#files-window) · [The four gates](#sandbox-gates) · [Opening a folder in a Linux shell](#files-open-in-msl)

<a id="concurrency"></a>

### How many can run at once

*MSL runs at most four instances together, and why suspended ones count.*

MSL runs **at most four instances at once**. The **Concurrency** card on the Overview tab shows "Running now: *n* of 4", and the capacity pill at the top of the sidebar shows the same, turning orange when all four are in use.

<a id="concurrency--why"></a>

#### Why there's a limit

Every running or suspended instance keeps its memory on your Mac, and virtual machine memory can't be paged out. Without a limit, it would be easy to start enough instances to leave macOS gasping. The default memory size is chosen so that four instances together stay well within your Mac.

<a id="concurrency--what-counts"></a>

#### What counts

| State | Uses a slot? |
|---|---|
| Running | Yes |
| Suspended | Yes - it's frozen, but its memory is still held. |
| Hibernated or stopped | No |

<a id="concurrency--full"></a>

#### When it's full

**Start** is greyed out on stopped instances, and trying anyway says "4 instances are already running … Suspend or shut one down first." Things that would start an instance - **Find Apps**, a sharper icon for a Dock tile - say the same, or quietly fall back (an app added while the slots are full keeps its existing icon).

To free a slot, **hibernate** or **shut down** something. Suspending doesn't free one. See [Suspend, hibernate or shut down?](#stopping-instances).

**Related:** [Shared disks](#shared-disks) · [Suspend, hibernate or shut down?](#stopping-instances) · [An instance won't start](#trouble-wont-start)

---

<a id="chapter-tools"></a>

## 7. Tools Tab

*The background service, snapshots, stopping and removing, and disk check and repair.*

<a id="tools-tab"></a>

### The Tools tab

*Five cards for looking after an instance.*

| Card | What's on it | More |
|---|---|---|
| **Background service** | Whether MSL's service is running, and whether it starts at login. | [The background service](#background-service) |
| **Generated applications** | Where the Mac apps made for this instance live. | [Generated apps](#generated-apps) |
| **Snapshots** | Saved machine states, to go back to. | [Snapshots](#snapshots) |
| **Maintenance** | Disk check and repair, maintenance boot, and fix-it utilities. | [Maintenance](#maintenance) |
| **Instance** | Suspend, Hibernate, Shut Down, Remove…. | [Stopping](#stopping-instances), [Removing](#removing-instances) |

**Related:** [The Maintenance card](#maintenance) · [Snapshots](#snapshots) · [Suspend, hibernate or shut down?](#stopping-instances)

<a id="background-service"></a>

### The background service

*mslhd runs every instance. What it is, how it starts, and what to do when it isn't running.*

`mslhd` is MSL's background service. It runs every instance - the app, the `msl` command and the Linux apps in your Dock are all just ways of asking it to do things. Without it running, nothing can start.

<a id="background-service--card"></a>

#### The card

The **Background service** card at the top of the Tools tab:

- **Start MSL's service automatically**: whether it starts when you log in (as a login item, at `~/Library/LaunchAgents/com.msl.mslhd.plist`). On by default.
- **Status**: Running or Not running.
- **Log**: `~/Library/Logs/MSL/mslhd.log`, where it writes what it's doing.

> [!NOTE]
> **Turning it off sticks**
> MSL normally re-installs the login item every time the app opens, so it can repair itself. Switching it off here is remembered, so the app won't quietly turn it back on.

> [!WARNING]
> **Linux apps in your Dock need it**
> With the service off, Linux apps you've added to Applications or pinned to the Dock can't start either, because it's the service that runs them.

<a id="background-service--not-running"></a>

#### When it isn't running

With no instance selected, the main window says "MSL's background service isn't running" and offers **Start it**. If it keeps stopping, the log says why - see [The service isn't running](#trouble-service).

<a id="background-service--updates"></a>

#### After updating MSL

Updating the app installs the new service, but the one already running carries on until it next starts - at your next login. Until then, newer features that need it (like the [Maintenance](#maintenance) card) may say the service is "an older version". Logging out and back in sorts it.

**Related:** [The service isn't running](#trouble-service) · [Logs and msl doctor](#logs-and-doctor) · [Under the hood](#how-it-works)

<a id="generated-apps"></a>

### Generated apps

*Where the Mac apps made for an instance's Linux programs live.*

Every Linux app you [add to Applications](#add-to-applications) or [pin to the Dock](#pin-to-dock) becomes a small Mac app in `~/Applications/MSL/<instance>/`. The **Generated applications** card shows where:

- **Location**: that instance's folder.
- **Show in Finder**: opens it.
- **Open Logs**: opens `~/Library/Logs/MSL`. A Mac app started from the Dock has no terminal to report problems in, so it writes them here instead.

They're ordinary Mac apps: deleting one in Finder is exactly the same as **Remove from Applications**.

**Related:** [Adding apps to your Applications folder](#add-to-applications) · [Pinning to the Dock](#pin-to-dock) · [Removing an instance](#removing-instances)

<a id="snapshots"></a>

### Snapshots

*Save a machine's state under a name and go back to it - and the one rule that keeps it safe.*

A snapshot saves a machine's state - everything in its memory, every running program - under a name, so you can return to that exact moment.

<a id="snapshots--saving"></a>

#### Saving one

1. The instance has to be running or suspended - a stopped one has no memory to save. (The card says "Start *name* to take a snapshot.")
2. Type a name in **New snapshot name** - letters, digits, hyphens and underscores, like `before-upgrade`.
3. Click **Save** (or press Return).

> [!IMPORTANT]
> **Saving stops the instance**
> Saving pauses the machine, writes its memory to a file, and then **stops** it. That's deliberate - a saved state is only reliable if the machine it came from doesn't carry on running. Start it again afterwards if you want to keep working.

<a id="snapshots--restoring"></a>

#### Restoring one

Click **Restore** beside it. Whatever the instance is doing is replaced - it stops if it was running - and it comes back exactly as it was when you saved. As the card says: restoring discards everything since.

<a id="snapshots--disk"></a>

#### The rule that keeps it safe

> [!WARNING]
> **A snapshot doesn't copy the disk**
> A snapshot holds the machine's memory and running state. It does *not* keep a separate copy of the disk - the disk is the distro's shared disk, and it carries on changing when anything runs on it.
>
> If the disk changes after you save - you start the instance again, or use another instance of the same distro - then restoring puts back a memory that remembers a different disk. Linux can get confused about its own files, which can damage the filesystem.
>
> **Restore is only safe if nothing has run on that distro since the snapshot was saved.** If you've restored anyway and things seem odd, [check the disk](#disk-check).

For "undo" after changing files, a copy of those files is often the better tool. For the disk as a whole, [Repair Disk](#disk-repair) keeps a real copy of the disk before it changes anything.

<a id="snapshots--where"></a>

#### Where they live

Each snapshot is a file in `~/Library/Application Support/MSL`, named `vm-<instance>-<snapshot>.state`, about the size of the instance's memory. There's no delete button yet; removing the instance deletes all of its snapshots. See [Reclaiming disk space](#reclaim-space).

**Related:** [Suspend, hibernate or shut down?](#stopping-instances) · [Repairing a disk](#disk-repair) · [Reclaiming disk space](#reclaim-space)

<a id="stopping-instances"></a>

### Suspend, hibernate or shut down?

*Three ways to stop an instance, what each costs, and which to use.*

The **Instance** card at the bottom of the Tools tab has **Suspend**, **Hibernate** and **Shut Down**. The header and the sidebar's right-click menu have some of them too.

|  | **Suspend** | **Hibernate** | **Shut Down** |
|---|---|---|---|
| What happens | Frozen, kept in memory. | Memory written to a file, then stopped. | Stopped at once. |
| Coming back | Almost instantly, exactly where it was. | A few seconds, exactly where it was. | A fresh start of Linux. |
| Holds memory on your Mac | Yes | No | No |
| Uses one of the four slots | Yes | No | No |
| Disk space on your Mac | None | A file about the size of its memory | None |
| Available when | Running | Running or suspended | Running or suspended |

<a id="stopping-instances--suspend"></a>

#### Suspend

For a short break. Nothing is saved to disk, so it's instant both ways - but the instance keeps its memory and its [slot](#concurrency). MSL also suspends instances by itself when they're [idle](#idle).

<a id="stopping-instances--hibernate"></a>

#### Hibernate

For a longer break. The machine's whole memory is written to your Mac's disk and the instance stops, giving back its memory and its slot. **Start** brings it back exactly as it was - shells, programs and all. Saving takes longer the more memory the instance has.

This is also what MSL does to every running instance when your Mac shuts down, restarts or logs out. See [Sleep, shutdown and battery](#power-events).

<a id="stopping-instances--shut-down"></a>

#### Shut Down

> [!WARNING]
> **Shut Down stops it straight away**
> **Shut Down** in the app stops the virtual machine immediately - like holding down a computer's power button. Linux doesn't get the chance to finish writing to its disk first. Its filesystem recovers on the next start, but anything that hadn't been written yet is lost, and stopping a machine this way over and over is how disks get damaged.
>
> To shut Linux down properly, do one of these instead:
>
> • Run `sudo poweroff` in the instance's Terminal tab, and let it stop by itself.
>
> • Or, in Terminal.app, run `msl --shutdown work` - it asks Linux to power off first, then stops the machine.
>
> • Or **Hibernate**, which loses nothing at all.

Shutting down also throws away a hibernated session, if there was one: after a power-off, the saved memory no longer matches the disk.

<a id="stopping-instances--which"></a>

#### Which one?

- Back in a minute → **Suspend**, or just leave it - idle instances suspend themselves.
- Done for the day, want the memory back → **Hibernate**.
- Want a clean start of Linux → `sudo poweroff` inside it, then **Start**.

**Related:** [Sleep, shutdown and battery](#power-events) · [Idle instances](#idle) · [How many can run at once](#concurrency) · [Snapshots](#snapshots)

<a id="removing-instances"></a>

### Removing an instance

*What Remove deletes, what it keeps, and why it doesn't ask first.*

**Remove…** is in the instance's right-click menu, the header's menu, and the Instance card on the Tools tab.

> [!CAUTION]
> **It happens straight away**
> Remove doesn't ask for confirmation, despite the "…" on its name. Click it only when you mean it.

<a id="removing-instances--deleted"></a>

#### What's deleted

- The instance itself - its name disappears from the sidebar.
- Its hibernated session, if it had one.
- **All of its snapshots.**
- Every Mac app made for it in `~/Applications/MSL/<instance>`, and its cached list of apps.
- Its terminal session in the app.

If it was running, it's stopped first.

<a id="removing-instances--kept"></a>

#### What's kept

> [!IMPORTANT]
> **Your files are on the distro's disk, not the instance**
> Removing an instance never touches the distro's disk image - the files inside Linux stay, and every other instance of that distro carries on as before. Create a new instance of the same distro and your files are all still there.

To really delete a distro's files and free the space, see [Reclaiming disk space](#reclaim-space).

**Related:** [Reclaiming disk space](#reclaim-space) · [Shared disks](#shared-disks) · [Generated apps](#generated-apps)

<a id="uninstalling-msl"></a>

### Uninstalling MSL

*Remove MSL and keep every instance and image - or remove all of it.*

**Permissions & Startup ▸ Uninstall**, or `msl uninstall` in a terminal. Both run the same thing: the app shows you the list and then hands the job to the command in a Terminal window, because MSL can't delete itself while it's the one doing the deleting.

> [!IMPORTANT]
> **Your Linux is kept by default**
> Uninstalling removes MSL, not the Linux you installed with it. Every instance, disk image, custom image, account and setting stays in `~/Library/Application Support/MSL`. Install MSL again and it all comes back exactly as it was.

<a id="uninstalling-msl--removed"></a>

#### What goes

- MSL.app itself.
- The background service and the login items, stopped first.
- The Mac apps made for your Linux apps, in `~/Applications/MSL`.
- MSL's caches, logs and saved window state.
- The `msl`, `mslhd`, `mslgui` and `msl-applauncher` programs.

Running instances are shut down properly first - not hibernated, because a saved session with no MSL to restore it is worse than a clean power-off. Anything mounted in Finder is unmounted before that.

<a id="uninstalling-msl--kept"></a>

#### What stays

- Every distro disk image, and everything inside it.
- Your instances, the accounts you made, and each instance's storage settings.
- Your custom images, in `Custom Images`.
- MSL's own settings, so a reinstall doesn't switch something back on that you switched off.

<a id="uninstalling-msl--upgrading"></a>

#### Upgrading is not uninstalling

To move to a newer MSL, just install it over the old one. The app and your Linux live in different places, so nothing is lost and there is no uninstall step. See [The background service](#background-service) for why MSL restarts it after an update.

<a id="uninstalling-msl--everything"></a>

#### Removing all of it

`msl uninstall --everything`, or the checkbox in the sheet, deletes the Linux side too - every image, instance and setting. It asks you to type a word first, the same one [Removing an instance](#removing-instances) uses, because nothing here comes back.

`msl uninstall --dry-run` prints both lists and changes nothing.

**Related:** [The background service](#background-service) · [Generated apps](#generated-apps) · [Removing an instance](#removing-instances)

<a id="maintenance"></a>

### The Maintenance card

*Disk check and repair, a maintenance boot, and fix-it utilities - organised by when they can run.*

The **Maintenance** card on the Tools tab collects tools for keeping an instance healthy. It's laid out by *when* each one can run, because that decides whether a button can work at all:

- **Disk**: Check and repair the Linux filesystem from your Mac. The instance must be shut down.
- **Maintenance Boot**: Start Linux in a minimal mode and check its disk with Linux's own tools.
- **While It's Running**: Four fix-it utilities that run inside a running instance.

> [!NOTE]
> **Nothing changes without asking**
> As the card's footnote says: nothing here changes a disk without asking first, and every repair keeps a copy of the disk from before it.

<a id="maintenance--reasons"></a>

#### Greyed-out buttons explain themselves

A disabled button always has a line saying why, rather than just going grey:

| You see | Why |
|---|---|
| "Shut the instance down first - a disk that's in use can't be checked safely." | Disk tools need it stopped. |
| "This instance has a hibernated session…" | Its saved memory and disk are a pair. Start it, then shut it down, before maintenance. |
| "Maintenance is already running on this disk." | One job at a time per disk. |
| "e2fsck isn't installed…" with **Copy Install Command** | The Mac-side check needs a free tool. See [Checking a disk](#disk-check--e2fsprogs). |
| "Start the instance to use these." | The utilities run inside Linux. |

<a id="maintenance--results"></a>

#### Results

When a tool finishes, a coloured box appears at the bottom of the card:

| Colour | Means |
|---|---|
| Green | Healthy, or done. |
| Orange | Something needs your attention. |
| Red | It couldn't do what it was asked. |
| Blue | For your information. |

**Show details** opens the tool's full output; the × dismisses the box.

> [!IMPORTANT]
> **Instances that share the disk wait**
> While a disk tool is working, no instance using that distro's disk can start - they all share it.

**Related:** [Checking a disk](#disk-check) · [Repairing a disk](#disk-repair) · [Utilities for a running instance](#guest-utilities) · [Maintenance boot](#maintenance-boot)

<a id="disk-check"></a>

### Checking a disk

*Check Disk reads the Linux filesystem from your Mac, without changing anything.*

**Check Disk** in the Maintenance card's **Disk** section examines the instance's Linux filesystem from your Mac and reports what it finds. It never changes anything.

<a id="disk-check--before"></a>

#### Before you start

- **Shut the instance down.** Checking a disk while Linux is using it gives meaningless answers - it's only safe when nothing has it open.
- **No hibernated session.** If the instance is hibernated, start it and shut it down first.
- **Install e2fsprogs on your Mac** (see below).

<a id="disk-check--e2fsprogs"></a>

#### Installing e2fsprogs

Linux disks are checked with a tool called `e2fsck`. macOS doesn't come with it, but it's free through [Homebrew](https://brew.sh). Until it's installed, the card says so and offers **Copy Install Command**, which copies this:

```sh
brew install e2fsprogs
```

Paste it into Terminal. MSL finds it where Homebrew puts it - no other setup needed.

> [!TIP]
> **No Homebrew?**
> The [maintenance boot](#maintenance-boot) checks the disk with Linux's own copy of the tool, so it doesn't need anything on your Mac.

<a id="disk-check--results"></a>

#### What the results mean

| Result | Colour | Means |
|---|---|---|
| **No problems found** | green | The filesystem is consistent. |
| **Problems found** | orange | "Nothing was changed. Run Repair to fix them - a backup of the disk is taken first." |
| **The check didn't run** | red | Something stopped the check itself, and the result "says nothing about the disk". The reason follows. |

**Show details** has e2fsck's own output.

A big disk can take a few minutes - "Checking the disk… a large disk can take a few minutes."

**Related:** [Repairing a disk](#disk-repair) · [Checking the disk at every start](#check-at-start) · [Filesystem errors](#trouble-filesystem)

<a id="disk-repair"></a>

### Repairing a disk

*Repair Disk fixes the filesystem - after taking an instant, free backup you can go back to.*

**Repair Disk…** fixes whatever the filesystem check finds. It asks first - "Repair this instance's disk?" - and explains what happens next.

<a id="disk-repair--what"></a>

#### What it does

1. **Takes a backup.** An instant copy of the whole disk, made with an APFS clone: it appears immediately and costs no space on your Mac until the disk starts to differ from it.
2. **Repairs.** `e2fsck` fixes everything it can.
3. **Reports** what happened.

The same prerequisites as [Checking a disk](#disk-check--before) apply: shut down, no hibernated session, e2fsprogs installed.

> [!IMPORTANT]
> **No backup, no repair**
> If MSL can't make the clone - the disk isn't on an APFS volume, or the backup would have to be copied to another volume - it refuses to repair rather than risk the disk without a way back.

<a id="disk-repair--results"></a>

#### Results

| Result | Means |
|---|---|
| **Problems found and fixed** | Done. The backup is kept until you discard it. |
| **Problems fixed** | Fixed, and e2fsck wants a restart before the disk is used - starting the instance now *is* that restart. |
| **Some problems couldn't be fixed** | It fixed what it safely could. What's left needs a closer look; the backup is kept. |
| **The check didn't run** | Nothing was repaired. The reason follows. |

<a id="disk-repair--backup"></a>

#### The backup

After a repair, the Disk section shows "A copy of the disk from before the last repair is kept." with two buttons:

- **Restore…**: puts the old disk back. It asks first: "Put the old disk back?" - anything written to the disk since that repair is lost.
- **Discard**: deletes the backup. Do this once you're happy the repaired disk is fine.

The backup sits beside the disk image, with `.pre-repair` on the end of its name. If one already exists when you repair again, MSL keeps the existing one instead of replacing it - so it's always from before the first repair since you last discarded.

> [!TIP]
> **Discard when you're sure**
> The clone is free at first but grows as the repaired disk changes, up to the size of the whole disk. Once the instance has been working happily for a while, discard it.

**Related:** [Checking a disk](#disk-check) · [Filesystem errors](#trouble-filesystem) · [Maintenance boot](#maintenance-boot)

<a id="check-at-start"></a>

### Checking the disk at every start

*An optional full check before each start, which refuses to boot a damaged disk.*

**Check the disk every time this instance starts**: a switch in the Maintenance card's Disk section. **Off by default.**

When it's on, every start first runs a full check of the disk from your Mac. If the disk is clean, the instance starts as usual. If it isn't, MSL **refuses to start it** rather than risk making things worse, with a message that begins "didn't start: the filesystem check at start found a problem". Then [repair it](#disk-repair).

- It needs e2fsprogs on your Mac. If you turn it on and later remove e2fsprogs, starts are refused until you reinstall it or turn the switch off - the message says which.
- It adds the length of a full check to every start. On a big disk that's noticeable.
- Resuming a hibernated session skips the check: the saved memory and the disk have to match exactly, and a check can't change that.
- It's set per instance.

**Related:** [Checking a disk](#disk-check) · [An instance won't start](#trouble-wont-start)

<a id="maintenance-boot"></a>

### Maintenance boot

*Start Linux in a minimal mode and check or repair its disk with Linux's own tools.*

**Check from Linux** and **Repair from Linux…** start the instance in a minimal maintenance mode: the disk read-only, nothing else running. Linux checks (or repairs) its own disk with its own tools, reports back, and shuts itself down.

It's useful when your Mac doesn't have e2fsprogs, and it's a second opinion from Linux itself.

<a id="maintenance-boot--repair"></a>

#### Repairing

**Repair from Linux…** asks first, then takes the same instant backup as [Repair Disk](#disk-repair--backup) before starting Linux. The backup appears in the Disk section afterwards, with Restore… and Discard.

<a id="maintenance-boot--results"></a>

#### What you might see

| Result | Means |
|---|---|
| The usual check or repair results | It ran; the same meanings as [Checking a disk](#disk-check--results). |
| **Maintenance boot couldn't start** (red) | Linux stopped before the tools could run - often because the disk is too damaged to start from. If e2fsprogs is on your Mac, Check Disk looks at it without starting it. |
| **No result from the maintenance boot** (red) | It didn't report back within the time limit and was stopped. If this was a repair, check the disk before relying on it. |

The same prerequisites apply as for the Mac-side tools: shut down, no hibernated session.

**Related:** [Checking a disk](#disk-check) · [Repairing a disk](#disk-repair) · [What's ready, what's experimental](#whats-ready) · [The Maintenance card says…](#trouble-maintenance)

<a id="guest-utilities"></a>

### Utilities for a running instance

*Sync the clock, repair the package manager, clear caches, and look for disk errors.*

The **While It's Running** section of the Maintenance card has four utilities. Each has a **Run** button, enabled while the instance is running.

<a id="guest-utilities--clock"></a>

#### Sync clock with the Mac

An instance resumed from hibernation keeps the time it was saved at, which can confuse web certificates, builds and `git`. This sets Linux's clock to your Mac's and tells you how far off it was - or "The clock was already in sync."

> [!TIP]
> **Usually automatic**
> MSL already corrects the clock of running instances after your Mac wakes. This is for when something slips through.

<a id="guest-utilities--packages"></a>

#### Repair package manager

Finishes interrupted installs and clears a stale lock left behind by a crash, using the distro's own package manager - the fix for "could not get lock" and "interrupted" errors. It can take several minutes.

<a id="guest-utilities--caches"></a>

#### Clear caches inside Linux

Clears the package manager's downloaded files and trims the system journal.

> [!IMPORTANT]
> **Frees space inside Linux, not on your Mac**
> This makes room *inside* the instance. The disk image on your Mac doesn't shrink - see [Reclaiming disk space](#reclaim-space).

<a id="guest-utilities--disk-errors"></a>

#### Check for disk errors

Reads Linux's kernel log for filesystem and input/output errors. It only reads - if it finds any, shut the instance down and [check the disk](#disk-check).

**Related:** [The clock is wrong](#trouble-clock) · [The disk is full](#trouble-disk) · [Checking a disk](#disk-check)

---

<a id="chapter-sandbox"></a>

## 8. Sandbox Tab

*Cut an instance off from the network, your files, graphics or input - and watch what it says.*

<a id="sandbox"></a>

### The Sandbox tab

*Four switches that decide what one instance can reach, and one button to seal it.*

The Sandbox tab decides what an instance can reach. It has three parts: a header saying how locked-down the instance is, the four **Gates**, and **Watch**, which opens the Traffic Monitor.

<a id="sandbox--posture"></a>

#### The header

A lock icon and one word:

| Posture | Icon | Means |
|---|---|---|
| **Open** | open lock, grey | Every gate is open. The instance has the network, your home folder, graphics and input. |
| **Partly sealed** | lock with clock, orange | Some gates are closed - the line under it says how many. |
| **Sealed** | closed lock, red | Every gate is closed: "no network, no share, no new windows, no input." |

On the right, one button does everything at once: **Seal it** closes all four gates; **Open everything** opens them all.

<a id="sandbox--gates"></a>

#### The gates

Four switches, each **Open** or **Cut**: **Network**, **Mac home share**, **Graphics (mslgd)**, and **Keyboard & mouse**. When one is cut, a line under it says exactly what that does. Each is covered in [The four gates](#sandbox-gates).

<a id="sandbox--persist"></a>

#### Gates stick

As the card's footnote says, gates are kept across restarts and re-applied every time the instance starts or resumes - "so hibernating won't quietly hand anything back." You can close gates on a stopped instance, too; the header then says what it *will* have when it starts, which is the way to sandbox something before it ever runs.

<a id="sandbox--limits"></a>

#### What the Sandbox is - and isn't

> [!IMPORTANT]
> **Switches on top of the virtual machine**
> Every gate is enforced by your Mac, from outside Linux. Nothing asks Linux to behave, so software inside it can't undo a gate.
>
> But they are switches *on top of* the virtual machine, not the security boundary itself - the virtual machine is that. They don't harden the VM against escape. The tab says this too when anything is closed.

> [!NOTE]
> **The switches show the truth, not the request**
> The gates reflect what the virtual machine's devices are actually doing, as reported by MSL's background service - not just what was last asked for. If something settles differently from what you asked, a banner says "The sandbox settled differently".

**Related:** [The four gates](#sandbox-gates) · [The Traffic Monitor](#traffic-monitor)

<a id="sandbox-gates"></a>

### The four gates

*Exactly what cutting the network, home share, graphics or input does - and doesn't do.*

Each gate is honest about its scope, because "cut the internet" and "unplug this VM's network card" are not the same promise.

<a id="sandbox-gates--network"></a>

#### Network

> [!NOTE]
> The virtual network card is detached. The guest keeps its IP and routes but no packet reaches the host, so it looks like an unplugged cable rather than a firewall block.

- Linux can't reach the internet, your local network, or your Mac over the network.
- **SSH stops working**, because SSH uses the network. The SSH card says the address isn't answering and names this gate as a likely reason.
- **`msl` shells, the Terminal tab and MSL Files keep working.** They use a direct channel between your Mac and the virtual machine (vsock) that doesn't go through the network card at all.

<a id="sandbox-gates--home-share"></a>

#### Mac home share

> [!NOTE]
> /mnt/mac stops resolving. Anything already reading a file there will see I/O errors, not a clean unmount.

Linux loses access to your Mac home folder. Close anything using files in `/mnt/mac` before cutting it.

<a id="sandbox-gates--graphics"></a>

#### Graphics (mslgd)

> [!NOTE]
> mslgd stops accepting new X11 connections. Windows that are already open keep their connection and keep drawing.

New Linux app windows can't open. Apps already on screen carry on - cut this *before* launching things if you want none of them.

<a id="sandbox-gates--input"></a>

#### Keyboard & mouse

> [!NOTE]
> Keyboard and pointer events are dropped on the host side, before they are encoded. The guest sees an idle input device, not a disconnected one.

Linux app windows still draw, but typing and clicking in them do nothing. Handy for watching something run without nudging it by accident.

<a id="sandbox-gates--combining"></a>

#### Combining them

| You want | Cut |
|---|---|
| No internet, but keep working in the shell | Network |
| Keep a program away from your personal files | Mac home share |
| Stop an instance from putting windows on your screen | Graphics |
| Look but don't touch | Keyboard & mouse |
| Everything, for something you don't trust | **Seal it** |

**Related:** [The Sandbox tab](#sandbox) · [Your home folder inside Linux](#home-share) · [Connecting over SSH](#ssh) · [SSH won't connect](#trouble-ssh)

<a id="traffic-monitor"></a>

### The Traffic Monitor

*A live, minimalist log of what MSL and an instance are doing - and what Linux has connected.*

The Traffic Monitor is a small, live view of what's happening between your Mac and an instance. Open it from the **Watch** card on the Sandbox tab - **Open**, or **⇧⌘T** while the Sandbox tab is showing. It slides down over the window; **Done** closes it.

Along the top: **Pause**/**Resume** (freezes the list so you can read it), **Clear** (empties the log), and **Done**. Under that, two lanes.

<a id="traffic-monitor--msl-activity"></a>

#### MSL activity

MSL's own traffic: the things your Mac and the instance actually say to each other through MSL. Newest at the top, each with the time, a coloured icon and a short summary. Repeated events fold together with a count like **×12** instead of flooding the list.

| Category | Colour | Covers |
|---|---|---|
| **Control** | blue | Commands to the background service: start, suspend, snapshot. |
| **Files** | green | The file bridge - MSL Files and Finder reading and writing guest files. |
| **Display** | purple | X11 connections, app windows, mslgd. |
| **Lifecycle** | orange | The virtual machine itself: booted, paused, restored, stopped. |
| **Sandbox** | red | Gates opening and closing. |

Click a category's chip to hide or show it. **This instance only** (on by default) hides other instances' events - MSL-wide events, like the service starting, always show because they're context.

With nothing to show yet it says "Listening…" - start the instance, open a file or launch an app and it'll appear. The footer counts what's shown.

> [!IMPORTANT]
> **Not a packet capture**
> This lane shows MSL's own traffic, which your Mac can genuinely see. It doesn't show Linux's own internet connections - those live inside the virtual machine's network stack. That's the second lane.

<a id="traffic-monitor--guest-connections"></a>

#### Guest connections

What Linux itself has open, read from Linux's own network stack once a second:

- Each row: **TCP** or **UDP**, then either "listening on *address:port*" or *local* → *remote*, the program that owns it, and its state (listening ones in green).
- **Show processes** matches each connection to the program that owns it. That means looking through every open file of every program in Linux, so it's only done while you're looking.
- **Hide loopback** (on by default) hides connections that never leave the guest, and says how many it hid.

This lane reports *sockets, not packets*: that something is connected to an address, and who owns it - not what was sent.

> [!NOTE]
> **Only while it's running**
> If the instance isn't running, this lane says so - and won't start it just to look, since that would change the very thing you're watching.

**Related:** [The Sandbox tab](#sandbox) · [What's ready, what's experimental](#whats-ready) · [Logs and msl doctor](#logs-and-doctor)

---

<a id="chapter-files"></a>

## 9. MSL Files

*Browse your Mac and your Linux instances side by side, and move files between them.*

<a id="files-window"></a>

### The MSL Files window

*A Finder work-alike that shows your Mac and your running Linux instances side by side.*

**MSL Files** is a file browser that can see both sides of MSL: your Mac's folders and the filesystem inside every running instance, in one window. Open it with **Window ▸ MSL Files**, or **⌥⌘F**.

It deliberately *is* a Finder look-alike - the same four views, the same sidebar, the same shortcuts - so there's nothing new to learn. What it adds is the part Finder can't do.

> [!NOTE]
> **Why not just Finder?**
> Finder *can* reach a running instance - its files are served to your Mac as a real network volume - but it appears under a loopback IP address with no hint of which instance it is. MSL Files shows each instance by name, next to your own folders, and lets you drag between them.

<a id="files-window--layout"></a>

#### The window

- **The sidebar**: Recents, your folders, **Linux** (one entry per running instance), and your Finder tags. See [The Files sidebar](#files-sidebar).
- **The toolbar**: back, forward, enclosing folder, open; the four view buttons; sort; new folder, Quick Look, share, tags, trash; and a search field.
- **The path bar** under the toolbar - every folder above this one, each clickable.
- **The status bar** at the bottom - how many items (or "3 of 12 selected"), whether the place is read-only, and how much space is available.

With no instance running and nothing selected, it says "Nothing to browse - Start an instance to see its Linux filesystem here."

<a id="files-window--search"></a>

#### Searching

The search field in the toolbar (⌘F) filters what's in the current folder by name, as you type. For searching everything, use **Recents** or a **tag** in the sidebar, which are Spotlight searches over your home folder.

<a id="files-window--shortcuts"></a>

#### Finder's shortcuts

Every Finder shortcut you know works here. They're all listed in [Keyboard shortcuts](#shortcuts--files).

**Related:** [The Files sidebar](#files-sidebar) · [Moving files between Mac and Linux](#files-moving) · [Your home folder inside Linux](#home-share)

<a id="files-sidebar"></a>

### The Files sidebar

*Recents, your folders, your Linux instances by name, and your tags.*

From top to bottom:

| Section | Contains |
|---|---|
| *(no heading)* | **Recents** - files you've used lately, from Spotlight. |
| **Favorites** | Your home folder, Desktop, Documents, Downloads and Applications - whichever exist. |
| **Locations** | **Macintosh HD**, your Mac's whole disk. |
| **Linux** | Each **running** instance, by name, with an orange icon. "No running instances" when there are none. |
| **Tags** | Your Finder tags, each with its colour dot. Clicking one lists everything with that tag. |

A small **lock** beside a place means it's read-only for you; the status bar says "Read-only" too, and anything that would change it is greyed out.

> [!TIP]
> **Tagging by dropping**
> Drop files onto a tag in the sidebar to apply that tag, just like Finder.

<a id="files-sidebar--instances"></a>

#### Instances come and go

The Linux section follows your instances: start one and it appears; stop or suspend it and it leaves. MSL Files never starts an instance by itself. The **Go** menu lists them too, under Finder's usual destinations.

**Related:** [The MSL Files window](#files-window) · [Tags](#files-tags)

<a id="files-views"></a>

### Views, sorting and getting around

*Icons, list, columns and gallery; sorting and grouping; back, forward and Go to Folder.*

<a id="files-views--views"></a>

#### The four views

| View | Shortcut |
|---|---|
| as Icons | ⌘1 |
| as List | ⌘2 |
| as Columns | ⌘3 |
| as Gallery | ⌘4 |

Or use the view buttons in the toolbar, or the **View** menu.

<a id="files-views--sorting"></a>

#### Sorting and grouping

The arrows button in the toolbar (or **View ▸ Sort By** and **Group By**):

- **Group by**: None, Name, Kind, Date Modified, Size, or Tags.
- **Sort by**: Name, Size, Kind, Date Modified, or Date Added.
- **Ascending**, and **Keep Folders on Top**.
- **Show Hidden Files**: also ⇧⌘., Finder's own shortcut for it.

<a id="files-views--show"></a>

#### Showing and hiding

|  | Shortcut |
|---|---|
| Hide or show the sidebar | ⌃⌘S |
| Show Path Bar | ⌥⌘P |
| Show Status Bar | ⌘/ |
| Show Hidden Files | ⇧⌘. |

<a id="files-views--navigating"></a>

#### Getting around

|  | Shortcut |
|---|---|
| Back | ⌘[ |
| Forward | ⌘] |
| Enclosing folder | ⌘↑ |
| Open the selection | ⌘↓, or double-click |
| Go to Folder… | ⇧⌘G - type a path like `/` or `~/` |
| Recents | ⇧⌘F |
| Documents · Desktop · Home | ⇧⌘O · ⇧⌘D · ⇧⌘H |
| Downloads | ⌥⌘L |
| Computer · Applications · Utilities | ⇧⌘C · ⇧⌘A · ⇧⌘U |
| iCloud Drive | ⇧⌘I, if you use it |

Click any folder in the path bar to jump straight to it. The **Go** menu also lists every running instance.

> [!NOTE]
> **Return renames, like Finder**
> Return starts renaming the selected item; it doesn't open it. ⌘↓ or a double-click opens.

**Related:** [Keyboard shortcuts](#shortcuts) · [The MSL Files window](#files-window)

<a id="files-moving"></a>

### Moving files between Mac and Linux

*Drag, copy and paste, duplicate, new folders, rename, compress, share.*

<a id="files-moving--drag"></a>

#### Drag and drop

Drag files from Finder, or from anywhere in MSL Files, into a folder - on your Mac or inside an instance. They're **copied**; the originals stay where they were. An empty folder says "Drag files here to copy them in."

Places that are read-only won't accept a drop.

<a id="files-moving--copy-paste"></a>

#### Copy and paste

Select files and press **⌘C**, go somewhere else, and press **⌘V** - within MSL Files, across the line between Mac and Linux, either way. The Edit menu's **Select All Items** (⌥⌘A) selects everything in the folder.

<a id="files-moving--editing"></a>

#### Making and changing things

| Action | How |
|---|---|
| New folder | ⇧⌘N, or the toolbar's folder button |
| New folder containing the selection | ⌃⌘N |
| Rename | Return, or right-click ▸ Rename… |
| Duplicate | ⌘D |
| Compress into a zip | File ▸ Compress |
| Share | the toolbar's share button, or File ▸ Share… |
| Copy the path | ⌥⌘C (File ▸ Copy as Pathname) |

<a id="files-moving--looking"></a>

#### Looking closer

- **Quick Look**: Space, or ⌘Y. A preview opens; **Done** closes it.
- **Get Info**: ⌘I. The item's thumbnail and name; **General** (Kind, Size, Where, Created, Modified); and **Tags**, as colour swatches to click.
- **Reveal in Finder**: ⌘R shows it in a real Finder window.

> [!TIP]
> **The other way round**
> Linux can already reach your Mac home folder at `/mnt/mac`, so for files under your home folder there's often nothing to copy at all. See [Your home folder inside Linux](#home-share).

**Related:** [Your home folder inside Linux](#home-share) · [Deleting files](#files-deleting) · [The MSL Files window](#files-window)

<a id="files-tags"></a>

### Tags

*Finder tags that work in both directions, on your Mac's files.*

MSL Files uses Finder's real tags - tag something here and Finder sees it, and the other way round.

<a id="files-tags--adding"></a>

#### Adding and removing

- The **tag** button in the toolbar, **File ▸ Tags**, or **right-click ▸ Tags**: choose a tag to add it; choose one with a tick to remove it. **Clear Tags** removes them all.
- **Get Info** (⌘I) shows the standard colours as swatches - click one to toggle it.
- Drop files onto a tag in the sidebar.

<a id="files-tags--finding"></a>

#### Finding tagged things

Each tag in the sidebar lists everything carrying it, using Spotlight across your home folder. **Group by ▸ Tags** groups a folder's contents by tag.

**Related:** [The Files sidebar](#files-sidebar) · [Moving files between Mac and Linux](#files-moving)

<a id="files-deleting"></a>

### Deleting files

*The Trash on your Mac, and permanent deletion inside Linux.*

**Move to Trash**: ⌘⌫, the toolbar's trash button, or right-click - works as you'd expect on your Mac's files: they go to the Trash, and you can get them back.

> [!CAUTION]
> **Inside Linux there's no Trash**
> An instance's filesystem has no Trash. Deleting there asks first - "This volume has no Trash." with **Delete *n* Items Permanently** - and "Deleting here cannot be undone" means exactly that.

> [!TIP]
> **A safety net for big clean-ups**
> Before deleting a lot inside Linux, consider a [snapshot](#snapshots) - or copy what matters to your Mac first.

**Related:** [Moving files between Mac and Linux](#files-moving) · [Snapshots](#snapshots)

<a id="files-open-in-msl"></a>

### Opening a folder in a Linux shell

*Right-click a folder to open a Linux shell already sitting in it.*

Right-click a folder in MSL Files for two ways into a terminal:

- **Open Folder in MSL**: a *Linux* shell in Terminal.app, already in that folder.
- **Open in Terminal**: a normal *Mac* shell in Terminal.app, in that folder.

<a id="files-open-in-msl--which"></a>

#### Which instance?

| The folder is… | Open Folder in MSL… |
|---|---|
| Inside an instance | opens there: "Open Folder in MSL (*work*)". |
| Under your Mac home folder, one instance running | opens in that one, through `/mnt/mac`. |
| Under your home folder, several running | offers a submenu to choose. |
| Under your home folder, none running | is greyed out - `/mnt/mac` only exists inside a running instance. |
| Outside your home folder (`/Applications`, another drive) | is greyed out - Linux can't see it. |

So a project in `~/Code/thing` opens as `/mnt/mac/Code/thing` inside Linux: same files, Linux tools.

**Related:** [Your home folder inside Linux](#home-share) · [Using Terminal.app](#terminal-app)

---

<a id="chapter-power"></a>

## 10. Power & Lifecycle

*What happens when your Mac sleeps or shuts down, when instances sit idle, and why distros share.*

<a id="power-events"></a>

### Sleep, shutdown and battery

*MSL freezes every instance before your Mac sleeps, shuts down, logs out or runs out of battery.*

A virtual machine that's writing to its disk when the power goes is how Linux disks get damaged. So whenever your Mac is about to sleep or stop, MSL's first move is to **freeze every running instance** - near-instant, with no disk activity - so none of them is mid-write. Only then does it do anything slower.

<a id="power-events--table"></a>

#### What happens when

| Your Mac… | MSL… |
|---|---|
| **Sleeps** (lid closed, Apple menu ▸ Sleep) | Freezes every instance. They stay in memory. |
| **Shuts down or restarts** | Freezes every instance, then hibernates each one to disk. |
| **Logs out** | The same as shutting down. |
| **Is on battery at 10% or below** | The same as shutting down, before the battery gives out. |
| **Switches to another user** | Nothing - instances keep running for you, like everything else in your session. |

MSL never holds up your Mac shutting down.

<a id="power-events--wake"></a>

#### Waking up

After your Mac wakes:

- Instances that were frozen stay **Suspended** until something uses them - open a shell or an app, or click **Resume**.
- Open terminal sessions have ended - the connection didn't survive the sleep. The Terminal tab shows "Session ended"; click **Reconnect**.
- MSL corrects the clock of instances that are running, since a frozen instance's clock stops while your Mac sleeps.

<a id="power-events--shutdown"></a>

#### Shutting down

Shutdown, restart and logout hibernate every running instance, so next time you start one it picks up exactly where it was.

Before that, MSL asks open Linux apps to close, the way their own close buttons would - so an app with unsaved work gets its chance to ask.

> [!WARNING]
> **Linux app windows don't come back**
> The instance resumes, but its app windows don't: each window's connection to your Mac ended when the Mac shut down. Save your work in Linux apps before shutting down or restarting.

> [!NOTE]
> **If time runs out**
> macOS only waits so long. If an instance can't finish saving in time, it was still frozen first, so its disk is safe - it simply starts fresh next time instead of resuming, and Linux tidies its filesystem up as it starts, as it would after a power cut.

> [!TIP]
> **Trying it without shutting down**
> `msl power-test sleep` (or `shutdown`, `logout`, `lowbattery`, `wake`) runs MSL's response by hand, without your Mac actually doing it. `msl power-test battery` shows what the battery watcher sees.

**Related:** [Suspend, hibernate or shut down?](#stopping-instances) · [Living with Linux windows](#linux-windows) · [The clock is wrong](#trouble-clock)

<a id="idle"></a>

### Idle instances

*Instances nobody's using suspend themselves, and wake the moment you need them.*

A running instance uses processor time and battery even when nothing's happening inside it. So MSL tidies up after you.

<a id="idle--last-session"></a>

#### When the last session closes

When the last shell or Linux app on an instance closes, MSL **suspends** it about three seconds later. The dot turns orange.

Using it again resumes it straight away - opening the Terminal tab, `msl work` in a terminal, opening one of its apps, or clicking **Resume**. Resuming from suspend is almost instant, so mostly you won't notice.

What keeps an instance awake:

- an open shell, in the app, in Terminal.app, or from `msl`;
- an open Linux app.

<a id="idle--long-idle"></a>

#### Left alone for a while

Instances that have been left alone for a while may also be **hibernated**, to give their memory back to your Mac. Starting one resumes it exactly where it was - it just takes a few seconds rather than being instant.

<a id="idle--power"></a>

#### Around sleep and shutdown

While your Mac is going to sleep or shutting down, idle suspending stands aside so it can't get in the way of MSL [protecting instances](#power-events).

**Related:** [Suspend, hibernate or shut down?](#stopping-instances) · [The Terminal tab](#terminal-tab) · [Living with Linux windows](#linux-windows)

<a id="shared-disks"></a>

### Shared disks

*Instances of the same distro share one disk - so only one of them can run at a time.*

Each distro has **one disk image** on your Mac, and every instance of that distro uses it. Two Debian instances, one Debian disk.

<a id="shared-disks--why"></a>

#### Why

Distro disks are big, and a copy per instance would fill your Mac quickly. Sharing means a new instance costs almost nothing.

<a id="shared-disks--means"></a>

#### What it means

- **Only one instance per distro can run at a time.** Two running machines writing to one disk would wreck it, so MSL refuses: "'*other*' is already running and shares *distro*'s disk with '*this*' - running both at once would corrupt it; stop '*other*' first."
- **Files are shared.** Anything saved inside Linux on `work` is there on `scratch`, if they're the same distro. So is your [Linux user](#first-start--user).
- **Disk size and storage settings are shared**: see [Disk size and storage](#storage).
- **Disk maintenance blocks the whole distro** while it runs.

<a id="shared-disks--separate"></a>

#### What's separate

Each instance still has its own name, CPUs and memory, sandbox gates, SSH shortcut, hibernated session, snapshots, and Mac apps.

> [!TIP]
> **Two Linux machines at once**
> Use two different distros - they have separate disks and run side by side happily.

> [!WARNING]
> **Snapshots and shared disks**
> Because the disk is shared, running *any* instance of a distro changes the disk every snapshot of that distro was taken against. See [the snapshot rule](#snapshots--disk).

**Related:** [Words you'll see](#vocabulary) · [How many can run at once](#concurrency) · [Creating an instance](#create-instance) · [Disk size and storage](#storage)

---

<a id="chapter-troubleshooting"></a>

## 11. Troubleshooting

*Symptoms first, then what to do - and where to look when that isn't enough.*

<a id="trouble-wont-start"></a>

### An instance won't start

*Greyed-out Start buttons, refusals, and what each message means.*

<a id="trouble-wont-start--greyed"></a>

#### Start is greyed out

| Why | What to do |
|---|---|
| A spinner is showing - it's busy. | Wait for it to finish. |
| The capacity pill is orange - four are running. | Hibernate or shut one down. Suspending doesn't free a slot. See [Concurrency](#concurrency). |
| There's an **Install *Distro*** button instead. | The distro isn't downloaded. See [Installing a distro](#install-distro). |

<a id="trouble-wont-start--messages"></a>

#### Messages, and what they mean

> [!NOTE]
> **"4 instances are already running … suspend or shut one down first"**
> Every slot is taken. Hibernate or shut one down.

> [!NOTE]
> **"'other' is already running and shares distro's disk with 'this'…"**
> Another instance of the same distro is running. Only one can use the disk at a time - stop that one first. See [Shared disks](#shared-disks).

> [!NOTE]
> **"didn't start: the filesystem check at start found a problem"**
> [Check-at-start](#check-at-start) is on and found damage. [Repair the disk](#disk-repair), then start it.

> [!NOTE]
> **"check-at-start is on, but e2fsck isn't installed on this Mac"**
> Install e2fsprogs (`brew install e2fsprogs`), or turn the check off on the Maintenance card.

> [!NOTE]
> **"maintenance is running on this instance's disk"**
> A disk tool is working on it. It can start once that finishes.

> [!WARNING]
> **"the guest kernel panicked while booting - its filesystem is probably damaged"**
> Linux couldn't start from its disk. With the instance stopped, [check the disk](#disk-check), then repair it. The log has the details: `~/Library/Logs/MSL/mslhd.log`.

> [!NOTE]
> **"shell connection timed out"**
> The connection to the instance got stuck. Try again - MSL starts a fresh machine.

> [!NOTE]
> **"MSL's background service isn't running"**
> See [The service isn't running](#trouble-service).

**Related:** [How many can run at once](#concurrency) · [Shared disks](#shared-disks) · [Filesystem errors](#trouble-filesystem) · [The service isn't running](#trouble-service)

<a id="trouble-service"></a>

### The service isn't running

*When MSL's background service is missing, stopped, or out of date.*

Everything in MSL goes through its background service, `mslhd`. When it isn't running, nothing can start.

<a id="trouble-service--signs"></a>

#### Signs

- With no instance selected: "MSL's background service isn't running", and a **Start it** button.
- Errors ending "MSL's background service isn't running."
- The Tools tab's **Background service** card says **Not running**.
- Linux apps in the Dock don't open.

<a id="trouble-service--fixes"></a>

#### Fixes, in order

1. Click **Start it** (or quit and reopen MSL, which starts it too).
2. Make sure **Start MSL's service automatically** is on, on the Tools tab.
3. Run `msl doctor` in Terminal - it checks whether the service is reachable and whether MSL's tools are installed. See [Logs and msl doctor](#logs-and-doctor).
4. Read `~/Library/Logs/MSL/mslhd.log` - the last lines usually say why it stopped.

<a id="trouble-service--outdated"></a>

#### "an older version"

The Maintenance card may say "MSL's background service answered, but not in a way this version understands". That's the service from before your last update, still running. The new one takes over the next time you log in - log out and back in to switch now.

**Related:** [The background service](#background-service) · [Logs and msl doctor](#logs-and-doctor)

<a id="trouble-apps"></a>

### Linux apps won't appear or open

*Empty app grids, apps that won't open, and windows that misbehave.*

<a id="trouble-apps--empty"></a>

#### The grid is empty

- "**No GUI applications found**" - nothing installed has a `.desktop` entry. Command-line programs never do. Install a GUI app inside Linux, then **Refresh**. See [Your first Linux app](#first-app).
- "**No applications yet**" with **Install *Distro*** - the distro isn't downloaded yet.

<a id="trouble-apps--missing"></a>

#### I installed something and it isn't there

Click **Refresh** - MSL only reads the list when asked. Check the source picker isn't filtering it out (choose **All**), and that the search field is empty.

<a id="trouble-apps--wont-open"></a>

#### It won't open

| Check | Because |
|---|---|
| Is the **Graphics** gate cut on the Sandbox tab? | It stops new windows opening. |
| Is the capacity pill orange? | Opening an app has to start the instance, and every slot is taken. |
| Is the background service running? | It's what runs Linux apps. See [The service isn't running](#trouble-service). |
| Does it run from the Terminal tab? | Type its command there - errors print right in the terminal. |

An orange "Couldn't start *app*" banner includes the reason. Apps started from the Dock or Spotlight have no terminal, so they write problems to `~/Library/Logs/MSL` - **Open Logs** on the Tools tab.

<a id="trouble-apps--dock"></a>

#### An app in my Dock does nothing

If the instance it belongs to has been removed, its Mac apps were removed too - but a Dock tile can outlive them. Remove the tile. `msl doctor` lists apps pointing at removed instances, and `msl doctor --fix` cleans them up.

<a id="trouble-apps--drawing"></a>

#### The window looks wrong

mslgd is MSL's own display server, and some apps use parts of X11 it doesn't draw perfectly yet. Try the app from another source (a Flatpak, say). See [Living with Linux windows](#linux-windows).

<a id="trouble-apps--clipboard"></a>

#### Copy and paste doesn't work between apps

Not yet - only within one Linux app. See [Copy and paste](#linux-windows--clipboard).

**Related:** [The Applications tab](#apps-tab) · [Living with Linux windows](#linux-windows) · [The four gates](#sandbox-gates)

<a id="trouble-ssh"></a>

### SSH won't connect

*Not answering on port 22, stale details, and setup that fails.*

<a id="trouble-ssh--not-answering"></a>

#### "isn't answering on port 22"

1. **Is the Network gate cut?** On the Sandbox tab. Cutting it unplugs the virtual network card SSH uses. The app's own terminal and `msl` shells still work, because they don't use the network.
2. **Is the instance running?** SSH needs it up.
3. Click **Set up again** on the SSH card - it redoes everything, including restarting the SSH server.

<a id="trouble-ssh--stale"></a>

#### "Last known details"

Not a problem: the card is showing details from when the instance last ran. It rechecks once the instance is running.

<a id="trouble-ssh--failed"></a>

#### Setup failed

The card shows the reason and a **Try again** button. Setting up installs things inside Linux, which needs the instance running - and, the first time, may need the network.

<a id="trouble-ssh--tools"></a>

#### VS Code or another tool can't find it

They read `~/.ssh/config`. Check the `Host msl-work` entry is there; **Set up again** rewrites it. **Copy all details** on the card gives you everything to paste elsewhere.

**Related:** [Connecting over SSH](#ssh) · [The four gates](#sandbox-gates)

<a id="trouble-disk"></a>

### The disk is full

*Running out of space inside Linux, or on your Mac.*

There are two different "full"s, and the Storage card on the Overview tab shows both.

<a id="trouble-disk--guest-full"></a>

#### Full inside Linux

"No space left on device" inside Linux, or the usage bar is orange.

1. **Make room inside:** run **Clear caches inside Linux** from the Maintenance card, and delete what you don't need.
2. **Raise the limit:** drag the Storage card's slider up. The disk grows and Linux's filesystem is stretched to match at the next start.
3. **Let it grow by itself:** with a dynamic disk, **Grow automatically when it runs low** adds 8 GB at a start whenever it's 85% full, up to the limit.

<a id="trouble-disk--host-full"></a>

#### Full on your Mac

A dynamic disk only takes the space it has written, but that grows as Linux writes - and it never shrinks back, even after deleting files inside Linux. The Storage card shows what it really takes ("Actually used on your Mac"), and its footnote shows your Mac's free space.

See [Reclaiming disk space](#reclaim-space) for what can be deleted.

**Related:** [Disk size and storage](#storage) · [Reclaiming disk space](#reclaim-space) · [Utilities for a running instance](#guest-utilities)

<a id="trouble-filesystem"></a>

### Filesystem errors

*Read-only filesystems, I/O errors, and instances that won't boot - how to check and repair.*

<a id="trouble-filesystem--signs"></a>

#### Signs

- "Read-only file system" when writing - Linux switched the disk to read-only after finding a problem.
- "Input/output error" on files.
- The instance won't start: "the guest kernel panicked while booting".
- **Check for disk errors** on the Maintenance card finds something.

<a id="trouble-filesystem--steps"></a>

#### What to do

1. **Save anything you can**: copy important files out to `/mnt/mac` or with MSL Files.
2. **Shut the instance down.**
3. **[Check Disk](#disk-check)** on the Maintenance card (needs e2fsprogs on your Mac).
4. If it finds problems, **[Repair Disk…](#disk-repair)**. A backup is taken first.
5. Start the instance and see how it is. If things are worse, **Restore…** puts the old disk back.
6. When all's well, **Discard** the backup.

No e2fsprogs? Try the [maintenance boot](#maintenance-boot).

<a id="trouble-filesystem--prevent"></a>

#### Keeping it from happening

- Shut Linux down properly - `sudo poweroff` inside it, or `msl --shutdown` - rather than the app's **Shut Down**, which stops it at once. See [the note on Shut Down](#stopping-instances--shut-down).
- Don't restore [snapshots](#snapshots--disk) after the disk has changed.
- Consider [checking at every start](#check-at-start).

**Related:** [Checking a disk](#disk-check) · [Repairing a disk](#disk-repair) · [Maintenance boot](#maintenance-boot) · [Checking the disk at every start](#check-at-start)

<a id="trouble-clock"></a>

### The clock is wrong

*Wrong time inside Linux after sleep or hibernation, and why it matters.*

A frozen or hibernated instance's clock stops, so after a long pause it can be hours behind. That isn't only cosmetic: it breaks secure web connections ("certificate is not yet valid"), confuses `make` and `git`, and causes errors that look unrelated.

- MSL fixes the clock of running instances automatically after your Mac wakes.
- Anything else: **Sync clock with the Mac** on the Maintenance card. It says how far off it was.

Check the time inside Linux with `date`.

**Related:** [Utilities for a running instance](#guest-utilities) · [Sleep, shutdown and battery](#power-events)

<a id="trouble-maintenance"></a>

### The Maintenance card says…

*Every message the Maintenance card can show instead of working, and what to do.*

| The card says | What to do |
|---|---|
| "This distro isn't installed yet, so there's no disk to check or repair." | Nothing to maintain yet. |
| "Checking what's available…" | Wait a moment. |
| "MSL's background service isn't answering…" | See [The service isn't running](#trouble-service). |
| "…answered, but not in a way this version understands…" | An older service is still running. Log out and back in. |
| "e2fsck isn't installed…" | **Copy Install Command**, then run it in Terminal. |
| "Shut the instance down first…" | Stop it. See [the note on Shut Down](#stopping-instances--shut-down). |
| "This instance has a hibernated session…" | **Start** it, then shut it down, then try again. |
| "Maintenance is already running on this disk." | Wait for it to finish. |
| "Start the instance to use these." | The utilities run inside Linux. |
| "MSL's background service didn't answer in time. It may still be working - check again in a moment." | A long job may still be running. Wait, then check again. |

**Related:** [The Maintenance card](#maintenance) · [What's ready, what's experimental](#whats-ready) · [The service isn't running](#trouble-service)

<a id="trouble-memory"></a>

### Memory trouble

*Your Mac gets slow, or programs inside Linux are killed for running out of memory.*

<a id="trouble-memory--mac-slow"></a>

#### Your Mac gets slow

Instances' memory can't be paged out, so too much of it leaves macOS short.

- Hibernate instances you aren't using - suspended ones still hold their memory.
- Lower their memory on the Overview tab - especially above the three-fifths warning.
- Use [dynamic memory](#memory-dynamic), so idle instances give memory back.

<a id="trouble-memory--guest-oom"></a>

#### Programs in Linux get killed

When Linux runs out of memory it stops a program to survive - often the biggest one. Linux images don't use swap, so there's no slow fallback first.

- Raise the instance's memory (manual), or its maximum (dynamic), then restart it.
- On dynamic memory, the live readout's **Guest stalling on memory** shows when it's struggling.

**Related:** [Memory: manual mode](#memory) · [Memory: dynamic mode](#memory-dynamic) · [How many can run at once](#concurrency)

<a id="logs-and-doctor"></a>

### Logs and msl doctor

*Where MSL writes what it's doing, and the command that checks your installation.*

<a id="logs-and-doctor--logs"></a>

#### Logs

MSL's logs are in `~/Library/Logs/MSL`. **Open Logs** on the Tools tab opens the folder.

- **mslhd.log**: the background service: every start, stop, power event and error, with the details behind the short messages in the app.
- Mac apps started from the Dock or Spotlight write their problems here too, since they have no terminal.

<a id="logs-and-doctor--doctor"></a>

#### msl doctor

In Terminal:

```sh
msl doctor
```

It checks for things no other command shows, and lists each as fine, a warning or a problem:

- Whether MSL's command-line tools are installed.
- Whether the background service is reachable.
- Every instance, and whether its distro is downloaded.
- Leftover files from removed instances, and cached app lists for them.
- Mac apps still pointing at removed instances.
- How much space the disk images take in total.

It only reports. If it finds leftovers, it lists them and tells you to run:

```sh
msl doctor --fix
```

which deletes exactly what it listed - nothing else.

**Related:** [The service isn't running](#trouble-service) · [Where MSL keeps things](#where-things-live)

<a id="reclaim-space"></a>

### Reclaiming disk space

*What takes space on your Mac, what can go, and what can't be shrunk.*

<a id="reclaim-space--what"></a>

#### What takes space

Everything is in `~/Library/Application Support/MSL`:

| File | What | Size |
|---|---|---|
| `rootfs.img` (Alpine), and `rootfs-<distro>.img` for the rest - `rootfs-debian.img`, `rootfs-rocky.img` and so on | Each distro's disk. | Whatever Linux has written. |
| `vm-<instance>.state` | A hibernated session. | About the instance's memory. |
| `vm-<instance>-<snapshot>.state` | A snapshot. | About the instance's memory. |
| `<disk>.pre-repair` | A backup from a disk repair. | Grows as the repaired disk changes. |

<a id="reclaim-space--options"></a>

#### What you can do

- **Discard repair backups** you no longer need, on the Maintenance card.
- **Remove instances** you don't use - that deletes their hibernated sessions and snapshots. See [Removing an instance](#removing-instances).
- **Delete a distro's disk image**, with every instance of that distro stopped. The space comes back immediately; the next start downloads the distro fresh.

> [!CAUTION]
> **Deleting a disk image deletes its files**
> Everything inside Linux on that distro - for every instance using it - goes with it. Copy out anything you want to keep first. Hibernated sessions and snapshots of that distro no longer match a fresh disk, so delete those too, or remove the instances.

<a id="reclaim-space--doesnt"></a>

#### What doesn't work

> [!IMPORTANT]
> **Deleting files inside Linux doesn't shrink the image**
> A dynamic disk grows as Linux writes, but deleting files inside Linux doesn't hand the space back to your Mac. **Clear caches inside Linux** makes room *inside* the instance, not on your Mac. The only way to get that space back is to delete the image and start fresh.

**Related:** [Disk size and storage](#storage) · [Removing an instance](#removing-instances) · [Snapshots](#snapshots) · [Where MSL keeps things](#where-things-live)

---

<a id="chapter-cli"></a>

## 12. Command line

*Everything msl --help prints, here.*

<a id="cli-help"></a>

### msl --help

*Every msl command in Terminal.app, grouped the way msl --help prints them.*

Type these in Terminal.app. `msl --help` prints the same list, and `msl files` opens MSL Files.

<a id="cli-help--get-started"></a>

#### Get started

| Command | Does |
|---|---|
| `msl install <distro>` | Download a distro, then set up its first instance - name, CPUs, memory and disk |
| `msl <instance>` | Open a shell. A distro name works too: msl debian |
| `msl <instance> <command>` | Run one command; exits with its exit code, like ssh |
| `msl` | Open a shell in the instance you used last |
| `msl -- <command>` | Run one command in the instance you used last |
| `msl files` | Open MSL Files, to browse your instances from the Mac (also --files) |

<a id="cli-help--shell-options"></a>

#### Shell options

| Command | Does |
|---|---|
| `-u, --user <name>` | Log in as this user instead of your default account (root is always there) |
| `-d, --distro <distro>` | The distro for a new instance: alpine, debian, ubuntu, kali, arch, fedora, rocky, alma, centos, oracle, opensuse, nix, or custom:<image> |

<a id="cli-help--instances"></a>

#### Instances

| Command | Does |
|---|---|
| `msl list` | Every instance and whether it's running (also: instances, ls) |
| `msl new [name] [sizes]` | Create an instance without opening a shell. No name: asks for name, CPUs, memory and disk |
| `msl resources [instance] [sizes]` | Show or change CPUs, memory and disk (also: config) |
| `msl storage [instance] [show/fixed <size>/dynamic <size>]` | Disk size, and whether its space is reserved on your Mac |
| `msl status [instance]` | Whether an instance is running, paused or off |
| `msl suspend / resume / hibernate [instance]` | Pause in memory, continue, or save to disk and stop |
| `msl --shutdown [instance]` | Power off cleanly; every running instance if none is named |
| `msl snapshot save/restore <instance> <name>` | Save or return to a named point |
| `msl snapshot list [instance]` | The snapshots an instance has |
| `msl remove <instance> [--keep-disk]` | Delete an instance. Removing a distro's last instance also deletes its disk |
| `msl remove-distro <distro> [--yes]` | Delete every instance of a distro and its disk |

<a id="cli-help--sizes-for-new-and-resources"></a>

#### Sizes, for new and resources

| Command | Does |
|---|---|
| `--cpus <n>` | How many CPU cores the instance gets |
| `--memory 6G / 2G-8G` | A fixed amount, or a range that grows and shrinks with use |
| `--disk 64G` | Disk size; your Mac only gives up space as files are written |
| `--disk-fixed 64G` | Disk size, reserved on your Mac up front |

<a id="cli-help--linux-apps"></a>

#### Linux apps

| Command | Does |
|---|---|
| `msl apps list / scan [instance]` | The instance's GUI apps; scan reads them again from Linux |
| `msl apps install <instance> <app>` | Make a Mac app for it in ~/Applications/MSL (install-all: every app) |
| `msl apps uninstall <instance> <app>` | Remove that Mac app |
| `msl apps pin / unpin <instance> <app>` | Add or remove its Dock tile |

<a id="cli-help--connect"></a>

#### Connect

| Command | Does |
|---|---|
| `msl ssh [instance] [--print]` | SSH in, setting access up the first time; --print shows the command |
| `msl images [list/open]` | Your own images in Custom Images; use one with --distro custom:<image> |
| `msl images new <image> --distro <distro>` | Start a custom image as a copy of an installed distro |

<a id="cli-help--maintenance"></a>

#### Maintenance

| Command | Does |
|---|---|
| `msl doctor [--fix]` | Find leftover state, missing images and uninstalled tools; --fix cleans up |
| `msl keyboard [--keysyms]` | The Mac keyboard layout, and what Linux apps see |
| `msl install-tools` | From a build: install msl and mslhd into Application Support |
| `msl uninstall [--everything] [--dry-run]` | Remove MSL and keep your Linux; --everything deletes that too |
| `msl help [--no-app]` | This help, and MSL Help in the app; --no-app just prints |

<a id="cli-help--experimental-and-debugging"></a>

#### Experimental and debugging

| Command | Does |
|---|---|
| `msl gui-native <instance> [app]` | Run a Linux app on MSL's own display server |
| `msl gui <instance> [app]` | Run a Linux app through XQuartz |
| `msl cage-view <instance> [app]` | A Wayland (cage) session in a Mac window |
| `msl cage-bridge-test / cage-input-test <instance>` | Wayland frame and input round-trip checks |
| `msl power-test <event>` | Replay a power event: sleep, shutdown, logout, lowbattery, wake, battery... |

**Related:** [msl command reference](#msl-command) · [The msl command](#command-line)

---

<a id="chapter-reference"></a>

## 13. Reference

*Every shortcut, every command, every file, every word.*

<a id="shortcuts"></a>

### Keyboard shortcuts

*Every keyboard shortcut in MSL, in one place.*

<a id="shortcuts--everywhere"></a>

#### Everywhere

| Keys | Does |
|---|---|
| ⌘N | New Instance |
| ⌘R | Refresh (main window) |
| ⌥⌘F | MSL Files |
| ⇧⌘? | Open the Help menu - MSL Help is in it |
| ⌘W | Close the window |
| ⌘Q | Quit MSL - instances keep running |

<a id="shortcuts--main"></a>

#### Main window

| Keys | Does |
|---|---|
| ⇧⌘T | Traffic Monitor (while the Sandbox tab is showing) |
| ↩ | Create, in the New Instance sheet |
| ⎋ | Cancel, in the New Instance sheet |

<a id="shortcuts--help"></a>

#### MSL Help

| Keys | Does |
|---|---|
| ⌘F | Search the guide |
| ⎋ | Clear the search |

<a id="shortcuts--files"></a>

#### MSL Files

Finder's own shortcuts, deliberately.

<a id="shortcuts--views"></a>

##### Views

| Keys | Does |
|---|---|
| ⌘1 | as Icons |
| ⌘2 | as List |
| ⌘3 | as Columns |
| ⌘4 | as Gallery |
| ⌃⌘S | Hide or show the sidebar |
| ⇧⌘. | Show Hidden Files |
| ⌥⌘P | Show Path Bar |
| ⌘/ | Show Status Bar |

<a id="shortcuts--getting-around"></a>

##### Getting around

| Keys | Does |
|---|---|
| ⌘[ | Back |
| ⌘] | Forward |
| ⌘↑ | Enclosing folder |
| ⌘↓ | Open the selection |
| ⇧⌘G | Go to Folder… |
| ⇧⌘F | Recents |
| ⇧⌘O | Documents |
| ⇧⌘D | Desktop |
| ⌥⌘L | Downloads |
| ⇧⌘H | Home |
| ⇧⌘C | Computer |
| ⇧⌘A | Applications |
| ⇧⌘U | Utilities |
| ⇧⌘I | iCloud Drive |
| ⌘F | Search this folder |

<a id="shortcuts--files-2"></a>

##### Files

| Keys | Does |
|---|---|
| ⌘O | Open |
| ⇧⌘N | New Folder |
| ⌃⌘N | New Folder with Selection |
| ↩ | Rename |
| ⌘D | Duplicate |
| ⌘C | Copy |
| ⌘V | Paste |
| ⌥⌘A | Select All Items |
| ⌥⌘C | Copy as Pathname |
| ⌘I | Get Info |
| Space | Quick Look |
| ⌘Y | Quick Look |
| ⌘R | Reveal in Finder |
| ⌘⌫ | Move to Trash |

<a id="shortcuts--symbols"></a>

#### Reading the symbols

| Symbol | Key |
|---|---|
| ⌘ | Command |
| ⇧ | Shift |
| ⌥ | Option |
| ⌃ | Control |
| ↩ | Return |
| ⎋ | Escape |
| ⌫ | Delete |

**Related:** [Views, sorting and getting around](#files-views) · [Using this guide](#using-help)

<a id="msl-command"></a>

### msl command reference

*Every msl subcommand, what it does, and its options.*

`msl` talks to the same background service as the app. Run `msl help` for this list in your terminal.

<a id="msl-command--shells"></a>

#### Shells and commands

| Command | Does |
|---|---|
| `msl [instance]` | An interactive shell. An instance named after a distro (`msl fedora`) needs no setup. |
| `msl [instance] <command>…` | Runs one command, like `ssh`; its exit code is returned. |
| `msl -- <command>…` | The same, on the default instance. |
| `-u`, `--user <name>` | Which Linux user. Every distro also has an unprivileged `msl` user. |
| `-d`, `--distro <distro>` | Which distro, for an instance being used for the first time. |

<a id="msl-command--instances"></a>

#### Instances

| Command | Does |
|---|---|
| `msl list` (or `ls`, `instances`) | Every instance. |
| `msl new <name> [--distro <d>] [--cpus <n>] [--memory <size>] [--disk <size>]` | Creates an instance, sized, without opening a shell. `--memory 2G-8G` makes it dynamic. |
| `msl resources [instance]` | Its CPUs, memory and disk. Also `msl config`. |
| `msl resources <instance> --cpus 4 --memory 6G --disk 128G` | Changes them - the same settings as the Resources and Storage cards. `--disk-fixed <size>` reserves the space up front. |
| `msl remove <instance> [--keep-disk]` | Removes it and its saved state. Removing a distro's last instance also deletes its disk, unless `--keep-disk`. |
| `msl status [instance]` | Its state. |
| `msl suspend [instance]` | Freezes it in memory. |
| `msl resume [instance]` | Unfreezes or starts it. |
| `msl hibernate [instance]` | Saves it to disk and stops it. |
| `msl --hibernate [instance]` | The same - for every running instance if none is named. |
| `msl --shutdown [instance]` | Asks Linux to power off, then stops it - every running instance if none is named. |

<a id="msl-command--setup"></a>

#### Distros, disks and snapshots

| Command | Does |
|---|---|
| `msl install <distro> [--manifest <url>]` | Downloads, verifies and installs a distro: `alpine`, `debian`, `ubuntu`, `kali`, `arch`, `fedora`, `rocky`, `alma`, `centos`, `oracle`, `opensuse` or `nix`. |
| `msl storage [instance] show` | Shows its disk settings. |
| `msl storage [instance] dynamic <size>` | A disk that takes only what it has written, up to `<size>`. |
| `msl storage [instance] fixed <size>` | A disk that reserves `<size>` up front. |
| `msl snapshot save <instance> <name>` | Saves a snapshot. |
| `msl snapshot restore <instance> <name>` | Restores one. |
| `msl snapshot list [instance]` | Lists them. |

<a id="msl-command--apps"></a>

#### Apps

| Command | Does |
|---|---|
| `msl apps list [instance]` | Its Linux GUI apps, from the last scan. |
| `msl apps scan [instance]` | Reads them from the guest again. |
| `msl apps install <instance> <app>` | Makes a Mac app for it in `~/Applications/MSL`. |
| `msl apps install-all [instance]` | The same, for every app found. |
| `msl apps uninstall <instance> <app>` | Removes that Mac app. |
| `msl apps pin <instance> <app>` / `unpin` | Adds or removes its Dock tile. |

<a id="msl-command--other"></a>

#### Connecting and checking

| Command | Does |
|---|---|
| `msl ssh [instance] [--print]` | Connects over SSH, setting it up on first use. `--print` shows the command instead. |
| `msl doctor [--fix]` | Checks the installation; `--fix` deletes only what it listed. |
| `msl power-test <event>` | Runs MSL's response to `sleep`, `shutdown`, `logout`, `switchaway`, `switchback`, `lowbattery` or `wake` by hand; `battery` shows what the battery watcher sees. |
| `msl install-tools` | From a build: installs MSL's tools and its login item. |

> [!NOTE]
> **Experimental commands**
> `msl gui`, `msl gui-native` and a few `cage-` commands are experiments from MSL's development, for trying other ways of showing Linux graphics. The Applications tab is the supported way to run Linux apps.

**Related:** [The msl command](#command-line) · [Logs and msl doctor](#logs-and-doctor) · [Linux users and root](#linux-users)

<a id="where-things-live"></a>

### Where MSL keeps things

*Every folder and file MSL uses on your Mac.*

| Where | What |
|---|---|
| `~/Library/Application Support/MSL` | Everything MSL keeps: distro disks, hibernated sessions, snapshots, repair backups, settings. |
| …`/rootfs*.img` | The distro disks. See [Reclaiming disk space](#reclaim-space). |
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

**Related:** [Reclaiming disk space](#reclaim-space) · [Logs and msl doctor](#logs-and-doctor) · [Connecting over SSH](#ssh)

<a id="glossary"></a>

### Glossary

*Every term in MSL, A to Z.*

| Term | Meaning |
|---|---|
| **Balloon** | How [dynamic memory](#memory-dynamic) hands memory back: a device inside Linux that inflates to return memory to your Mac and deflates to give it back. |
| **Check at start** | An optional disk check before every start. See [Checking at every start](#check-at-start). |
| **Distro** | A Linux distribution: Alpine, Debian, Ubuntu, Arch, Fedora, Rocky and more - see [Choosing a distro](#choosing-distro). |
| **Dynamic disk** | A disk that only takes the space Linux has written, up to a limit. |
| **Dynamic memory** | Memory that starts at a maximum and gives back what isn't used. |
| **e2fsck, e2fsprogs** | The Linux filesystem checker, and the package it comes in. Installed on a Mac with `brew install e2fsprogs`. |
| **Fixed disk** | A disk whose whole size is reserved on your Mac up front. |
| **Gate** | One of the four [Sandbox](#sandbox-gates) switches. |
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
| **Stall** | Time Linux programs spend waiting for memory - a sign of memory pressure. |
| **Suspend** | Freeze an instance in memory; resuming is almost instant. |
| **vCPU** | A virtual processor. |
| **vsock** | The direct channel between your Mac and a virtual machine, which doesn't use the network. |
| **X11** | The protocol Linux GUI apps draw with. |

**Related:** [Words you'll see](#vocabulary) · [Under the hood](#how-it-works)

<a id="credits"></a>

### Credits and licences

*Who made MSL, the licences it's under, and where to read more.*

The full story is in the **About MSL** window - choose **MSL ▸ About MSL**.

<a id="credits--about-window"></a>

#### In the About window

- **About**: the melon, MSL's logo; the version; and the mascot, illustrated by neekocat_2025.
- **Licence**: the full text, and why one repository has two licences.
- **Contributors**: everyone who has landed a commit, read live from GitHub, each with their own colour.
- **Extras**: what MSL is for, and the story of writing an X11 server from scratch.

<a id="credits--licences"></a>

#### Licences

MSL is free software.

- **mslgd**: the X11 server, its per-app window hosts and the guest-side tunnel, and anything derived from them - is under the **GNU General Public License v3**. Use it, change it, share it; if you share changes, share their source too. The app ships with mslgd built in, so the app as a whole is GPL v3.
- **Everything else**: the app, the `msl` command, the background service, MSL Files, the guest daemons and the virtual-machine plumbing - is under the **MIT licence**, so anyone can use it for anything.

> **Thank you** (´･ω･`)
> For trying a small, stubborn project that set out to make Linux feel at home on a Mac. If something in this guide is wrong, or missing, that's a bug too. ♡ (˶ᵔ ᵕ ᵔ˶)

**Related:** [Welcome to MSL](#welcome) · [Under the hood](#how-it-works)

This took like months btw.