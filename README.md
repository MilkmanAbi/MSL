<p align="center">
  <img src="https://raw.githubusercontent.com/MilkmanAbi/MSL/main/Assets/App_Logo.png" width="148" alt="The MSL melon">
</p>

<h1 align="center">MSL</h1>

<p align="center">
  <b>Mac Subsystem for Linux</b><br>
  Real Linux on your Mac. A shell in about a second, your files on both sides,<br>
  and Linux apps that open as Mac windows with Dock tiles of their own.
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/MilkmanAbi/MSL?label=release&color=e8735a"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-555555">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-arm64-555555">
  <img alt="12 distributions" src="https://img.shields.io/badge/distros-12-4c9a6a">
  <a href="#licence"><img alt="MIT, and GPLv3 for mslgd" src="https://img.shields.io/badge/licence-MIT%20%2B%20GPLv3%20(mslgd)-3b6fb6"></a>
</p>

<p align="center">
  <a href="#getting-started">Getting started</a> &nbsp;·&nbsp;
  <a href="#msl-files">MSL Files</a> &nbsp;·&nbsp;
  <a href="#mslgd">mslgd</a> &nbsp;·&nbsp;
  <a href="MSL-HELP.md">The guide</a> &nbsp;·&nbsp;
  <a href="#the-msl-family">The MSL family</a>
</p>

<br>

> MSL is completely free software, it has no funding, and the prebuilt images for it are hosted on SourceForge... It is painfully slow. I apologise for that.

> The Ubuntu image has a SLEW of issues, so many deps needed. It's kinda annoying, sorry.

MSL runs real Linux distributions on your Mac: an actual Linux kernel and an actual Linux userland on Apple's own Virtualization framework, with nothing emulated and no virtual machine window to babysit. You type `msl` and you're in. Your home folder is already there. Linux apps show up in the Dock, in Spotlight and in ⌘-Tab like they always lived there. ✨

MSL has been in development for over a year, and getting here took an honestly insane amount of engineering effort. It's free, it's open source, and it's still held together with a great deal of love. ヽ(・∀・)ﾉ

<p align="center">
  <b>Tried MSL?</b> Tell me how it went in the <a href="https://docs.google.com/forms/d/e/1FAIpQLScJm6KavA6mDJE9ntoH2YPvlsSoEJZaissnvr_b4gG68b3ixA/viewform?usp=dialog">community feedback form</a>. ( ´ ▽ ` )ﾉ
</p>

## First, an honest word about the name

MSL isn't really a subsystem. Nothing is woven into macOS, there's no kernel extension and no compatibility layer. Underneath, every Linux instance is a lightweight virtual machine, the same foundation plenty of other Mac apps are built on. (WSL 2 on Windows is a lightweight virtual machine too, for what it's worth.)

The name describes a feeling rather than an architecture. Everything MSL does is aimed at making that virtual machine disappear, until Linux on your Mac stops feeling like a trip to another computer and starts feeling like something your Mac simply does.

## What MSL isn't

MSL is not a replacement for Docker, and it doesn't try to be. Containers are the right tool for reproducible builds, services and deployments, and Docker is excellent at them. It's not VMware Fusion, Parallels or UTM either: if you want a full desktop, Windows, or another operating system in a window, those are made for exactly that. OrbStack and Lima are great at what they do too.

MSL is a different take on the same old idea. Less about containers, less about desktops, and more about a Linux you live right next to, the way WSL feels on Windows. It's just another piece of software, built by someone who wanted that feeling on a Mac and couldn't stop. Use it alongside everything else, or don't use it at all. Both are completely fine. ( ˘ω˘ )

## What it feels like

Open Terminal and type `msl debian`. About a second later you're in a real Linux shell, signed in as your own account, with job control, colours and line editing, and your Mac's home folder is waiting at `/mnt/mac`. Type `gimp`, and GIMP opens as a Mac window with its own icon in the Dock and its own name in the menu bar.

Close the lid, and MSL freezes your instances before the Mac goes to sleep; open it again and everything is exactly where you left it. Walk away from an instance and it quietly suspends itself so it stops using your processor, then wakes the moment you open a shell or an app. Shut the Mac down and your Linux apps get the chance to ask about unsaved work first.

None of that needs a window of its own. MSL has one if you want it, and you rarely have to open it.

## What's inside

<table>
<tr>
<td width="50%" valign="top">

### Linux, the WSL way

- **Twelve distributions**, from Alpine to Nix, each a verified download, plus custom images you build yourself.
- **Named instances**, up to eight of them and four running at once, each with its own settings.
- **A real shell wherever you are**: the app's Terminal tab, Terminal.app, the `msl` command, or SSH, which sets itself up the first time you ask for it.
- **Your own Linux account**, created on first start, with sudo asking for its own password.

</td>
<td width="50%" valign="top">

### Your Mac and Linux, both ways

- **Your Mac home folder inside Linux**, at `/mnt/mac`, from the first boot.
- **Linux's files on your Mac**, by instance name, in [MSL Files](#msl-files).
- **Links from Linux apps open on the Mac**, in your own browser and mail app.
- **"Show in folder" from a Linux app** opens MSL Files instead of a Linux file manager.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### Linux apps, as Mac apps

- **Every GUI app in an instance**, found automatically, with its real icon.
- **Add any of them to your Applications folder**, so Spotlight and Launchpad can open them with MSL closed.
- **Pin them to the Dock.** Opening one starts its instance if it needs to.
- **Drawn by [mslgd](#mslgd)**, MSL's own X11 server, so each window is a genuine Mac window.

</td>
<td width="50%" valign="top">

### Sized to fit, and kept safe

- **CPUs, memory and disk per instance.** Memory can be fixed or dynamic, and disks only take the space they actually use.
- **Suspend, hibernate and snapshots**, with instances frozen safely whenever your Mac sleeps, shuts down or logs out.
- **Disk check and repair from the Mac**, with an automatic backup before anything is touched.
- **A Sandbox** that cuts an instance off from the network, your files, graphics or input, with a live Traffic Monitor.

</td>
</tr>
</table>

<a id="msl-files"></a>

## MSL Files

It looks like Finder. It is not Finder. (◞‸◟)

A running Linux instance does show up in Finder, as a network volume called `127.0.0.1` with nothing to tell you which instance it is. The sensible fix would have been a better volume name. What MSL has instead is an entire file manager, written from scratch in SwiftUI, over 5,000 lines of it, in a sincere and slightly unhinged attempt to make moving files between macOS and Linux feel like a normal Mac thing to do. 😆

It has Finder's four views, Finder's sidebar and Finder's keyboard shortcuts, right down to Return renaming instead of opening and ⇧⌘. for hidden files. Quick Look, Get Info, copy and paste, drag and drop, real Finder tags, Recents and tag searches through Spotlight, and a Trash that knows Linux volumes don't have one. Your Mac's folders sit in the sidebar right above every running instance, listed by name, so getting a file from Downloads into Linux is a single drag.

Along the way it turned out that SwiftUI's own table never delivers a double-click, so the list view is laid out by hand. It is a genuinely silly amount of effort to rebuild something every Mac already ships with, and it's one of the parts of MSL I'm fondest of. ( ˶ˆ ᗜ ˆ˵ )

MSL Files is also available as [a standalone app](https://github.com/MilkmanAbi/MSL-Files).

<a id="mslgd"></a>

## mslgd

Linux GUI apps draw through a display protocol called X11. On a Mac the usual answer is XQuartz, and XQuartz works: the windows appear. But under XQuartz every Linux app is a window belonging to XQuartz. One Dock tile for all of them, one icon, a menu bar that says XQuartz whichever app you're actually in, and Mission Control stacking them all together.

MSL wanted the windows to belong to the apps. As far as I could find, the only way to get there is to be the X server. So MSL has its own.

**mslgd** is an X11 server written from scratch in Swift: about 13,700 lines across 30 files, with no Xlib and no X.Org code underneath. It speaks the X11 wire protocol directly and draws straight into AppKit and Core Graphics, so every Linux window is a real `NSWindow`. Each Linux app runs in a small process of its own on the Mac side, because macOS gives out exactly one Dock tile per process, and that's what earns every app its own tile, icon, menu bar name, and place in Mission Control and ⌘-Tab.

What it handles today:

- **The core protocol**: windows, pixmaps, graphics contexts, images, properties, selections, and fonts through Core Text.
- **Rendering**: RENDER compositing, glyphs, gradients, trapezoids, transforms and clipping, with SHAPE for windows that aren't rectangles, plus RANDR and BIG-REQUESTS.
- **Input**: XInput 2 including raw motion, trackpad scrolling, middle-click and drags, and XKB keymaps that follow your Mac's keyboard layout and switch when you switch it.
- **Behaving like a Mac app**: the close button asks the app first, so unsaved work gets its "Save changes?", and window icons come from the app itself.
- **Experiments you can switch on**: Linux app menus in the Mac menu bar, ⌘ shortcuts and Mac text navigation inside Linux apps, and a choice of what each Option key means.

A few things it turns out you have to know when you write one of these:

- The 68 predefined atoms have to be seeded by hand. Skip that and `WM_NAME` can never match, so every window title is silently dead code, for months.
- Send one input as both XI2 and core events and every click lands twice. Krita's menus were broken for a very long time because of one doubled click.
- Coverage masks belong in the **alpha** channel, because Core Graphics clips by alpha, not brightness. Get it wrong and a calculator renders like a haunted photocopy.
- AppKit will happily send a mouse Enter with no matching Leave. GTK 4 does not find this funny, and simply stops responding to the mouse.

GTK 3 and 4 apps, Qt apps like Krita, GIMP, LibreOffice, galculator and xeyes all run as Mac windows. It's still the most experimental part of MSL: some apps draw imperfectly, there's no OpenGL, and copy and paste doesn't cross between apps yet. mslgd is the part MSL exists to attempt, rather than a finished claim about how well it does it. Would I do it again? Yes, and I think that's the problem. ( ͡° ᴥ ͡°)

mslgd is also available as [a standalone Swift package](https://github.com/MilkmanAbi/mslgd).

## Getting started

### What you need

- A Mac with Apple silicon (M1 or later) running **macOS 14 Sonoma** or later.
- A little space: a distro is a download of roughly 60 to 230 MB, and a new instance's 15 GB disk only takes up what Linux actually writes.
- Optionally, **e2fsprogs** from Homebrew, for checking and repairing Linux disks from the Mac. MSL tells you when it wants it.

### Install MSL

1. Download **MSL-1.0.0.pkg** from [Releases](../../releases/latest) and open it.
2. The package isn't notarized yet, so the first time, macOS refuses to open it. That's expected. Click **Done**, then open **System Settings ▸ Privacy & Security**, scroll down to the note saying MSL-1.0.0.pkg was blocked, click **Open Anyway**, and confirm with your password or Touch ID. The installer opens and runs normally from there.
3. That's it: **MSL** is in your Applications folder, and the `msl` command is ready in Terminal.

### With the MSL app

1. Open **MSL** and press **⌘N** for a new instance. Give it a name and pick a distribution.
2. Click **Install** in the instance's header to download the distro. Every download is checked against its published checksum before it's used.
3. MSL walks you straight to **Storage** to choose how big the disk should be, then to the **Terminal** tab, where Linux asks you to create your account.
4. Open the **Applications** tab to see the Linux apps inside. Open them, add them to your Applications folder, or pin them to the Dock.

### With Terminal

1. Type `msl` on a fresh Mac and it lists every distribution you can download, with its version and size.
2. Run `msl install debian`. MSL downloads Debian, then asks what to call your instance and how many CPUs, how much memory and how much disk it should have.
3. Run `msl debian`, or whatever you named it. The first start asks you to create your Linux account, and from then on it's straight into your shell.
4. `msl files` opens MSL Files, and `msl help` lists every command and opens the full guide in the app.

### Upgrading and uninstalling

Installing a newer package over an older one keeps every instance, image and setting. `msl uninstall` removes MSL and leaves your Linux exactly where it was, so reinstalling picks up right where you left off, and `msl uninstall --everything` removes all of it. The app can do both too, from **Permissions & Startup**.

## Distributions

| Distribution | Release | Download |
|---|---|---|
| Alpine Linux | 3.24 | 59 MB |
| Debian | 13 "trixie" | 102 MB |
| Ubuntu | 26.04 LTS | 111 MB |
| Kali Linux | Rolling | 118 MB |
| Arch Linux ARM | Rolling | 219 MB |
| Fedora | 44 | 121 MB |
| Rocky Linux | 10.2 | 116 MB |
| AlmaLinux | 10.2 | 120 MB |
| CentOS Stream | 10 | 121 MB |
| Oracle Linux | 10.2 | 130 MB |
| openSUSE Leap | 16.0 | 124 MB |
| Nix | on Debian 13 | 203 MB |

Every image ships with MSL's guest services, git, curl, wget, gcc, make, nano, zsh and sudo, and no usable passwords until you create your own account. Arch here is Arch Linux ARM, since Arch itself has no arm64 port, and Nix is the Nix package manager on Debian rather than NixOS. Want something else? The [MSL Image Builder](https://github.com/MilkmanAbi/msl-image-builder) makes custom images from any arm64 container, built to the same standard.

## Where things stand

This is **MSL 1.0.0**.

**Solid:** installing distros and creating instances, shells in every form, CPU, memory and disk sizing, suspend, hibernate and snapshots, protection when the Mac sleeps or shuts down, the shared home folder, MSL Files, the Sandbox, and disk check and repair.

**Experimental:** Linux GUI apps as Mac windows, and everything in **Window ▸ Experimental Features**. Experiments aren't promises. A future version might build one in properly, change it, or retire it, depending on what people actually want.

## Documentation

- **[MSL-HELP.md](MSL-HELP.md)** is the complete guide that ships inside the app: 77 articles across 13 chapters, from your first instance to repairing a disk, on one page.
- **In the app**, it lives under **Help ▸ MSL Help**, with a search that forgives typos and knows that "RAM" means memory.
- **In Terminal**, `msl help` prints every command.

## The MSL family

| Project | What it is |
|---|---|
| **MSL** | This repository: the app, the `msl` command, the background service and the guest services. |
| [**mslgd**](https://github.com/MilkmanAbi/mslgd) | The X11 server, as a standalone Swift package. |
| [**MSL Files**](https://github.com/MilkmanAbi/MSL-Files) | The file browser, as a standalone app. |
| [**MSL Image Builder**](https://github.com/MilkmanAbi/msl-image-builder) | A friendly terminal app for building your own Linux images for MSL. |
| [**MSL experiments**](https://github.com/MilkmanAbi/msl-experiments) | The code behind Experimental Features, for reference. |
| [**msl-files on SourceForge**](https://sourceforge.net/projects/msl-files/files/) | Where the distribution images are published. |

## Contributing

Bug reports, ideas and pull requests are all welcome, and so is simply telling me what you think in the [community feedback form](https://docs.google.com/forms/d/e/1FAIpQLScJm6KavA6mDJE9ntoH2YPvlsSoEJZaissnvr_b4gG68b3ixA/viewform?usp=dialog). A good bug report says which Mac and macOS version you're on, which distro, what you expected and what happened, and includes what `msl doctor` prints. Logs live in `~/Library/Logs/MSL`.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before joining in. Everyone who has helped is in [CONTRIBUTORS.md](CONTRIBUTORS.md), and if you're pointing an AI coding agent at the repository, [AGENTS.md](AGENTS.md) is written for it (It's made in case anyone wants to explore this project with Agents, considers how... messy it can get?).

<a id="licence"></a>

## Licence

MSL uses two licences, on purpose.

- **mslgd**, the X11 server, is under the **GNU General Public License v3**, along with anything derived from it. It lives in `Sources/MSLCore/X11`, `Sources/MSLCore/X11InputGate.swift`, `Sources/mslgui` and `Guest/init/x11tunnel.c`. It's the hard, stubborn part, and I kinda want it to stay free: use it, change it, ship it, and if you ship changes, share their source. mslgd is nothing compared to the likes of Xquartz etc, yes, but it still took a lot of engineering effort.
- **Everything else** is under the **MIT License**: the app, the `msl` command, the background service, MSL Files, the guest services and all of the virtual machine plumbing. Take it and build whatever you like.

MSL.app and the programs built from this repository include mslgd, so those builds, taken as a whole, are distributed under the GPL v3. The distribution images MSL downloads keep their own upstream licences. The full texts are in [LICENSE](LICENSE) and [LICENSE-MIT](LICENSE-MIT).

## Thanks

<img src="https://raw.githubusercontent.com/MilkmanAbi/MSL/main/Assets/Mascot.png" width="120" align="right" alt="MSL's mascot, a small knight holding the docs">

- **neekocat_2025**, who drew the little guy on the right. He carries the docs around and looks concerned about the kernel panics. Same. ( ˘•ω•˘ )
- **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** by Miguel de Icaza, the terminal inside the app.
- **X.Org and XQuartz**, for decades of X11 to learn from.
- **Every distribution** MSL runs, and the people who build them.
- **You**, for trying a small, stubborn project that set out to make Linux feel at home on a Mac.

<br clear="right">

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/MilkmanAbi/MSL/main/Assets/Abi_Logo-Dark.png">
    <img src="https://raw.githubusercontent.com/MilkmanAbi/MSL/main/Assets/Abi_Logo-Light.png" width="120" alt="Abi">
  </picture>
  <br>
  Made with care, stubbornness and a lot of getting it wrong first. ♡
</p>

<p align="center">
  If you like this, please 🌟 it, it makes me feel fuzzy and nice inside. ૮ ˶ᵔ ᵕ ᵔ˶ ა
</p>
