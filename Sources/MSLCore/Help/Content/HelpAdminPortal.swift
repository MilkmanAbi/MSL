import Foundation

// Chapter. The MSL Admin Portal: what it restricts, how strongly, and how
// to read a refusal.

extension HelpChapter {
    static let adminPortal = HelpChapter(
        id: "admin-portal", title: "Admin Portal", symbol: "building.columns", tint: .indigo,
        blurb: "Decide what this Mac is allowed to do with MSL — and say who decided, and why.",
        articles: [.mslap, .mslapSetup, .mslapCapabilities, .mslapStrength,
                   .mslapRefusals, .mslapFleet, .mslapLineage])
}

extension HelpArticle {

    static let mslap = HelpArticle(
        id: "mslap", title: "The MSL Admin Portal", symbol: "building.columns",
        summary: "What an administrator can restrict, and what MSL promises about it.",
        keywords: ["admin", "administrator", "portal", "mslap", "policy", "managed", "restrict",
                   "lock down", "school", "company", "fleet", "it"],
        related: ["mslap-setup", "mslap-capabilities", "mslap-strength"],
        body: #"""
        The Admin Portal — MSLAP — is how a Mac running MSL can be told what it is allowed to do. A school, a
        company, or you on your own Mac can deny particular things: creating instances, reaching the internet,
        sharing the Mac's home folder, copying an image.

        Open it from **Window ▸ MSL Admin Portal**.

        ## Two audiences, one window {#audiences}

        The window is built for two people who want opposite things from it.

        Somebody using a managed Mac opens it to find out **why something refused them**. That is the whole top half:
        who set the policy, what it says, and the reason they wrote. A locked-down tool that will not say why it
        refused is the thing people hate most about managed machines, so MSL always says.

        An administrator opens it to **see the resolved rules** and set them up. That is behind a password.

        @card lock indigo | Nothing is restricted by default | A Mac with no policy installed works exactly as it always did. MSLAP only ever takes things away, and only when somebody installs a policy saying so.

        ## What it is not {#limits}

        MSLAP decides what **MSL** will do. It is not a device management system and does not pretend to be:

        - It cannot stop somebody using a Linux shell inside an instance they are allowed to run. Root inside a guest
          is the guest kernel's business, and nothing on the Mac side can change that — so MSL does not list it as
          something it can restrict.
        - It assumes a Mac being administered by MSLAP is a Mac being administered. If an organisation deploys a
          policy, the person using that Mac is not a local administrator of it — that is what device management is
          for. On your own Mac you are the administrator, and there is nothing to defend against.

        > [!note]
        > Every restriction MSL claims has a place in the code that actually refuses it. A capability that nothing
        > enforces is not listed as enforced — see [What can be restricted](help:mslap-capabilities#honesty).

        ## Where to go next {#next}

        | You want to | Read |
        |---|---|
        | Set it up on this Mac | [Setting it up](help:mslap-setup) |
        | See the full list of switches | [What can be restricted](help:mslap-capabilities) |
        | Know how much a policy really guarantees | [How strong a policy is](help:mslap-strength) |
        | Understand a message that refused you | [Reading a refusal](help:mslap-refusals) |
        | Deploy to more than one Mac | [Managing several Macs](help:mslap-fleet) |
        """#)

    static let mslapSetup = HelpArticle(
        id: "mslap-setup", title: "Setting it up", symbol: "key",
        summary: "An administrator password and a signing key, and what each one is actually for.",
        keywords: ["setup", "set up", "password", "admin password", "signing key", "keygen",
                   "first run", "enrol", "enroll", "install policy"],
        related: ["mslap", "mslap-strength", "mslap-fleet"],
        body: #"""
        Open **Window ▸ MSL Admin Portal** on a Mac with no policy and the window says *This Mac is not managed*,
        with a **Set Up…** button.

        ## The three things, and why they are three {#three}

        Setup asks for a password and makes a key. They do different jobs, and blurring them is how somebody ends up
        believing a password protects a file that anyone can edit.

        | | What it does | What it does not do |
        |---|---|---|
        | **Administrator password** | Unlocks the editing view in this window. | Protect the policy file. Anyone who can read the disk can read the file. |
        | **Signing key** | Makes the policy tamper-evident: edit it and it stops verifying. | Stop it being deleted. |
        | **Where the file lives** | A root-owned location cannot be changed by a non-administrator. | Stop an administrator of the Mac. |

        Only all three together make a policy enforceable. [How strong a policy is](help:mslap-strength) explains
        which rung a given setup is on, and MSL always tells you rather than letting you infer it.

        ## Setting a policy {#policy}

        Unlock with the password and the window lists all the capabilities with a switch each. Turn off what this Mac
        may not do, write a reason — it is shown on every refusal — and apply. MSL signs it and installs it for your
        user.

        That is the **tamper-evident** rung. To go further:

        ```
        msl admin enrol ~/Library/Application\ Support/MSL/policy.json
        ```

        which copies it to `/Library/Application Support/MSL/` as root, where somebody who is not an administrator
        of this Mac cannot change or remove it.

        ## Checking it {#checking}

        ```
        msl admin status
        msl admin status <instance>
        ```

        The first shows the whole policy and its strength; the second resolves it for one instance, which is what
        actually applies when that instance does something.

        > [!tip]
        > Set a policy that denies something harmless first — `system.doctor`, say — and run the command it governs.
        > Seeing the refusal once tells you more about how this works than reading about it.

        ## Undoing it {#undo}

        ```
        msl admin unenrol
        ```

        Removes the policy. If it is in the root-owned location this asks for your Mac password, because that is the
        point of it being there.
        """#)

    static let mslapCapabilities = HelpArticle(
        id: "mslap-capabilities", title: "What can be restricted", symbol: "list.bullet.rectangle",
        summary: "The full list of switches, grouped, and the rule that keeps the list honest.",
        keywords: ["capabilities", "capability", "list", "switches", "deny", "allow", "scope",
                   "instance.clone", "network", "sharing", "what can be blocked"],
        related: ["mslap", "mslap-setup", "mslap-refusals"],
        body: #"""
        A policy is a list of **capabilities** that are denied. Everything not denied is allowed, so a new MSL
        feature is never silently restricted by an old policy.

        ```
        msl admin capabilities
        ```

        prints every one with what it covers and where it is enforced.

        ## The groups {#groups}

        | Group | Covers |
        |---|---|
        | `instance` | Creating, deleting, starting, stopping, renaming, cloning, locking instances |
        | `resources` | Memory, CPUs, disk size, fixed or dynamic memory |
        | `distro` | Installing and removing distros, custom images, where images come from |
        | `shipment` | Importing and exporting `.mslship` files |
        | `network` | The VPN, DNS, the sandbox network gate, the traffic monitor, forwarded ports |
        | `public` | Publishing an instance to the internet, and each backend |
        | `sharing` | The Mac home share, the clipboard, MSL Files, the Finder mount, the file picker |
        | `peripherals` | USB, audio, camera, microphone |
        | `graphics` | GPU acceleration, per-app graphics, scaling |
        | `apps` | Launching Linux apps, launch commands, Launchpad, the Dock, scanning |
        | `integrations` | Links and mail opening on the Mac, the global menu bar, shortcuts, sign-in |
        | `system` | Experimental features, updating, startup, uninstalling, the terminal, SSH, diagnostics |
        | `admin` | Removing or editing the policy itself |

        Denying a group denies everything under it: `network` covers `network.vpn`. Whole segments only — denying
        `net` denies nothing.

        ## Scopes {#scopes}

        A rule applies to `*` or to instance names, including `lab-*`. So a lab Mac can forbid copying the teaching
        image while leaving a student's own instances alone.

        > [!important]
        > Scopes match by **instance name**, so renaming or cloning an instance could escape a rule written about it.
        > MSL refuses a rename or clone that would do that, naming the capability — see
        > [Rename and clone](help:instances-rename#policy).

        ## The honesty rule {#honesty}

        Every capability says where it is enforced:

        | Tier | Means |
        |---|---|
        | **daemon** | `mslhd` refuses the request. Binds the app and the command line alike. |
        | **app** | Refused in the app or CLI, for things the daemon never sees. |
        | **interface only** | A hidden control, and nothing more. |

        That last one is deliberately unflattering, and MSL labels it rather than hiding it. `system.terminal` is
        interface-only: hiding MSL's Terminal tab does not stop anybody typing `msl <instance>` in Terminal.app, and
        the refusal on screen says exactly that.

        **A capability with nowhere that refuses it is not shipped as enforced.** A test walks the whole list against
        the real enforcement sites, so the catalogue cannot drift into a list of promises nothing keeps.
        """#)

    static let mslapStrength = HelpArticle(
        id: "mslap-strength", title: "How strong a policy is", symbol: "shield.lefthalf.filled",
        summary: "Three rungs, what each one actually guarantees, and why MSL tells you which you are on.",
        keywords: ["strength", "advisory", "tamper-evident", "enforceable", "signed", "root",
                   "guarantee", "how strong", "security"],
        related: ["mslap-setup", "mslap", "mslap-fleet"],
        body: #"""
        `msl admin status` prints a **Strength** line, and the panel shows the same. It is measured from the file,
        never inferred from where it sits.

        | Rung | What it means | Someone can still |
        |---|---|---|
        | **Advisory** | A policy the person using the Mac can simply edit. | Change it to whatever they like. |
        | **Tamper-evident** | Signed. It can be deleted, not forged. | Delete it, which is visible. |
        | **Enforceable** | Signed and root-owned. | Nothing, unless they are an administrator of this Mac. |

        ## Why it is measured {#measured}

        A policy under `/Library/Application Support/MSL` is not automatically enforceable: that folder is
        group-writable by admin on some systems, and a policy placed there by an ordinary user would otherwise claim
        the top rung it has not earned. MSL checks the file's owner and permissions and reports what it finds.

        @card checkmark.seal green | Say it, do not imply it | Somebody deploys on the strength of that one line. It is the deployment MSL is least willing to be vague about.

        ## Signing {#signing}

        A signed policy is checked against the public keys this Mac has pinned. Three different failures, reported
        differently, because they mean completely different things:

        | Reported | Means |
        |---|---|
        | not signed | Nobody vouched for it. |
        | signed by a key this Mac has not pinned | Somebody vouched for it, but not somebody you said to trust. |
        | **the signature does not match** | It has been edited since it was signed. |

        ## When a policy is broken {#broken}

        If the policy is present but will not verify, MSL falls back to **the last policy that did verify** rather
        than to no policy at all. Editing a policy to break it must not be a way to remove it.

        It also does not refuse everything on a corrupt file. A machine that fails closed on an unreadable policy is
        a bricked machine, including the owner's ability to fix it — so MSL says so loudly, repeatedly, and keeps
        working on the last good rules.

        ## Local admin mode {#local}

        If you set MSLAP up on your own Mac, the signing key is on that Mac. Anyone with administrator access could
        re-sign a policy. What it still buys is that casually editing it breaks it — which is the whole point for one
        person locking down their own machine. A fleet keeps its key somewhere else entirely; see
        [Managing several Macs](help:mslap-fleet).
        """#)

    static let mslapRefusals = HelpArticle(
        id: "mslap-refusals", title: "Reading a refusal", symbol: "exclamationmark.bubble",
        summary: "What a refusal message tells you, and what to do about it.",
        keywords: ["refused", "refusal", "not allowed", "denied", "blocked", "why", "error",
                   "admin portal does not allow"],
        related: ["mslap", "mslap-capabilities", "mslap-strength"],
        body: #"""
        A refusal looks like this:

        ```
        ERROR refused by MSL Admin Portal: instance.delete is not allowed
        - Ubuntu is the working instance - no deleting it. Set by Abi.
        ```

        Four parts, and each is there on purpose.

        | Part | Why |
        |---|---|
        | `instance.delete` | The exact capability, so you can look it up or ask for it by name. |
        | `is not allowed` | What happened. Nothing was changed. |
        | the reason | Written by whoever set the policy. |
        | `Set by Abi` | Who to ask. |

        A managed Mac that will not say why it refused is the thing people hate most about managed machines, so MSL
        always says all four.

        ## Denied by something broader {#broader}

        Sometimes you will see `(denied by public)`. That means the administrator denied the whole `public` group,
        not that one capability. Useful, because asking for `public.relay` back when the whole group is denied is
        the wrong conversation.

        ## Things that are never refused {#never}

        Anything that makes the Mac **less** exposed goes through, whatever the policy says:

        - Unpublishing an instance, removing an authorised key, forgetting a notification address
        - Closing a forwarded port, detaching a USB device
        - Locking an instance, removing a peripheral share, turning startup off
        - Clearing a per-app launch command

        Otherwise denying a capability after somebody had already turned something on would trap it on, with no way
        back. Queries are never refused either: you can always read what the rules are.

        ## In the app {#app}

        The same thing in a window: a control that a policy forbids is disabled with the reason as its tooltip, or
        the panel explains it where the control would be. The reason is always the administrator's own words.
        """#)

    static let mslapFleet = HelpArticle(
        id: "mslap-fleet", title: "Managing several Macs", symbol: "square.stack.3d.up",
        summary: "Sign on one machine, deploy to many, and keep the key off them.",
        keywords: ["fleet", "several", "multiple macs", "deploy", "company", "school", "mdm",
                   "pin", "public key", "rollout"],
        related: ["mslap-strength", "mslap-setup", "mslap-lineage"],
        body: #"""
        Local admin mode keeps the signing key on the Mac it manages, which is fine for one person and wrong for an
        organisation. For several Macs, keep the private key on a machine you control and give each Mac only the
        public half.

        ## On the machine that holds the key {#authoring}

        ```
        msl admin keygen
        msl admin sign policy.json
        ```

        `keygen` prints the public key. Keep the private half here and nowhere else.

        ## On each managed Mac {#deploying}

        ```
        msl admin pin <base64-public-key>
        sudo msl admin enrol policy.json
        ```

        `pin` says "trust policies signed by this key". `enrol` puts the policy in the root-owned location. Those two
        together are what the **Enforceable** rung means.

        @card key.horizontal indigo | The key never arrives | A Mac that has only the public half can verify a policy and cannot create one. That is the difference between a fleet deployment and a local one, and it is the whole reason to do it this way.

        ## Updating a policy {#updating}

        Sign a new one and enrol it. Macs pick it up on the next check — nothing needs reinstalling, and an
        instance that is running keeps running.

        ## What this does not need {#nomdm}

        No server, no agent, no account. A policy is one signed JSON file; getting it onto the Macs is whatever you
        already use for files — your MDM's file deployment, a script, a shared drive.
        """#)

    static let mslapLineage = HelpArticle(
        id: "mslap-lineage", title: "Certifying and withdrawing an image", symbol: "checkmark.seal",
        summary: "Sign a statement that an image is yours, or that it is retired.",
        keywords: ["certify", "revoke", "withdraw", "lineage", "certificate", "image", "retired",
                   "leaked", "company image", "blessed"],
        related: ["instances-identity", "mslap-fleet", "instances-protect"],
        body: #"""
        An instance carries a signed **lineage** saying where it came from — see
        [Where an instance came from](help:instances-identity). A lineage certificate is you saying something about
        one of those lineages.

        ```
        msl admin certify <instance|lineage> --label "Acme Standard Image 2026"
        msl admin revoke  <instance|lineage> --reason "leaked"
        ```

        You can name an instance rather than hunting for its lineage.

        ## Why this one is different {#unforgeable}

        An instance's own identity is signed by a key on the Mac that made it. A certificate is signed by your
        **MSLAP key**, which a fleet keeps somewhere else — so nobody holding only one of your Macs can make one.
        It is the only part of this that holds even on a Mac you no longer trust.

        ## Certifying {#certify}

        A certificate says *this image is ours*. Combined with denying `instance.acceptUncertified`, a Mac will run
        only images you have signed for.

        ## Withdrawing {#revoke}

        A revocation says *this image is retired*. Every instance of that lineage then refuses to start, and
        **no capability can set that aside** — a revocation a policy could override would be no revocation at all.

        > [!warning]
        > A withdrawn image stops starting on every Mac the certificate reaches. The instances are not deleted and
        > their files are untouched, but nobody can boot them until the certificate is removed.

        ## Deploying one {#deploy}

        `certify` writes the file under your own Library. For a fleet, copy it to each Mac at
        `/Library/Application Support/MSL/lineages/` with `sudo`, where somebody who is not an administrator cannot
        add or remove one. `msl identity <instance>` says whether the certificate it found is root-owned or merely
        advisory.
        """#)
}
