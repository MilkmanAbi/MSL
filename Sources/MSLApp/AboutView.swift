import AppKit
import MSLCore
import SwiftUI

/// MSL's About window.
///
/// A real window rather than `NSApp.orderFrontStandardAboutPanel` or a
/// sheet: there are four sections here, one of them is the full GPL, and a
/// 674-line licence inside a fixed-size sheet is not something anyone can
/// actually read. A window can be resized and left open beside the app.
///
/// Deliberately not sterile. This project is one person's, and the About
/// panel is the one place in an app where that is allowed to show.
struct AboutView: View {
    @State private var section: AboutSection = .about

    var body: some View {
        NavigationSplitView {
            List(AboutSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
        } detail: {
            // Each pane scrolls itself rather than everything living in one
            // outer ScrollView. The Licence pane needs to *fill* the window
            // - its reader grows with the window instead of being a fixed
            // box with dead space under it - and a pane nested in a scroll
            // view has no height to fill.
            switch section {
            case .about: PaneScroll { AboutPane() }
            case .licence: PaneScroll { LicencePane() }
            case .contributors: PaneScroll { ContributorsPane() }
            case .extras: PaneScroll { ExtrasPane() }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

enum AboutSection: String, CaseIterable, Identifiable, Hashable {
    case about, licence, contributors, extras
    var id: Self { self }

    var title: String {
        switch self {
        case .about: return "About"
        case .licence: return "Licence"
        case .contributors: return "Contributors"
        case .extras: return "Extras"
        }
    }

    var symbol: String {
        switch self {
        case .about: return "sparkles"
        case .licence: return "doc.text"
        case .contributors: return "person.2.fill"
        case .extras: return "books.vertical.fill"
        }
    }
}

// MARK: - Shared bits

/// The scrolling, padded frame the read-only panes sit in.
private struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Design.Spacing.section)
                .padding(.vertical, Design.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The melon's own colours, borrowed for the panel so it feels like it
/// belongs to the logo rather than to the system template.
enum Melon {
    static let rind = Color(red: 0.60, green: 0.78, blue: 0.55)
    static let flesh = Color(red: 0.99, green: 0.78, blue: 0.57)
    static let deep = Color(red: 0.36, green: 0.60, blue: 0.42)

    /// Colours for the contributor cards - the melon's own two, plus a few
    /// fruit-bowl neighbours so a grid of them looks like a grid of people
    /// rather than one colour repeated.
    ///
    /// Muted on purpose: these are drawn at 10% fill behind a name, so
    /// saturated versions turn the pane into a highlighter set.
    static let bowl: [Color] = [
        rind,
        flesh,
        Color(red: 0.95, green: 0.60, blue: 0.62),   // watermelon
        Color(red: 0.62, green: 0.72, blue: 0.93),   // plum-ish blue
        Color(red: 0.85, green: 0.70, blue: 0.94),   // grape
        Color(red: 0.98, green: 0.85, blue: 0.52),   // mango
        Color(red: 0.55, green: 0.83, blue: 0.80),   // honeydew-teal
    ]

    /// The same person always gets the same colour, on every launch and on
    /// every machine - see `StableHash` for why that needs saying.
    static func tint(for login: String) -> Color {
        bowl[StableHash.index(for: login, modulo: bowl.count)]
    }
}

/// Loads a bundled image by bare name.
///
/// Bare, with no `subdirectory:`, because `Package.swift` declares these
/// with `.process` - which flattens them into the bundle root. Returning an
/// empty `Image` rather than trapping: a missing asset should leave a gap
/// in the About panel, not take the app down.
struct BundledImage: View {
    let name: String
    var body: some View {
        if let url = MSLAsset.url(name, extension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}

/// Abi's own mark, which follows the system appearance.
///
/// The two files are the same drawing in opposite ink - `-Light` is black
/// (for a light background) and `-Dark` is white - so the *theme* name
/// picks the file, not the ink name. `@Environment(\.colorScheme)` resolves
/// "system" correctly and re-renders when the user switches appearance
/// mid-session, so no appearance observer is needed.
struct AbiMark: View {
    @Environment(\.colorScheme) private var scheme
    /// Generous for a mark that is meant to be small: the file is a square
    /// 1024x1024 with the drawing occupying a wide band across the middle,
    /// so roughly half of any frame given to it is transparent padding. A
    /// 20pt frame leaves about 9pt of actual ink, which is a smudge - and
    /// this is fine line art (a phage's legs are one pixel wide at source),
    /// so it needs real room plus high-quality interpolation or the strokes
    /// break up and crawl.
    var height: CGFloat = 72

    var body: some View {
        BundledImage(name: scheme == .dark ? "Abi_Logo-Dark" : "Abi_Logo-Light")
            .frame(height: height)
            .accessibilityLabel("Abi")
    }
}

/// A soft rounded panel - the shape everything cute in here sits on.
struct CuteCard<Content: View>: View {
    var tint: Color = Melon.rind
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Design.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.tileCorner, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            )
    }
}

private struct SectionHeading: View {
    let text: String
    var kaomoji: String? = nil

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            Text(text).font(.title3.weight(.semibold))
            if let kaomoji {
                Text(kaomoji)
                    .font(.callout)
                    .foregroundStyle(Melon.deep)
            }
        }
        .padding(.bottom, Design.Spacing.tight)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            // The melon, big, because it is the favourite.
            HStack(alignment: .center, spacing: Design.Spacing.large) {
                BundledImage(name: "App_Logo")
                    .frame(width: 168, height: 168)
                    .shadow(color: Melon.deep.opacity(0.22), radius: 14, y: 6)

                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    Text("MSL").font(.system(size: 46, weight: .bold, design: .rounded))
                    Text("Mac Subsystem for Linux")
                        .font(.title3)
                        .foregroundStyle(Melon.deep)
                    Text("\(MSLVersion.display) · still experimental, still held together with love")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, Design.Spacing.tight)
                }
                Spacer(minLength: 0)
            }

            CuteCard {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("Real Linux distros, running as native-feeling macOS terminals — and, experimentally, Linux GUI apps as real Mac windows with their own Dock tiles.")
                    Text("Built on Virtualization.framework, so there's no emulation layer and no VM window to keep track of. ヽ(・∀・)ﾉ")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            // The mascot, cutely, with his artist credited in the smallest
            // font in the whole app.
            HStack(alignment: .bottom, spacing: Design.Spacing.medium) {
                VStack(spacing: 2) {
                    BundledImage(name: "Mascot")
                        .frame(width: 118)
                    Text("Illustrated by neekocat_2025")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                CuteCard(tint: Melon.flesh) {
                    VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                        Text("our little guy").font(.callout.weight(.semibold))
                        Text("He carries the docs around and looks concerned about the kernel panics. Same. ( ˘•ω•˘ )")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 300)

                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: Design.Spacing.small) {
                Text("made by").font(.caption).foregroundStyle(.tertiary)
                AbiMark(height: 76)
                Spacer(minLength: 0)
                Link("github.com/MilkmanAbi/MSL",
                     destination: URL(string: "https://github.com/MilkmanAbi/MSL")!)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Licence

private struct LicencePane: View {
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            SectionHeading(text: "Licence", kaomoji: "＿φ( ◔ω◔ )")
            Text("MSL is free software. Most of it is MIT; mslgd, its X11 server, is under the GNU General Public License v3, printed below. The app is built with mslgd inside it, so the app as a whole is GPL v3 too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The reader: a box that grows with the window rather than a
            // fixed height with dead space under it.
            //
            // `.clipShape` goes on the ScrollView *before* the background,
            // and the whole thing is given a bounded frame. Without both,
            // the scroll view sizes itself to the full length of the GPL
            // and draws straight through the card, the heading and the
            // sidebar - which is exactly what it did.
            ScrollView {
                Text(text ?? "Loading…")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Spacing.medium)
            }
            // A fixed height, deliberately. Letting this box grow to fill
            // the window needs an unbounded frame, and an unbounded
            // ScrollView here sizes itself to the entire length of the GPL:
            // the text then draws straight over the card, the heading and
            // the sidebar, and the sidebar rows disappear altogether.
            // Verified by screenshot, twice. A tall fixed box inside the
            // pane's own scroll view is the boring thing that works.
            .frame(height: 520)
            .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .strokeBorder(Melon.rind.opacity(0.3), lineWidth: 1)
            )

            LicenceSplit()
                .padding(.top, Design.Spacing.small)
        }
        .task {
            guard text == nil else { return }
            if let url = MSLAsset.url("License", extension: "md") {
                text = try? String(contentsOf: url, encoding: .utf8)
            }
            if text == nil { text = "Couldn't load the licence text — it ships in the repository as LICENSE." }
        }
    }
}

/// Why one repository carries two licences, in plain language.
///
/// Worth spelling out rather than leaving to a `LICENSE` file: the split is
/// a deliberate choice about which parts are worth keeping free, and "GPL"
/// on its own tells nobody which parts those are or why.
private struct LicenceSplit: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            SectionHeading(text: "Two licences, on purpose", kaomoji: "( ˶ˆ ᗜ ˆ˵ )")

            CuteCard(tint: .blue) {
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    HStack(spacing: Design.Spacing.small) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                        Text("Everything else — MIT").font(.callout.weight(.semibold))
                    }
                    Text("This app, the msl command, the background service, MSL Files, the guest daemons, and all the VM plumbing: booting Linux, saving and restoring it, disks, vsock. Useful to anyone building something on a Mac, so nothing about it is fenced off.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("So: take it. Use it in anything, including something closed and commercial. No obligations, just don't sue me. (っ˘ω˘ς )")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    Text("Every file outside mslgd. Full text in **LICENSE-MIT**; the README's Licence section lists the mslgd paths.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            CuteCard(tint: .purple) {
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    HStack(spacing: Design.Spacing.small) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        Text("mslgd — GPL v3").font(.callout.weight(.semibold))
                    }
                    Text("**mslgd**, the X11 server, with its per-app window hosts and the guest-side tunnel, and anything derived from it. This is where most of the years and most of the swearing went — an attempt at making Linux GUI apps feel like they belong on a Mac, with a great deal of engineering effort, care and getting it wrong first.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Copyleft, so it stays free: use it, change it, ship it — but if you ship changes, the people who get them get the source too. Someone shouldn't be able to take the hard part, close it, and sell it back.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    Text("Sources/MSLCore/X11, X11InputGate, mslgui and x11tunnel.c. The app ships with mslgd built in, so the whole app, built, is GPL v3 — that's the text above.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            SectionHeading(text: "…so why not just use XQuartz?", kaomoji: "(・_・ヾ")

            CuteCard(tint: Melon.flesh) {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("XQuartz works, and for a lot of people it is genuinely the right answer — it puts Linux windows on your screen and it takes five minutes to set up. MSL was after something narrower: not *whether* the windows appear, but *whose* they are.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Under XQuartz, every Linux app is a window belonging to XQuartz, which means:")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                        Bullet("**One Dock tile** for all of them, and it says XQuartz rather than GIMP or Krita.")
                        Bullet("**One icon**, the X, on every app.")
                        Bullet("**The menu bar says XQuartz**, whichever app you are actually in.")
                        Bullet("**Mission Control** groups them together rather than showing them as separate apps.")
                        Bullet("⌘-Tab reaches *XQuartz* as a single entry.")
                    }

                    Text("None of that is a fault — it is simply not what XQuartz set out to do. But it does read as a remote desktop with Linux inside it, and MSL wanted to try the other thing: a Linux app with its own tile, its own icon, its own name and its own place in Mission Control.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    Text("As far as I could find, none of that is reachable from outside: an app only gets its own window, tile and identity if *you* are the thing creating the windows — which means being the X server. So mslgd is one, written from scratch: about 13,700 lines across 30 files, speaking the X11 wire protocol straight into AppKit and Core Graphics. Atoms, pixmaps, render and composite, glyphs, clipping, XI2 input, crossing events — and a whole helper process per app, because macOS gives exactly one Dock tile per process and I never found a way around it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("That's the bit under the GPL — the part MSL exists to attempt, rather than a finished claim about how well it does it. ♡")
                        .font(.callout)
                        .foregroundStyle(Melon.deep)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Contributors

private struct ContributorsPane: View {
    @StateObject private var loader = ContributorsLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            SectionHeading(text: "Contributors", kaomoji: "٩(ˊᗜˋ*)و")
            Text("Everyone who has landed a commit in the repo. Pulled live from GitHub each time you open this.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch loader.state {
            case .loading:
                HStack(spacing: Design.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Asking GitHub…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, Design.Spacing.medium)

            case .loaded(let people):
                // `maximum:` matters: with one contributor an unbounded
                // adaptive column stretches that single card across the
                // whole pane, which looks like a layout bug rather than a
                // small team.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340),
                                             spacing: Design.Spacing.medium)],
                          alignment: .leading, spacing: Design.Spacing.medium) {
                    ForEach(people) { person in
                        ContributorCard(person: person, profile: loader.profiles[person.login])
                    }
                }

            case .empty:
                CuteCard(tint: Melon.flesh) {
                    VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                        Text("No commits pushed yet ( ´•̥̥̥ω•̥̥̥` )").font(.callout.weight(.semibold))
                        Text("The repo is up but still empty. This list fills itself in the moment there's something to show.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .failed(let reason):
                CuteCard(tint: .orange) {
                    VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                        Text("Couldn't load the list").font(.callout.weight(.semibold))
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await loader.load() } }
                            .buttonStyle(.link)
                            .padding(.top, Design.Spacing.tight)
                    }
                }
            }

            Link("Open the repository on GitHub →",
                 destination: URL(string: "https://github.com/MilkmanAbi/MSL")!)
                .font(.callout)
                .padding(.top, Design.Spacing.tight)
        }
        .task { await loader.load() }
    }
}

private struct ContributorCard: View {
    let person: Contributor
    /// Arrives a moment after the card does - see `ContributorsLoader`.
    var profile: ContributorProfile? = nil
    @State private var hovering = false

    private var tint: Color { Melon.tint(for: person.login) }

    var body: some View {
        Link(destination: URL(string: person.profileURL) ?? URL(string: "https://github.com")!) {
            CuteCard(tint: tint) {
                HStack(alignment: .top, spacing: Design.Spacing.small) {
                    AsyncImage(url: URL(string: person.avatarURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(tint.opacity(0.35))
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    // A ring in the person's own colour, so the avatar and
                    // the card agree with each other.
                    .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: 2))

                    VStack(alignment: .leading, spacing: 1) {
                        // The name someone chose to go by, with the handle
                        // underneath it; just the handle when they set no
                        // name, rather than an empty line where one was.
                        if let name = profile?.name, !name.isEmpty {
                            Text(name).font(.callout.weight(.semibold))
                            Text("@\(person.login)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(person.login).font(.callout.weight(.semibold))
                        }

                        Text("\(person.contributions) commit\(person.contributions == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)

                        if let location = profile?.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(tint)
                                .padding(.top, 1)
                        }

                        if let bio = profile?.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 3)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            // Just enough lift to say "this is a link" without the cards
            // jittering as the pointer crosses the grid.
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Extras

private struct ExtrasPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            SectionHeading(text: "What this even is", kaomoji: "(｡•̀ᴗ-)✧")

            CuteCard {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("Windows has WSL. macOS has plenty of good ways to get to Linux already — Docker, UTM, Lima, OrbStack, a VM in a window.")
                        .font(.callout)
                    Text("MSL is another path rather than a replacement for any of them. `msl` drops you into a real Linux shell in about a second — real job control, real pty, colours and line editing intact. Six distros boot today: Alpine, Debian, Ubuntu, Arch, Fedora and Nix.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ExtraStory(
                icon: "folder.fill", tint: Melon.rind,
                title: "MSL Files",
                detail: "A Finder work-alike that shows your Mac and your Linux guests side by side. Icon, list, column and gallery views; real Finder tags that round-trip with actual Finder; Quick Look; Recents; drag-and-drop across the boundary. The keyboard shortcuts are Finder's, on purpose — muscle memory shouldn't have to know which window it's in. (⌐■_■)"
            )

            ExtraStory(
                icon: "macwindow.on.rectangle", tint: Melon.flesh,
                title: "Linux apps as Mac windows",
                detail: "Launch a Linux GUI app and it shows up as a real macOS window, with its own Dock tile, its own icon and its own name in the menu bar. macOS only gives one Dock tile per process, so each Linux app gets an entire helper process of its own just to have a tile. Absolutely worth it. ᕕ( ᐛ )ᕗ"
            )

            SectionHeading(text: "The mslgd story", kaomoji: "(╯°□°)╯︵ ┻━┻")

            CuteCard(tint: .purple) {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("in which the dumbest possible approach is taken, repeatedly")
                        .font(.callout.weight(.semibold))
                    Text("The sane way to put Linux windows on a Mac is to install XQuartz and let it be the X server. So naturally: **about 13,700 lines of hand-written X11 server in Swift**, drawing straight into AppKit and Core Graphics. Thirty files. No Xlib, no xorg-server, just the wire protocol and stubbornness.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Things it turns out you have to know:")
                        .font(.callout.weight(.semibold))
                        .padding(.top, Design.Spacing.tight)

                    VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                        Bullet("The 68 predefined atoms have to be seeded by hand. Skip it and `WM_NAME` can never match, so window titles are silently dead code — for months.")
                        Bullet("Send an input as both XI2 *and* core and every click lands twice. Krita's menus were broken for a very long time because of one doubled click.")
                        Bullet("Depth-8 coverage masks go in the **alpha** channel, because `CGContextClipToMask` reads alpha, not luminance. Get it wrong and your calculator renders like a haunted photocopy.")
                        Bullet("AppKit will happily send you Enter without a matching Leave. GTK4 does not find this funny and simply stops responding to your mouse.")
                    }

                    Text("Would I do it again? Yes, and I think that's the problem. ( ͡° ᴥ ͡°)")
                        .font(.callout)
                        .foregroundStyle(Melon.deep)
                        .padding(.top, Design.Spacing.tight)
                }
            }

            HStack {
                Spacer()
                VStack(spacing: Design.Spacing.tight) {
                    Text("thanks for reading this far ♡")
                        .font(.callout).foregroundStyle(.secondary)
                    AbiMark(height: 64)
                }
                Spacer()
            }
            .padding(.top, Design.Spacing.small)
        }
    }
}

private struct ExtraStory: View {
    let icon: String
    let tint: Color
    let title: String
    /// Not `body` - that is `View`'s own requirement, and a stored
    /// property of the same name shadows it into a compile error.
    let detail: String

    var body: some View {
        CuteCard(tint: tint) {
            HStack(alignment: .top, spacing: Design.Spacing.medium) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text("·").font(.callout.weight(.bold)).foregroundStyle(Melon.deep)
            Text(.init(text)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    AboutView()
}
