import MSLCore
import SwiftUI

/// What the welcome guide says, as data.
///
/// Separate from the view so the pages can be checked without a window -
/// `WelcomeGuideTests` renders every one of them offscreen, which is the
/// only thing that proves a page actually lays out (see
/// `CardRenderingTests` for why `swift build` does not).
struct WelcomePage: Identifiable {
    /// A bullet: a symbol, a few words, and the sentence that earns them.
    struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    let id: String
    /// Shown over the photo.
    let title: String
    let subtitle: String
    /// The paragraph under the banner. One or two sentences - anything
    /// longer stops being read on a page somebody is clicking through.
    let lead: String
    let points: [Point]
    /// A help article to offer at the bottom, when there is an obvious
    /// "and then what" for this page.
    let article: (id: String, label: String)?
    /// A real button, for a page whose whole point is to send you
    /// somewhere. Only the last page has one.
    let action: Action?

    /// Somewhere the guide can send you. An enum rather than a closure so
    /// the pages stay plain data the tests can read.
    enum Action: Equatable {
        /// Close the guide and open Permissions & Startup.
        case openPermissions

        var label: String {
            switch self {
            case .openPermissions: return "Open Permissions & Startup"
            }
        }
    }

    init(id: String, title: String, subtitle: String, lead: String,
         points: [Point], article: (id: String, label: String)? = nil,
         action: Action? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.lead = lead
        self.points = points
        self.article = article
        self.action = action
    }
}

enum WelcomeGuide {
    /// Whether this Mac has been through the guide.
    ///
    /// `UserDefaults`, like `msl.permissions.introduced` beside it: per
    /// person, and it survives the app being replaced, which happens on
    /// every single update. A file in Application Support would be shared
    /// with `msl` and the daemon, and neither of them has any business
    /// knowing whether somebody has read a welcome screen.
    static let seenKey = "msl.welcome.seen"

    /// Where the flag lives. Injectable **only** so tests can use a store of
    /// their own - a test that writes the real domain is a test that changes
    /// the person's settings, and one that makes its own `UserDefaults`
    /// suite leaks a plist into `~/Library/Preferences` for ever, because
    /// `cfprefsd` writes the domain back out after the process has gone.
    /// Measured: six of them had piled up from earlier runs, and neither
    /// `removeSuite` nor `removePersistentDomain` nor deleting the file
    /// stopped it.
    nonisolated(unsafe) static var store: UserDefaults = .standard

    nonisolated static var hasBeenSeen: Bool {
        get { store.bool(forKey: seenKey) }
        set { store.set(newValue, forKey: seenKey) }
    }

    /// Six pages. Any more and nobody reaches the end; any fewer and the
    /// parts that are genuinely unusual about MSL - Linux windows in the
    /// Dock, USB devices macOS has no driver for - get compressed into a
    /// bullet nobody reads.
    static let pages: [WelcomePage] = [
        WelcomePage(
            id: "welcome",
            title: "Welcome to MSL",
            subtitle: "Mac Subsystem for Linux \(MSLVersion.marketing)",
            lead: """
            MSL runs real Linux on your Mac - a whole distribution, in a real virtual machine, \
            on Apple's own hypervisor. Not a container, not an emulator, and not a window \
            pretending to be a desktop.
            """,
            points: [
                .init(symbol: "shippingbox",
                      title: "Twelve distributions",
                      detail: "Alpine, Debian, Ubuntu, Arch, Fedora, Kali and more. Download one, and it is kept - every instance you make from it is a genuinely fresh install."),
                .init(symbol: "square.stack.3d.up",
                      title: "As many as you like",
                      detail: "Instances are separate machines with separate disks. Break one and the others never notice."),
                .init(symbol: "bolt",
                      title: "It starts in seconds",
                      detail: "Suspend one when you walk away and it picks up exactly where it was."),
            ],
            article: ("install-distro", "Installing a distro")),

        WelcomePage(
            id: "two-ways",
            title: "Two ways in",
            subtitle: "The app, and the command line",
            lead: """
            This window is one half of MSL. The other is `msl`, a command you can use from \
            Terminal.app or anywhere else - the same instances, the same daemon, no difference \
            in what either can do.
            """,
            points: [
                .init(symbol: "macwindow",
                      title: "The app",
                      detail: "Make instances, give them memory and disk, browse their files, watch what they are doing, and start their apps."),
                .init(symbol: "terminal",
                      title: "msl",
                      detail: "`msl` on its own lists what you have. `msl <name>` drops you into a shell. `msl <name> <command>` runs one thing and comes back."),
                .init(symbol: "arrow.triangle.2.circlepath",
                      title: "Nothing is app-only",
                      detail: "Anything you do here has a command, and anything you type has a button. Use whichever is closer to hand."),
            ],
            article: ("cli-help", "Everything `msl` can do")),

        WelcomePage(
            id: "windows",
            title: "Linux apps, Mac windows",
            subtitle: "MSL's own display server",
            lead: """
            Linux apps open as ordinary macOS windows. Not a desktop in a box with Linux \
            inside it - each app is its own window, with its own Dock tile, its own icon and \
            its own name.
            """,
            points: [
                .init(symbol: "app.badge",
                      title: "Real windows",
                      detail: "They minimise, they go full screen, they show up in Mission Control and in the app switcher, because they are real macOS windows."),
                .init(symbol: "dock.rectangle",
                      title: "Real Dock tiles",
                      detail: "GIMP looks like GIMP in your Dock. You can add a Linux app to your Applications folder and open it without touching MSL at all."),
                .init(symbol: "command",
                      title: "Your shortcuts",
                      detail: "⌘C and ⌘V work, and the clipboard is shared both ways. The Mac keyboard layout is carried across, so the keys are where you left them."),
            ],
            article: ("opening-apps", "Opening a Linux app")),

        WelcomePage(
            id: "files",
            title: "One set of files",
            subtitle: "Your Mac, from inside Linux",
            lead: """
            Your home folder is mounted inside every instance at `/mnt/mac`, so there is no \
            copying things back and forth to work on them. It is the same file from both sides.
            """,
            points: [
                .init(symbol: "folder",
                      title: "MSL Files",
                      detail: "A Mac-side browser for any instance's Linux filesystem. Drag things in and out of it like any other window."),
                .init(symbol: "doc.badge.arrow.up",
                      title: "Open and Save, properly",
                      detail: "When a Linux app asks for a file, you get a real Mac file picker instead of a GTK dialog that cannot see your Mac."),
                .init(symbol: "link",
                      title: "Links and mail come back",
                      detail: "A link clicked inside Linux opens in your Mac browser. An attachment opens in your Mac mail client."),
            ],
            article: ("files-window", "The MSL Files window")),

        WelcomePage(
            id: "usb",
            title: "Hardware macOS has never met",
            subtitle: "USB passthrough",
            lead: """
            Some devices macOS simply has no driver for - a dev board, a programmer, a \
            vendor-specific dongle, something whose manufacturer only ever shipped a Linux \
            driver. Linux almost certainly does have one. MSL hands the device over.
            """,
            points: [
                .init(symbol: "cable.connector",
                      title: "msl usb list",
                      detail: "Shows what is plugged into your Mac, which macOS driver holds each one, and which instance has it."),
                .init(symbol: "arrow.right.circle",
                      title: "msl usb attach",
                      detail: "A device macOS has no driver for goes straight through, with nothing to approve. One it does have a driver for can be taken from it, which asks for your password."),
                .init(symbol: "arrow.uturn.backward",
                      title: "You get it back",
                      detail: "Detach, or stop the instance, and macOS picks the device up again by itself."),
            ],
            article: ("usb-devices", "USB devices")),

        WelcomePage(
            id: "ready",
            title: "One thing first",
            subtitle: "Permissions",
            lead: """
            macOS has to be told to let MSL do some of this, and it asks about each thing \
            separately. **Allow All** in the next window raises every one of those questions \
            now, so they do not interrupt you later - in the middle of opening an app, or \
            halfway through copying a file.
            """,
            points: [
                .init(symbol: "checkmark.shield",
                      title: "Nothing here is permanent",
                      detail: "Every one of these is an ordinary macOS permission. Say no to any of them, change your mind later in System Settings, and MSL carries on - it just tells you which parts cannot work."),
                .init(symbol: "flask",
                      title: "Some of this is experimental",
                      detail: "MSL says so plainly rather than pretending otherwise - Experimental Features, also in the sidebar, lists every switch and what it actually does."),
                .init(symbol: "questionmark.circle",
                      title: "There is a real guide",
                      detail: "MSL Help, in the Help menu: ninety-odd articles covering all of this properly. Nothing here is something you have to remember - including this window, which is in that menu too."),
            ],
            article: ("whats-ready", "What's ready, what's experimental"),
            action: .openPermissions),
    ]
}
