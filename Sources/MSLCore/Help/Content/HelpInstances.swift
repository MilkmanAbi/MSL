import Foundation

// Chapter. Managing instances themselves: renaming, copying, where one came
// from, keeping one from being copied, and reaching into one over a port.

extension HelpChapter {
    static let instances = HelpChapter(
        id: "instances", title: "Managing Instances", symbol: "square.on.square", tint: .teal,
        blurb: "Rename and copy them, see where one came from, seal one shut, and reach a port inside.",
        articles: [.instancesRename, .instancesIdentity, .instancesProtect, .instancesForward,
                   .instancesCustomCommand])
}

extension HelpArticle {

    static let instancesRename = HelpArticle(
        id: "instances-rename", title: "Renaming and copying", symbol: "square.on.square",
        summary: "Give an instance another name, or make a second one from it.",
        keywords: ["rename", "clone", "copy", "duplicate", "second instance", "name",
                   "msl rename", "msl clone"],
        related: ["instances-identity", "mslap-capabilities", "instances-protect"],
        body: #"""
        ```
        msl rename <instance> <new name>
        msl clone  <instance> <new name>
        ```

        **Rename** moves everything: the disk, accounts, files, resource settings, sandbox gates, per-app graphics
        and launch commands, port forwards, the lot. **Clone** makes a second instance from the first — its disk is
        an instant copy, so it costs almost nothing until the two start to differ.

        ## Both need the instance stopped {#stopped}

        Copying a filesystem while something is writing to it captures it mid-write, which is the same corruption as
        two instances sharing one disk. So both refuse a running instance and say so.

        ## Renaming cannot carry saved memory {#hibernate}

        A rename is refused while an instance has hibernated memory or a snapshot, and the reason is worth knowing:
        **a guest's network address is derived from its name**, and macOS will not restore a saved virtual machine
        whose address has changed. Renaming anyway would produce an unhelpful error on the next start, so MSL asks
        you to start it once — which uses the saved state up — and delete any snapshots first.

        A clone is unaffected: the original keeps its name, and the copy starts cold.

        ## What a clone keeps, and what it does not {#clone-keeps}

        | Kept | Not kept |
        |---|---|
        | Files, accounts, installed packages | The original's name, obviously |
        | Resource settings, sandbox gates, per-app settings | Its SSH record — `msl ssh` rebuilds it |
        | Its place in the family it came from | Saved memory and snapshots |

        The copy keeps the original's SSH host key until the guest makes a new one, so `msl ssh` may warn about a
        changed key the first time.

        ## Launchpad and the Dock {#apps}

        Renaming **removes** the instance's generated app shortcuts and Dock pins rather than rewriting them. A
        generated app launches an instance by name, so one left pointing at a name that no longer exists would
        quietly bring that instance back as an empty new one. Open the Applications tab after a rename and they are
        scanned again.

        ## Under a policy {#policy}

        Rules are written about instance names, so renaming or cloning out of a rule would be a way around it. MSL
        refuses that, and names the capability:

        ```
        ERROR refused by MSL Admin Portal: instance.delete is denied for 'Ubuntu'
        but not for 'Ubuntu2', so this would be a way around it
        ```

        Moving **into** a more restricted name is fine — that takes things away, not back.
        """#)

    static let instancesIdentity = HelpArticle(
        id: "instances-identity", title: "Where an instance came from", symbol: "signature",
        summary: "Every instance carries a signed record of its origin, and MSL can tell a copy from an original.",
        keywords: ["identity", "lineage", "provenance", "origin", "copy", "original", "generation",
                   "msl identity", "where did this come from"],
        related: ["instances-rename", "mslap-lineage", "instances-protect"],
        body: #"""
        ```
        msl identity [instance]
        ```

        Every instance is given a signed identity when it is created. It records the family it belongs to, how many
        times it has been copied, and the name it was born under.

        ```
        Ubuntu: an original
              lineage   vtp6ismgxwsxmj4kcmvx7hojug
              copies    0 (0)
              born as   Ubuntu on machine b8072e055c9775b6
        ```

        A copy says `copy 0.1 of its lineage` and keeps its parent's lineage, so a family stays recognisable however
        far it spreads. The dots are the copies: `0.1.2` is the second copy of the first copy of an original.

        ## What it is for {#why}

        Denying `instance.clone` stops the Clone button. It does not stop somebody copying a disk file by hand, or
        exporting a shipment where copying is allowed and importing it where it is not. An identity makes those
        answerable: a copy that arrives any other way still carries the family it came from, and a Mac can refuse it.

        ## What MSL notices {#notices}

        | | What you see |
        |---|---|
        | A copied disk with a new registry entry | `no identity recorded` — it makes no claim to be an original |
        | A copied identity file too | `ALSO CLAIMED BY …` — two instances cannot be the same instance |
        | An edited identity | `the signature does not match` |
        | An imported shipment | arrives as a copy, one generation deeper |

        ## The marker inside the guest {#marker}

        MSL also writes the identity to `/etc/msl-instance` inside the instance. The host record does not travel
        with a disk; that does. If somebody swaps the disk under a name whose identity is perfectly valid, the two
        disagree and MSL says so.

        A **missing** marker is reported and never rewritten. Writing it back would stamp this instance's identity
        onto whatever disk is actually there, which is the exact thing the marker exists to catch. If you know the
        disk is right — a cleanup removed the file, say — put it back deliberately:

        ```
        msl identity <instance> --rewrite-marker
        ```

        > [!note]
        > Instances made before this existed have no identity, and nothing refuses them. MSL gives identities to
        > whatever is on the Mac once, when the feature arrives, and records that it did — so an instance turning up
        > without one afterwards is a different and more interesting fact.
        """#)

    static let instancesProtect = HelpArticle(
        id: "instances-protect", title: "Protecting an image", symbol: "lock.doc",
        summary: "Put an instance's disk in an encrypted container, so a copy of the file is useless.",
        keywords: ["protect", "encrypt", "encrypted", "container", "vault", "unprotect",
                   "msl protect", "copy", "leak", "secure"],
        related: ["instances-identity", "mslap-lineage", "sandbox-gates"],
        body: #"""
        ```
        msl protect   <instance>
        msl unprotect <instance>
        ```

        Moves the instance's disk into an encrypted container. A copy of the file — on a USB stick, in a backup, in
        a support upload — is then useless on any other Mac.

        ## What it costs {#cost}

        A real copy of the whole disk, because MSL's instant-copy trick cannot cross into a container. Minutes for a
        large instance, and that much free space while it runs. Opening it at start is well under a second.

        The original is removed **only after** the copy inside has been read back and checked, so there is no moment
        where both are gone.

        ## What it does and does not buy {#limits}

        | Closed | Still open |
        |---|---|
        | Dragging the disk to a USB stick, AirDrop, email | Anything inside the instance, to anyone who can open a shell in it |
        | Time Machine and every backup service copying it in the clear | An administrator of this Mac, who can reach the key |
        | A guest copying it out of `/mnt/mac` | |

        That last one is worth its own sentence. **The Mac's home folder is shared into every instance, writable**,
        and instance disks live inside it — so any Linux terminal can copy any instance's disk unless you deny
        `sharing.macHome`. `msl doctor` says so if you have asked for an image to be protected and left that open.

        @card lock.shield orange | Protection is a consequence, not a switch | Deny `instance.clone` or `shipment.export` for an instance and MSL treats it as one you mean to keep uncopyable, and reports anything still open.

        ## A key only you hold {#adminheld}

        ```
        msl vault <instance> status | adopt | unlock | lock
        ```

        By default the key is derived from a secret on this Mac, which closes every accidental route but not a
        determined administrator of it. **Adopt** moves the container to a passphrase you type instead. After that
        nothing on the Mac can open it until somebody supplies it, including MSL after a reboot.

        > [!danger]
        > There is no recovery. If the passphrase is lost, the disk is unreadable permanently — MSL keeps only a
        > wrapped copy of the key, and that is the entire point of this mode.

        Saved memory from hibernating goes inside the container too. A `.state` file is the guest's whole RAM, and
        encrypting the disk while leaving that beside it in the clear would protect very little.
        """#)

    static let instancesForward = HelpArticle(
        id: "instances-forward", title: "Reaching a port inside Linux", symbol: "arrow.left.arrow.right",
        summary: "Open a port on your Mac that reaches a server running in an instance.",
        keywords: ["forward", "port", "localhost", "server", "development", "web server",
                   "msl forward", "unforward", "3000", "8080"],
        related: ["instances-rename", "public-what", "sandbox-gates"],
        body: #"""
        ```
        msl forward <instance> 8080:3000
        msl forward <instance> list
        msl unforward 8080
        ```

        `localhost:8080` on your Mac then reaches port 3000 inside the instance — so a development server in Linux
        opens in a Mac browser. One number means the same port both sides.

        The port is bound to your Mac only. Nothing else on the network can see it.

        ## Two routes, and why you may need the second {#routes}

        | Route | Reaches |
        |---|---|
        | the default | A server bound to `0.0.0.0` inside the guest |
        | `--ssh` | Everything, including one bound to `127.0.0.1` |

        Most development servers bind `127.0.0.1` by default — Flask, Vite, Rails and `manage.py runserver` all do —
        and nothing outside the guest can reach a loopback socket. So if the default route connects to nothing, add
        `--ssh`: it goes through the instance's own SSH server, which makes the connection from inside.

        MSL checks when you set one up and tells you which to use rather than leaving you with a connection that
        resets.

        ## They come back {#persist}

        A forward is remembered and restored when the instance next starts. `list` shows which are live and which
        are waiting:

        ```
        localhost:8080  ->  work:3000
        localhost:9000  ->  work:5432 through SSH  (not running - starts with the instance)
        ```

        ## What it will not do {#limits}

        - A forward does not keep an instance awake. An idle instance still suspends, and the listener is taken down
          with it so a request is refused at once rather than hanging. It comes back when the instance does.
        - It is refused while the instance is sandboxed. A forwarded port is a hole in exactly the box those gates
          draw — see [The four gates](help:sandbox-gates).
        - Ports below 1024 are reserved by macOS and MSL cannot bind them.
        """#)

    static let instancesCustomCommand = HelpArticle(
        id: "instances-custom-command", title: "Changing how an app starts", symbol: "terminal",
        summary: "Replace the command MSL runs for one Linux app.",
        keywords: ["custom command", "launch command", "arguments", "app won't start", "love",
                   "mari0", "environment variable", "right click"],
        related: ["apps-tab", "add-to-applications", "instances-rename"],
        body: #"""
        Right-click an app in the **Applications** tab and choose **Custom Launch Command** to replace what MSL runs
        when you open it.

        Some apps simply will not start from their own desktop entry without help: a game that needs a particular
        build of its engine, a binary that wants an environment variable set, an app whose packaged entry points at
        the wrong path. Those are one-line fixes if you can edit the command, and otherwise they are "this app does
        not work on MSL".

        ## Examples {#examples}

        ```
        love11 /opt/mari0
        GDK_BACKEND=x11 inkscape
        /opt/thing/bin/thing --no-sandbox
        ```

        It runs in the same environment MSL would have used, so the display, the session bus and the graphics mode
        are all already set up.

        ## It applies everywhere {#everywhere}

        The override is keyed to the app's **original** command, so it follows the app whether you open it from the
        Applications tab, a generated app in Launchpad, the Dock, or `msl gui-native`. Changing it in one place
        changes it everywhere, and clearing it puts the app back to its own command.

        > [!warning]
        > This runs an arbitrary command inside the instance, so an administrator can deny it with
        > `apps.customCommand`. **Clearing** one is always allowed — otherwise a policy arriving after somebody set
        > an override would trap it in place.
        """#)
}
