import Foundation

// Chapter 5. Shells: in the app, in Terminal.app, over SSH, from the command line.

extension HelpChapter {
    static let terminal = HelpChapter(
        id: "terminal", title: "Terminal & Shells", symbol: "terminal", tint: .indigo,
        blurb: "A real Linux shell in the app, in Terminal.app, over SSH, or from the msl command.",
        articles: [.terminalTab, .terminalApp, .linuxUsers, .ssh, .commandLine])
}

extension HelpArticle {
    static let terminalTab = HelpArticle(
        id: "terminal-tab", title: "The Terminal tab", symbol: "terminal",
        summary: "A full terminal inside the window, with a real Linux login shell in it.",
        keywords: ["terminal", "shell", "console", "bash", "command prompt", "end session", "reconnect", "pty", "tty"],
        related: ["terminal-app", "linux-users", "command-line", "idle"],
        body: #"""
        The Terminal tab is a complete terminal with a real Linux shell in it — job control, colours, line editing and
        full-screen programs like `vim` and `htop` all work, because it's a real terminal talking to a real shell.

        ## Opening a shell {#opening}

        Just open the tab. It connects straight away, starting the instance if it isn't running — or click **Terminal**
        in the header from any tab.

        If the instance can't start (every running slot is taken, say), the reason is printed right there in the
        terminal, where you're already looking.

        ## Appearance {#appearance}

        The terminal uses the system's monospaced font and follows light and dark mode with the rest of MSL, rather
        than being a black rectangle in a light window.

        ## The toolbar buttons {#toolbar}

        While the Terminal tab is showing, two buttons appear in the window's toolbar:

        - **End Session** — closes the shell. It sends the same hang-up signal a terminal window sends when you close
          it, so programs inside wind down the way they normally would.
        - **Open in Terminal** — opens another shell on the same instance in Terminal.app. See
          [Using Terminal.app](help:terminal-app).

        ## When the session ends {#ended}

        Type `exit`, or end the session, and a panel appears over the terminal: "Session ended" (or "Session ended
        (exit *n*)" if it ended with an error), and a **Reconnect** button. The scrollback stays visible behind it, so
        anything printed on the way out is still readable.

        ## Sessions keep running {#persistent}

        Each instance has its own terminal session, kept alive in the background. Switch tabs, switch instances, come
        back — the shell is exactly where you left it, scrollback and all. Removing an instance ends its session.

        > [!NOTE] An open shell keeps the instance awake
        > While any shell is open on an instance, it isn't [suspended for being idle](help:idle). When the last one
        > closes, MSL suspends it a few seconds later.
        """#)

    static let terminalApp = HelpArticle(
        id: "terminal-app", title: "Using Terminal.app", symbol: "apple.terminal",
        summary: "Open an instance's shell in Terminal.app, or type msl there yourself.",
        keywords: ["terminal.app", "iterm", "open in terminal", "external terminal", "automation permission", "tabs"],
        related: ["command-line", "terminal-tab", "ssh"],
        body: #"""
        Prefer Terminal.app, or want several shells side by side? Any of these opens a Terminal.app window running a
        shell on the instance:

        - **Open in Terminal.app** in the instance's right-click menu in the sidebar (or the header's Suspend/Resume
          menu).
        - **Open in Terminal** in the toolbar while the Terminal tab is showing.

        > [!NOTE] The first time, macOS asks
        > MSL opens the window by asking Terminal.app to run a command, so the first time macOS asks whether MSL may
        > control Terminal. Allow it. If you said no by accident, turn it back on in **System Settings ▸ Privacy &
        > Security ▸ Automation**.

        ## Or just type it {#typing}

        In any terminal app — Terminal, iTerm, whatever you use — this opens a shell on an instance called `work`:

        ```shell
        msl work
        ```

        Every new tab can do the same; each is its own shell. And one-off commands work like `ssh`:

        ```shell
        msl work uname -a
        msl work ls -la /mnt/mac/Desktop
        ```

        The exit code comes back too, so `msl` fits in scripts. Everything else it can do is in
        [The msl command](help:command-line).
        """#)

    static let linuxUsers = HelpArticle(
        id: "linux-users", title: "Linux users and root", symbol: "person.2",
        summary: "Your everyday Linux user, sudo and its password, root, and the extra 'msl' user.",
        keywords: ["user", "root", "sudo", "username", "password", "account", "admin", "permissions", "-u", "whoami",
                   "forgot password", "reset password", "passwd", "wheel", "sudoers", "administrator"],
        related: ["first-start", "command-line", "ssh"],
        body: #"""
        ## Your default user {#default}

        The first interactive shell on a distro asks you to create a user — see
        [Your first start](help:first-start#user). That user becomes the **default login for the distro**: every shell,
        in the app or out of it, logs in as them.

        It belongs to the distro, not the instance, because instances of a distro share one disk. Set it up once on
        any Debian instance, and every Debian instance has it.

        ## sudo {#sudo}

        Your account is an administrator, the usual Linux way: it's in the distro's admin group — `sudo` on Debian,
        Ubuntu, Kali and Nix, `wheel` on the rest — and `sudo` asks for **its password**:

        ```shell
        sudo apt install gimp
        [sudo] password for abi:
        ```

        After that, `sudo` remembers you for a few minutes, so a run of commands only asks once.

        ## Root {#root}

        From the Mac, `-u` picks the user — and `-u root` needs no password, because the Mac is the machine's owner.
        It's the same escape hatch WSL has with `wsl -u root`:

        ```shell
        msl work -u root
        msl work -u root apk add htop
        ```

        ## Forgot your password? {#forgot-password}

        Set a new one as root, from the Mac:

        ```shell
        msl work -u root passwd abi
        ```

        Replace `abi` with your username. It asks for the new password twice.

        ## One-off commands {#one-off}

        `msl work <command>` runs as the default user too, once there is one — before that, as root.

        ## The msl user {#msl-user}

        Every distro also has an ordinary unprivileged user called `msl`, for when you want a clean account with no
        admin rights: `msl work -u msl`.
        """#)

    static let ssh = HelpArticle(
        id: "ssh", title: "Connecting over SSH", symbol: "network",
        summary: "One command, nothing to configure — for scp, VS Code Remote-SSH, and anything else that speaks SSH.",
        keywords: ["ssh", "scp", "sftp", "vs code", "vscode", "remote ssh", "key", "fingerprint", "port 22", "~/.ssh/config", "msl-"],
        related: ["trouble-ssh", "sandbox-gates", "terminal-app"],
        body: #"""
        The **Connect over SSH** card on the Overview tab gives every instance a ready-made SSH shortcut. MSL does all
        the setup; you get one command:

        ```shell
        ssh msl-work
        ```

        It works anywhere SSH does — a terminal, `scp`, `rsync`, and editors like VS Code's Remote-SSH, which will list
        `msl-work` as a host.

        ## What MSL sets up {#what}

        1. **Its own key**, at `~/Library/Application Support/MSL/ssh/msl_ed25519`. MSL never touches your personal
           `~/.ssh` keys — a key MSL owns can be replaced without affecting anything else you use.
        2. **The key inside Linux**, for your Linux account — so `ssh` logs you in as you. (Before the distro has an
           account, it uses the built-in `msl` one; **Set up again** switches it once yours exists.)
        3. **The SSH server inside Linux**, started.
        4. **A shortcut** — a `Host msl-work` entry in `~/.ssh/config`. Nothing else in that file is touched.

        Then it checks the address actually answers before calling it ready.

        ## Automatically {#automatic}

        **Set this up automatically when an instance starts** (on by default, and it applies to all instances) does all
        of the above whenever an instance starts, so the shortcut is just there. Turn it off and each card offers
        **Set up now** instead, which works while the instance is running.

        ## Reading the card {#card}

        | You see | Means |
        |---|---|
        | "Not set up yet" | Nothing's been done. **Set up now** needs the instance running. |
        | "Setting up…" | Working on it. |
        | Green tick, "Ready." | Checked just now and answering. **Open Terminal** connects in Terminal.app. |
        | Grey clock, "Last known details…" | From the last time it ran — it's checked again once the instance is up. |
        | Orange triangle, "isn't answering on port 22" | Set up, but not reachable right now. |

        Under the command: the **Address** (user and IP), the **Key** path, and the **Host key** fingerprint. **Copy**
        copies the command; **Copy all details** copies everything; **Set up again** redoes it all.

        > [!NOTE] Addresses move; the shortcut follows
        > An instance's address can change between runs. MSL rechecks it at start and rewrites the `~/.ssh/config`
        > entry in place, so `ssh msl-work` keeps working.

        > [!TIP] Not answering?
        > The usual reason is the **Network** gate on the Sandbox tab — cutting it unplugs the network SSH uses. The
        > app's own terminal still works regardless. More in [SSH won't connect](help:trouble-ssh).

        From the command line, `msl ssh work` connects — setting everything up first if it's the first time — and
        `msl ssh work --print` just prints the command.
        """#)

    static let commandLine = HelpArticle(
        id: "command-line", title: "The msl command", symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Everything the app does, from any terminal — and a few things it doesn't.",
        keywords: ["cli", "command line", "msl", "terminal commands", "scripting", "automation", "commands", "usage", "help"],
        related: ["terminal-app", "msl-command", "logs-and-doctor"],
        body: #"""
        The app and the `msl` command are two faces of the same thing: both ask MSL's background service to do the work.
        Anything you do in one shows up in the other. The full list is in the reference —
        [msl command reference](help:msl-command) — but these are the ones you'll use:

        | Command | Does |
        |---|---|
        | `msl work` | A shell on `work`. |
        | `msl work <command>` | Runs one command, like `ssh`. Its exit code comes back. |
        | `msl fedora` | An instance named after a distro just works — no setup needed. |
        | `msl work -u root` | A shell as root. |
        | `msl list` | Every instance. |
        | `msl status work` | Running, suspended or stopped. |
        | `msl suspend work` / `msl resume work` | Freeze and unfreeze. |
        | `msl hibernate work` | Save to disk and stop. |
        | `msl --shutdown work` | Shut Linux down properly. With no name, every running instance. |
        | `msl install debian` | Download a distro. |
        | `msl ssh work` | Connect over SSH, setting it up if needed. |
        | `msl doctor` | Check the installation for problems. See [Logs and msl doctor](help:logs-and-doctor). |

        > [!TIP] Typos are caught
        > `msl lsit` doesn't quietly create an instance called "lsit" — it says "no instance named 'lsit' — did you
        > mean `msl list`?" To really make an instance with an odd name, use `msl new <name>`.

        Run `msl help` for the complete usage.
        """#)
}
