import Foundation

// Chapter 14. Reaching an instance from outside the Mac.

extension HelpChapter {
    static let publicAccess = HelpChapter(
        id: "public", title: "Reaching it from anywhere", symbol: "globe", tint: .teal,
        blurb: "Publish an instance's SSH so another computer, on another network, can log in.",
        articles: [.publicWhat, .publicPublishing, .publicKeys, .publicEmail, .publicServer, .publicSafety])
}

extension HelpArticle {
    static let publicWhat = HelpArticle(
        id: "public-what", title: "What publishing does", symbol: "globe",
        summary: "Gives an instance an address that works from any computer, anywhere.",
        keywords: ["public", "internet", "remote", "ssh", "expose", "publish", "server", "mini server",
                   "away", "another computer", "another network", "tunnel"],
        related: ["public-publishing", "public-keys", "ssh"],
        body: #"""
        MSL's normal SSH gets you into an instance **from this Mac**. Publishing gets somebody in **from
        anywhere** — a laptop on another network, a phone, a colleague's machine.

        That turns an instance into a small server: something you leave running and reach when you need it.

        ```
        msl public expose Ubuntu
        ```

        You get back an address and the command to use it:

        ```
        abinaash@mlisv-218-212-52-212.run.pinggy-free.link:38003
        ```

        Anyone with that address, and a key you've allowed, can log in with ordinary `ssh`. **They need no
        account, no MSL, and nothing installed** — which is the whole point of doing it this way.

        ## How it works {#how}

        The tunnel runs **on your Mac**, not inside the instance. MSL already reaches the guest's SSH port on
        your local network, so it forwards that through a relay and out to the internet. The instance itself
        is never changed to make this work, and nothing is installed in it.

        ## What it costs {#limits}

        By default MSL uses a free public relay, which means two honest limits:

        | | Free relay | Your own server |
        |---|---|---|
        | Address | Random, and changes | Yours, and stays |
        | Session | About an hour, then renewed at a new address | No limit |
        | Needs | Nothing | A machine you can already `ssh` to |

        The free relay is right for *"let me show you this"*. For something you actually depend on, publish
        through a server you own — see [Through your own server](help:public-server).

        > [!NOTE] The Mac has to stay awake
        > While anything is published, MSL stops your Mac going to sleep on its own, and keeps the instance
        > from hibernating. Closing the lid still sleeps it — a laptop in a bag is not a server. MSL reconnects
        > when it wakes, at a new address if it is using the free relay.
        
        ## Just reaching it from this Mac {#local}

        If you only want a server inside Linux to open in a browser on this Mac, you do not need any of this —
        see [Reaching a port inside Linux](help:instances-forward).

        """#)

    static let publicPublishing = HelpArticle(
        id: "public-publishing", title: "Publishing and stopping", symbol: "globe.badge.chevron.backward",
        summary: "One command or one button, and the same to undo it.",
        keywords: ["publish", "expose", "revoke", "stop", "unpublish", "msl public", "reach this from anywhere"],
        related: ["public-what", "public-keys", "public-safety"],
        body: #"""
        ## In the app {#app}

        Select the instance, and look for **Reach this from anywhere** under the SSH card. Press **Publish…**,
        confirm, and the address appears. **Stop** puts everything back.

        ## From the command line {#cli}

        | Command | What it does |
        |---|---|
        | `msl public expose <instance>` | Publishes it, and prints the address |
        | `msl public status <instance>` | Shows the current address |
        | `msl public revoke <instance>` | Stops publishing, and undoes the changes |
        | `msl public keys <instance>` | Lists the computers allowed in |
        | `msl public authorize <instance> <key.pub>` | Lets another computer in |

        `msl public expose` asks for confirmation first. Add `--yes` in a script.

        ## It stays published {#persistence}

        Publishing survives restarts. If you shut the Mac down with an instance published, MSL starts that
        instance and publishes it again when it comes back — because a machine you are using as a server
        should come back *as a server*, without you being there.

        With the free relay the address will be a different one, so check `msl public status` after a restart.

        ## It repairs itself {#reconnecting}

        A free relay ends each session after about an hour. MSL notices and opens a new one, so the instance
        stays published — at a new address each time. The app shows **Published, but not reachable this
        moment** during the handover rather than showing you an address that no longer works.

        ## Stopping {#stopping}

        `msl public revoke` closes the tunnel, deletes the drop-in MSL added to the SSH server, and removes
        the key MSL made for your Mac. Keys you authorized stay, because those are the list of people allowed
        into that instance, and losing them because a tunnel closed would be the wrong thing to do. Remove
        them with `msl public deauthorize`.
        """#)

    static let publicKeys = HelpArticle(
        id: "public-keys", title: "Letting another computer in", symbol: "key",
        summary: "Each computer keeps its own key; you paste its public half.",
        keywords: ["key", "keys", "authorize", "authorise", "public key", "id_ed25519", "ssh-keygen",
                   "another laptop", "colleague", "team", "allow"],
        related: ["public-publishing", "public-safety"],
        body: #"""
        A published instance accepts **keys only**. Passwords are turned off before anything is published.

        MSL makes one key for the Mac doing the publishing, so you can get in straight away. **That key does
        not survive a restart, on purpose** — it is stored outside your home folder where no instance can read
        it, and that place is cleared when the Mac restarts.

        For any computer you actually intend to use, authorize *its* key instead.

        ## On the other computer {#other}

        Get its public key. If it has none:

        ```
        ssh-keygen -t ed25519
        cat ~/.ssh/id_ed25519.pub
        ```

        That prints one line starting `ssh-ed25519`. That line is public — it is safe to email, paste in chat,
        or put in a ticket.

        ## On this Mac {#here}

        ```
        msl public authorize Ubuntu ~/their-laptop.pub work-laptop
        ```

        Or paste it into the app: **Reach this from anywhere ▸ Let another computer in…**

        > [!WARNING] Never send a private key
        > The file *without* `.pub` is the private half, and it should never leave the computer it was made on.
        > MSL refuses one if you paste it by mistake.

        ## Who can get in {#roster}

        ```
        msl public keys Ubuntu
        ```

        Each line shows a name and a fingerprint. Remove one with:

        ```
        msl public deauthorize Ubuntu work-laptop
        ```

        This is also how you'd run an instance for a team: one key each, each removable on its own.
        """#)

    static let publicEmail = HelpArticle(
        id: "public-email", title: "Emailing the address out", symbol: "envelope",
        summary: "MSL can email the address to whoever needs it, so nobody has to ask you.",
        keywords: ["email", "notify", "resend", "address changed", "rotate", "colleague",
                   "invite", "api key", "domain", "send"],
        related: ["public-what", "public-keys", "public-publishing"],
        body: #"""
        On the free relay the address changes about once an hour. Rather than you fielding "what's the
        address now?", MSL can email it.

        Each person gets **their own key** the first time, attached to the email, with the exact
        commands. After that they only get a short note when the address moves — same key, new port.

        ## Setting it up {#setup}

        MSL sends through [Resend](https://resend.com), which is free.

        1. Make an account
        2. **Verify a domain you own** at resend.com/domains
        3. Make an API key at resend.com/api-keys
        4. `msl public notify setup`

        Then add people:

        ```
        msl public notify add Ubuntu sam@work.com Sam
        ```

        Or in the app: **Reach this from anywhere ▸ Email the address to someone…**

        > [!IMPORTANT] A domain is required to email anyone else
        > This is Resend's rule, not MSL's. Their free sender (`onboarding@resend.dev`) can only
        > deliver to the address your *own* Resend account uses. With a domain verified — the free
        > plan includes one — you can email anybody. Without one you can still set this up to email
        > yourself, which is useful on its own, since you're the person being asked.

        ## What gets sent {#emails}

        | When | What they get |
        |---|---|
        | You add them, or first publish | Their key attached, `chmod 600`, and the `ssh` line |
        | The address changes | Just the new command — nothing to save |

        Nobody gets an endless drip: rotation emails are capped per person per day, and the cap lifts
        once somebody actually connects.

        ## Where the API key is kept {#key}

        In `/Users/Shared/MSL`, readable only by you.

        Deliberately **not** in Application Support: MSL shares your whole home folder into every
        instance as `/mnt/mac`, so a key there could be read from inside any Linux instance.
        `/Users/Shared` sits outside that share.

        ## Commands {#commands}

        | Command | What it does |
        |---|---|
        | `msl public notify setup` | Connect Resend |
        | `msl public notify test <you@…>` | Prove it works before anyone relies on it |
        | `msl public notify add <instance> <email> [name]` | Email this person the address |
        | `msl public notify list <instance>` | Who's on the list |
        | `msl public notify remove <instance> <email>` | Stop emailing them |
        | `msl public notify forget` | Remove the Resend setup entirely |

        Taking somebody off the list does **not** revoke their key — that's
        [`msl public deauthorize`](help:public-keys#roster), so the two are never confused.
        """#)

    static let publicServer = HelpArticle(
        id: "public-server", title: "Through your own server", symbol: "server.rack",
        summary: "An address that is yours and does not change.",
        keywords: ["self-hosted", "vps", "own server", "via", "stable address", "GatewayPorts",
                   "permanent", "always on", "domain"],
        related: ["public-what", "public-publishing"],
        body: #"""
        The free relay changes your address about once an hour. If you want one that stays put, publish
        through a machine you already have — a cheap VPS, a box at the office, anything with a public address.

        ```
        msl public expose Ubuntu --via=root@my.server.com:2222
        ```

        People then connect to `my.server.com` on port **2222**, and land in your instance.

        ## What the server needs {#requirements}

        **That you can already `ssh` to it.** MSL runs `ssh` as you, so your own config, keys and agent apply
        exactly as they do when you type it yourself. There is no MSL account, nothing to install, and no
        credential for MSL to keep.

        One setting on that server matters. In its `/etc/ssh/sshd_config`:

        ```
        GatewayPorts yes
        ```

        Without it, SSH binds the forwarded port to the server's *own loopback* and nobody else can reach it —
        the tunnel works perfectly and answers no one. MSL checks the port really answers before telling you it
        published, and says so if this is why it didn't.

        > [!NOTE] Pick a port above 1024
        > Ports below 1024 need root on that server, and its SSH won't bind one for an ordinary account.

        ## What you get {#benefits}

        | | |
        |---|---|
        | Address | Fixed — put it in `~/.ssh/config`, give it to people, point a name at it |
        | Expiry | None |
        | In the path | Only your own machine |
        """#)

    static let publicSafety = HelpArticle(
        id: "public-safety", title: "What MSL changes to keep it safe", symbol: "lock.shield",
        summary: "Password logins off, keys only, and nothing you cannot undo.",
        keywords: ["safety", "security", "hardening", "password", "brute force", "risk", "safe",
                   "sshd_config", "locked out"],
        related: ["public-what", "public-keys", "public-publishing"],
        body: #"""
        A port 22 that faces the internet starts receiving automated password guessing within minutes. MSL's
        instances ship with password logins **on**, which is fine on your own network and not fine on a public
        address — so publishing changes that first.

        ## What it changes {#changes}

        MSL writes one file in the instance, `/etc/ssh/sshd_config.d/00-msl-public.conf`:

        | Setting | Why |
        |---|---|
        | `PasswordAuthentication no` | Password guessing becomes pointless |
        | `KbdInteractiveAuthentication no` | The same thing by another name |
        | `PermitRootLogin prohibit-password` | root by key only, never by password |
        | `MaxAuthTries 3` | Fewer guesses per connection |
        | `LoginGraceTime 20` | Connections that never log in get dropped |
        | `AllowAgentForwarding no`, `AllowTcpForwarding no` | A borrowed key reaches less |

        Then it **asks the SSH server what it actually believes**, rather than trusting that writing the file
        was enough. If passwords are somehow still on, MSL refuses to publish and tells you. Writing a setting
        and having it take effect are not the same thing, and this is the difference between secured and
        apparently secured.

        ## What someone who logs in can reach {#reach}

        More than the Linux machine. MSL puts **your Mac's home folder inside every instance**, at
        `/mnt/mac`, and it is writable — that's what makes Linux apps able to open your Documents and
        save back to them.

        An SSH login has exactly the same access an app in that instance does. So publishing an
        instance shares those files with whoever you let in, and the people you authorize should be
        people you would hand your Mac to.

        Worth knowing before you hand out an address. It is not something MSL changes for you.

        ## You cannot be locked out {#never-locked-out}

        None of this can shut you out of your own instance. `msl <instance>` does not use SSH at all — it
        reaches the guest by a private channel between the Mac and the virtual machine. A lost key costs you a
        *remote* login, never the machine.

        ## What stays yours {#privacy}

        The tunnel's own connection is kept away from your `~/.ssh` entirely: MSL does not read your config
        and does not offer your private keys to a relay.

        ## What MSL cannot promise {#honest-limits}

        - **A free relay is somebody else's machine.** Your SSH session is encrypted end to end inside it, so
          the relay cannot read it — but it can see that a connection exists. Use your own server if that
          matters.
        - **A closed lid still sleeps the Mac**, and a sleeping Mac answers nothing.
        - **Anyone with the address can try.** They will not get in without a key you allowed, but they can
          try.
        """#)
}
