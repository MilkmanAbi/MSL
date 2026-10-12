import Foundation

/// One thing an MSLAP policy can deny.
///
/// A dotted path, so denying `network` denies everything beneath it. Held
/// as a string rather than an enum on purpose: a policy written for a newer
/// MSL will name capabilities this build has never heard of, and those must
/// survive a load/save round trip instead of being silently dropped. The
/// known ones are in `MSLAPCapability.catalogue`.
public struct MSLAPCapability: Hashable, Codable, Sendable, CustomStringConvertible {
    public let key: String

    public init(_ key: String) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    public var description: String { key }

    /// Whether denying `self` also denies `other` - true when `self` is
    /// `other` or one of its dotted ancestors. `network` covers
    /// `network.vpn`; `net` covers nothing, because segments are whole.
    public func covers(_ other: MSLAPCapability) -> Bool {
        key == other.key || other.key.hasPrefix(key + ".")
    }

    /// Where a denial is actually enforced. A capability's tier is a claim
    /// about the code, not a label: see `MSLAPCapability.Entry`.
    public enum Tier: Int, Codable, Sendable, Comparable {
        /// `mslhd` refuses the request. The only tier that binds BOTH the
        /// app and the CLI, because both reach MSL through the daemon.
        case daemon = 1
        /// Enforced in the app or CLI process, for host-side state the
        /// daemon never sees.
        case hostProcess = 2
        /// A hidden or disabled control, and nothing more.
        case interfaceOnly = 3

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .daemon: return "daemon"
            case .hostProcess: return "app"
            case .interfaceOnly: return "interface only"
            }
        }
    }

    /// A catalogue entry: what the capability is, and where denying it bites.
    public struct Entry: Sendable {
        public let capability: MSLAPCapability
        public let title: String
        public let detail: String
        public let tier: Tier
        /// False while the enforcement site does not exist yet, so
        /// `msl admin status` can say "listed, not yet enforced" instead of
        /// implying a guarantee. **A capability must never ship as enforced
        /// without the code that refuses it** - see README 30 §5.
        public let enforced: Bool
        /// True when MSL has no such action yet, so there is nothing to
        /// refuse.
        ///
        /// Distinct from `enforced == false`, which means the action
        /// exists and is not gated. An administrator reading the list
        /// needs to tell "this does nothing because MSL cannot do it" from
        /// "this does nothing because we have not wired it" - the first is
        /// a placeholder, the second is a gap.
        public let unavailable: Bool

        public init(_ key: String, _ title: String, _ detail: String,
                    tier: Tier, enforced: Bool = false, unavailable: Bool = false) {
            self.capability = MSLAPCapability(key)
            self.title = title
            self.detail = detail
            self.tier = tier
            self.enforced = enforced
            self.unavailable = unavailable
        }
    }

    /// Everything MSLAP knows how to deny.
    ///
    /// Derived from MSL's real surface - the CLI verbs, the daemon's
    /// control protocol and the app's panels - not invented. Every entry
    /// starts `enforced: false` and flips to true in the commit that adds
    /// its refusal, which keeps the catalogue honest about what it does.
    ///
    /// Deliberately absent: denying root INSIDE a guest. That is the guest
    /// kernel's business and cannot be enforced from the host, so listing
    /// it would promise something nobody can keep.
    public static let catalogue: [Entry] = [
        // MARK: instance
        Entry("instance.create", "Create instances", "Make a new instance of any distro.", tier: .daemon, enforced: true),
        Entry("instance.delete", "Delete instances", "Remove an instance and its disk.", tier: .daemon, enforced: true),
        Entry("instance.rename", "Rename instances",
              "Change an instance's name, carrying its disk and settings with it.",
              tier: .daemon, enforced: true),
        Entry("instance.clone", "Clone instances",
              "Duplicate an instance - its disk, accounts and settings - under a new name.",
              tier: .daemon, enforced: true),
        Entry("instance.start", "Start instances", "Boot an instance.", tier: .daemon, enforced: true),
        Entry("instance.stop", "Stop instances", "Shut an instance down.", tier: .daemon, enforced: true),
        Entry("instance.suspend", "Suspend instances", "Pause a running instance.", tier: .daemon, enforced: true),
        Entry("instance.hibernate", "Hibernate instances", "Save an instance's memory to disk.", tier: .daemon, enforced: true),
        // The only capability the identity work adds. Everything else it
        // enforces rides on `instance.clone`, which is what was asked for:
        // one switch blocks the button AND refuses a copy that arrived some
        // other way.
        Entry("instance.acceptUnidentified", "Run instances with no provenance",
              "Start an instance MSL has no identity for - everything made before this "
              + "version, and anything that appeared without coming through MSL. Allowed "
              + "by default; deny it only on a fleet where every instance has been issued one.",
              tier: .daemon, enforced: true),
        Entry("instance.acceptUncertified", "Run uncertified images",
              "Start an instance whose lineage carries no certificate from this "
              + "deployment's administrator. Allowed by default; deny it on a fleet that "
              + "should run only images the administrator has signed for. A certificate is "
              + "signed OFF this Mac, so nobody here can mint one.",
              tier: .daemon, enforced: true),
        Entry("instance.lock", "Change the instance lock", "Lock or unlock an instance.", tier: .hostProcess, enforced: true),
        Entry("instance.appearance", "Change appearance", "Instance logo, colour and personality.", tier: .hostProcess, enforced: true),

        // MARK: resources
        Entry("resources.edit", "Change resources", "Any change to memory, CPUs or disk.", tier: .hostProcess, enforced: true),
        Entry("resources.memory", "Change memory", "Memory assigned to an instance.", tier: .hostProcess, enforced: true),
        Entry("resources.cpu", "Change CPUs", "CPU count assigned to an instance.", tier: .hostProcess, enforced: true),
        Entry("resources.disk", "Change disk size", "Disk capacity of an instance.", tier: .hostProcess, enforced: true),
        Entry("resources.balloon", "Change memory mode", "Fixed or dynamic memory.", tier: .hostProcess, enforced: true),

        // MARK: distro
        Entry("distro.install", "Install distros", "Download and install a distro image.", tier: .hostProcess, enforced: true),
        Entry("distro.remove", "Remove distros", "Delete a downloaded distro.", tier: .daemon, enforced: true),
        Entry("distro.custom", "Use custom images", "Instances from a custom image.", tier: .daemon, enforced: true),
        Entry("distro.source", "Change image sources",
              "Install from a manifest other than MSL's own - `--manifest` or MSL_MANIFEST_URL.",
              tier: .hostProcess, enforced: true),

        // MARK: shipment - the sideloading and exfiltration routes
        Entry("shipment.import", "Import shipments", "Bring in a .mslship instance from elsewhere.", tier: .hostProcess, enforced: true),
        Entry("shipment.export", "Export shipments", "Write an instance out as a .mslship file.", tier: .hostProcess, enforced: true),

        // MARK: network
        Entry("network.vpn", "Use the VPN", "MSL's built-in VPN.", tier: .hostProcess, enforced: true),
        Entry("network.dns", "Change DNS", "The DNS provider instances use.", tier: .hostProcess, enforced: true),
        Entry("network.cut", "Change the network gate", "The sandbox network switch.", tier: .daemon, enforced: true),
        Entry("network.portForward", "Forward ports",
              "Open a port on this Mac that reaches one inside a guest. Loopback only - "
              + "`public.expose` is the one that reaches the internet.",
              tier: .daemon, enforced: true),
        Entry("network.trafficMonitor", "See traffic", "The traffic monitor.", tier: .daemon, enforced: true),

        // MARK: public (PublicMSL)
        Entry("public.expose", "Publish over the internet", "Make an instance reachable from outside.", tier: .daemon, enforced: true),
        Entry("public.relay", "Use the public relay", "The hosted relay backend.", tier: .daemon, enforced: true),
        Entry("public.selfHosted", "Use a self-hosted relay", "Publishing via your own server.", tier: .daemon, enforced: true),
        Entry("public.authorize", "Authorise SSH keys", "Grant someone access to a published instance.", tier: .daemon, enforced: true),
        Entry("public.notify", "Send address emails", "Email a new address when it changes.", tier: .daemon, enforced: true),

        // MARK: sharing
        Entry("sharing.macHome", "Share the Mac home folder", "Guest access to ~/Mac.", tier: .daemon, enforced: true),
        Entry("sharing.clipboard", "Share the clipboard", "Clipboard between Mac and Linux.", tier: .hostProcess, enforced: true),
        // Scoped carefully, because the first wording overclaimed. The
        // daemon refuses the real-permission listing and chmod; MSL Files
        // stops offering the instance. The bytes themselves come from the
        // WebDAV mount, so Finder keeps its own access until
        // `sharing.webdav` is denied as well - and saying otherwise would
        // be exactly the promise `enforced` exists to prevent.
        Entry("sharing.files", "Use MSL Files",
              "MSL Files stops offering the instance, and real Linux permissions and "
              + "Make Executable are refused. Finder's own mount is sharing.webdav.",
              tier: .daemon, enforced: true),
        Entry("sharing.webdav", "Mount guest files", "The WebDAV mount in Finder.", tier: .daemon, enforced: true),
        Entry("sharing.filePicker", "Use MSL Files as the picker", "MSL Files as Open/Save for Linux apps.", tier: .hostProcess, enforced: true),

        // MARK: peripherals
        Entry("peripherals.usb", "Pass through USB", "Mac USB devices into a guest.", tier: .daemon, enforced: true),
        Entry("peripherals.audio", "Use audio", "Sound from Linux apps.", tier: .daemon, enforced: true),
        Entry("peripherals.camera", "Use the camera", "Mac camera in a guest.", tier: .hostProcess, enforced: true),
        Entry("peripherals.microphone", "Use the microphone", "Mac microphone in a guest.", tier: .hostProcess, enforced: true),

        // MARK: graphics
        Entry("graphics.gpu", "Use GPU acceleration", "OpenGL on the Mac's GPU.", tier: .hostProcess, enforced: true),
        Entry("graphics.perApp", "Change per-app graphics", "A graphics mode for one app.", tier: .hostProcess, enforced: true),
        Entry("graphics.scaling", "Change scaling", "Native scaling for Linux windows.", tier: .hostProcess, enforced: true),

        // MARK: apps
        Entry("apps.launch", "Launch Linux apps", "Opening Linux apps at all.", tier: .hostProcess, enforced: true),
        Entry("apps.customCommand", "Edit launch commands",
              "Replace an app's launch command - this runs arbitrary commands in the guest.",
              tier: .hostProcess, enforced: true),
        Entry("apps.launchpad", "Add apps to Launchpad", "Generate macOS bundles for Linux apps.", tier: .hostProcess, enforced: true),
        Entry("apps.dock", "Pin apps to the Dock", "Keep a Linux app in the Dock.", tier: .hostProcess, enforced: true),
        Entry("apps.discovery", "Scan for apps", "Finding .desktop entries in a guest.", tier: .hostProcess, enforced: true),

        // MARK: integrations
        Entry("integrations.linksToMac", "Open links on the Mac", "Links from Linux apps open in Mac apps.", tier: .hostProcess, enforced: true),
        Entry("integrations.mailToMac", "Open mail on the Mac",
              "Mail links open in the Mac mail client. The guest handler is shared with "
              + "links, but the Mac side branches on the scheme, so this is refused on "
              + "its own without touching the handler's MIME list.", tier: .daemon, enforced: true),
        Entry("integrations.globalMenuBar", "Use the global menu bar", "Linux app menus in the Mac menu bar.", tier: .hostProcess, enforced: true),
        Entry("integrations.signInBrowser", "Sign in via the guest browser", "OAuth pages open in Linux.", tier: .hostProcess, enforced: true),
        Entry("integrations.shortcuts", "Use Mac shortcuts", "Mac keyboard shortcuts in Linux apps.", tier: .hostProcess, enforced: true),

        // MARK: system
        Entry("system.experimental", "Change experimental features", "The Experimental Features panel.", tier: .interfaceOnly, enforced: true),
        Entry("system.update", "Update MSL", "MSL updating itself.", tier: .hostProcess, enforced: true),
        Entry("system.startup", "Change startup behaviour", "Login items and daemon autostart.", tier: .hostProcess, enforced: true),
        Entry("system.uninstall", "Uninstall MSL", "Removing MSL from the Mac.", tier: .hostProcess, enforced: true),
        Entry("system.terminal", "Use the built-in terminal",
              "MSL's terminal tab. Interface tier: it does not stop `msl <instance>` "
              + "in Terminal.app, or SSH - deny system.ssh and lock the instance for that.",
              tier: .interfaceOnly, enforced: true),
        Entry("system.ssh", "Use guest SSH", "SSH into an instance.", tier: .hostProcess, enforced: true),
        Entry("system.doctor", "Run diagnostics", "msl doctor.", tier: .interfaceOnly, enforced: true),

        // MARK: admin
        Entry("admin.unenrol", "Remove the policy", "Unenrolling this Mac from management.", tier: .hostProcess, enforced: true),
        Entry("admin.editPolicy", "Edit the policy", "The MSLAP panel itself.", tier: .hostProcess, enforced: true),
    ]

    /// The catalogue entry for a key, if this build knows it.
    public static func entry(for capability: MSLAPCapability) -> Entry? {
        catalogue.first { $0.capability == capability }
    }

    /// Top-level groups, in catalogue order, for grouping in the UI and in
    /// `msl admin status`.
    public static var groups: [String] {
        var seen: [String] = []
        for entry in catalogue {
            let group = entry.capability.key.split(separator: ".").first.map(String.init) ?? ""
            if !seen.contains(group) { seen.append(group) }
        }
        return seen
    }
}
