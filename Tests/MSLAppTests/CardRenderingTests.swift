import SwiftUI
import XCTest
@testable import MSLApp
@testable import MSLCore

/// Every card in the app, drawn offscreen.
///
/// The gap this closes: `swift build` succeeding says a view compiles, not
/// that it renders. Five v2 cards were written, built and never once put on
/// a screen. `ImageRenderer` draws them for real - layout, text, the lot -
/// without needing a window, a display or screen-recording permission, so
/// this runs in `swift test` like anything else.
@MainActor
final class CardRenderingTests: XCTestCase {
    private func render(_ view: some View, file: StaticString = #filePath, line: UInt = #line) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: 560).padding())
        renderer.scale = 2
        return renderer.nsImage
    }

    /// `MSL_CARD_SNAPSHOT_DIR=/some/path swift test` also writes each card
    /// out as a PNG, which is how a person (or a model) actually looks at
    /// them without launching the app or having screen-recording rights.
    private func save(_ image: NSImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MSL_CARD_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: directory),
                                                 withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    private func assertRenders(_ view: some View, _ name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let image = render(view) else {
            return XCTFail("\(name) rendered nothing at all", file: file, line: line)
        }
        save(image, name)
        XCTAssertGreaterThan(image.size.width, 100, "\(name) is too narrow to be a card", file: file, line: line)
        XCTAssertGreaterThan(image.size.height, 40, "\(name) drew almost nothing", file: file, line: line)
    }

    /// A stopped instance and a live one take different branches in every
    /// one of these cards, and the stopped branch is the one nobody looks
    /// at. Both are rendered.
    private var stopped: Instance {
        Instance(name: "Test", distro: .alpine, state: .stopped, isInstalled: true, sandboxMountPath: nil)
    }

    /// The live branch is the one with the picker, the buttons and every
    /// sentence worth reading. `ImageRenderer` never runs `.task`, so these
    /// draw the "asking the guest" state without touching a guest.
    private var live: Instance {
        Instance(name: "Milk", distro: .alpine, state: .running, isInstalled: true, sandboxMountPath: nil)
    }

    /// The download UI, in both of its shapes. The bar shape was written
    /// and shipped once without anyone seeing it draw; this renders it.
    func testInstallProgressRendersWhileTransferring() {
        let transfer = DistroInstaller.TransferProgress(
            completed: 243 * 1024 * 1024, total: 534 * 1024 * 1024,
            bytesPerSecond: 7.8 * 1024 * 1024)
        assertRenders(
            InstallProgressView(status: "downloading https://example.invalid/msl-debian-13-arm64.img.xz (534 MB) ...",
                                transfer: transfer,
                                onCancel: {}),
            "install-progress-transferring")
    }

    /// The fallback shape. Its circular `ProgressView` draws as
    /// `ImageRenderer`'s prohibitory placeholder rather than a spinner -
    /// that is the renderer's limit with AppKit-backed controls, not a
    /// defect, and it is exactly why the bar above is drawn by hand.
    func testInstallProgressRendersWithoutATransfer() {
        assertRenders(InstallProgressView(status: "verifying sha256 ...", transfer: nil),
                      "install-progress-indeterminate")
    }

    /// The sidebar row that pulses on a first launch, in both states.
    /// A build says it compiles, not that the highlight draws.
    func testPermissionsRowRendersHighlightedAndNot() {
        assertRenders(PermissionsAndStartupButton(), "permissions-row")
    }

    func testPrivacyCardRenders() {
        assertRenders(PrivacyCard(instance: stopped), "PrivacyCard-stopped")
        assertRenders(PrivacyCard(instance: live), "PrivacyCard-live")
    }

    func testVPNCardRenders() {
        assertRenders(VPNCard(instance: stopped), "VPNCard-stopped")
        assertRenders(VPNCard(instance: live), "VPNCard-live")
    }

    func testInstanceLockCardRenders() {
        assertRenders(InstanceLockCard(instance: stopped), "InstanceLockCard")
    }

    func testHomeOwnershipCardRenders() {
        assertRenders(HomeOwnershipCard(instance: live).environmentObject(AppModel()),
                      "HomeOwnershipCard")
    }

    /// The Files editor is a sheet, so it is the easiest thing in the app to
    /// write and never see.
    func testTextEditorSheetRenders() {
        let target = FileTextEditorTarget(url: URL(fileURLWithPath: "/tmp/msl-test/.bashrc"))
        assertRenders(FileTextEditorSheet(target: target, onClose: {}).frame(height: 360),
                      "FileTextEditorSheet")
    }

    /// Every tile is the same box, whatever the name length or the source
    /// tag - the thing that was visibly wrong in the grid.
    func testAppTilesAreAllTheSameSize() {
        let apps = [
            LinuxApp(desktopPath: "/a.desktop", name: "Files", command: "nautilus", comment: nil),
            LinuxApp(desktopPath: "/b.desktop", name: "LibreOffice Calc Spreadsheet Editor",
                     command: "localc", comment: nil, source: .flatpak),
            LinuxApp(desktopPath: "/c.desktop", name: "Calculator", command: "gnome-calculator",
                     comment: nil, source: .snap),
        ]
        var sizes: [CGSize] = []
        for app in apps {
            let tile = AppTile(app: app, instance: live).environmentObject(AppModel())
            guard let image = ImageRenderer(content: tile).nsImage else {
                return XCTFail("a tile rendered nothing")
            }
            save(image, "AppTile-\(app.source.rawValue)")
            sizes.append(image.size)
        }
        XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "tiles differ in width: \(sizes)")
        XCTAssertEqual(Set(sizes.map(\.height)).count, 1, "tiles differ in height: \(sizes)")
    }

    /// The whole grid, as the Applications tab lays it out.
    func testAppGridRenders() {
        let names = ["Files", "LibreOffice Calc Spreadsheet Editor", "Calculator",
                     "Firefox", "GNU Image Manipulation Program", "Text Editor"]
        let sources: [AppSource] = [.system, .flatpak, .snap, .system, .user, .system]
        let apps = zip(names, sources).enumerated().map { index, pair in
            LinuxApp(desktopPath: "/\(index).desktop", name: pair.0, command: "run",
                     comment: nil, source: pair.1)
        }
        let grid = LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTile.width, maximum: AppTile.width),
                                                spacing: 12)], spacing: 12) {
            ForEach(apps) { app in AppTile(app: app, instance: self.live) }
        }
        .environmentObject(AppModel())
        .frame(width: 520)
        .padding()
        guard let image = ImageRenderer(content: grid).nsImage else {
            return XCTFail("the grid rendered nothing")
        }
        save(image, "AppGrid")
        XCTAssertGreaterThan(image.size.height, 100)
    }

    func testFilterPopoverRenders() {
        var filter = AppFilter()
        filter.source = .flatpak
        XCTAssertEqual(filter.activeCount, 1)
        XCTAssertEqual(filter.summary, "Flatpak")
        assertRenders(AppFilterPopover(filter: .constant(filter),
                                       availableSources: [.system, .user, .flatpak, .snap],
                                       counts: [.system: 24, .user: 2, .flatpak: 3, .snap: 1],
                                       total: 30),
                      "AppFilterPopover")
    }

    func testPersonalitySectionRenders() {
        assertRenders(PersonalitySection(), "PersonalitySection")
    }

    /// Power Rename - the batch find/replace + numbering sheet. Rendered with a
    /// rule filled in so the before/after preview shows.
    func testPowerRenameSheetRenders() {
        let model = FilesModel()
        let names = ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"]
        model.items = names.map {
            MSLFileItem(path: "/x/\($0)", name: $0, isDirectory: false, size: 100, modified: Date())
        }
        let sheet = PowerRenameSheet(files: model, paths: model.items.map(\.path))
        guard let image = ImageRenderer(content: sheet).nsImage else {
            return XCTFail("power rename sheet rendered nothing")
        }
        save(image, "PowerRenameSheet")
        XCTAssertGreaterThan(image.size.width, 100)
    }

    /// The MSL dashboard - the storage panel the "MSL" sidebar root shows.
    /// Rendered in both themes so the pink/cyan paint is actually seen.
    func testMSLDashboardRenders() {
        let info = MSLStorageInfo(
            images: [
                .init(id: "Debian 13", filename: "rootfs-debian.img",
                      path: "/x/rootfs-debian.img", allocated: 4_800_000_000,
                      capacity: 16_000_000_000, isSparse: true,
                      instances: ["Milk", "Cocoa"], exists: true),
                .init(id: "Alpine", filename: "rootfs.img", path: "/x/rootfs.img",
                      allocated: 900_000_000, capacity: 8_000_000_000, isSparse: true,
                      instances: ["Tin"], exists: true),
            ],
            locations: [
                .init(id: "programs", name: "MSL Program Files",
                      detail: "The app's tools, settings and catalogs",
                      symbol: "shippingbox", path: "/x", exists: true),
                .init(id: "images", name: "Disk Images",
                      detail: "The Linux root filesystems live here",
                      symbol: "internaldrive", path: "/x", exists: true),
                .init(id: "logs", name: "Logs", detail: "What mslhd has been up to",
                      symbol: "doc.text", path: "/x", exists: true),
            ],
            hostFreeBytes: 240_000_000_000, totalAllocated: 5_700_000_000)

        for theme in [FilesTheme.finder, .mslNeon] {
            let model = FilesModel()
            model.theme = theme
            let live = Instance(name: "Milk", distro: .debian, state: .running,
                                isInstalled: true, sandboxMountPath: "/Volumes/127.0.0.1")
            model.rebuildRoots(from: [live])
            let view = MSLDashboardView(files: model, instances: [live], info: info).content
                .frame(width: 720)
                .background(Color(nsColor: .windowBackgroundColor))
            guard let image = ImageRenderer(content: view).nsImage else {
                return XCTFail("dashboard rendered nothing")
            }
            save(image, "MSLDashboard-\(theme.rawValue)")
            XCTAssertGreaterThan(image.size.height, 300)
        }
    }

    /// The Quick Look peek info panel for a guest file - kind, size, dates and
    /// the real Linux permissions - the metadata the old QLPreviewView-only
    /// sheet showed nothing of.
    func testQuickLookSheetRenders() {
        let model = FilesModel()
        model.selectedRoot = FileRoot(
            id: "guest-Milk", name: "Milk", subtitle: "debian", symbol: "shippingbox",
            path: "/Volumes/127.0.0.1", isGuest: true, readOnly: false, section: .linux)
        let item = MSLFileItem(path: "/Volumes/127.0.0.1/etc/rc.local", name: "rc.local",
                               isDirectory: false, size: 320, modified: Date(), created: Date(),
                               kind: "Shell Script")
        model.items = [item]
        model.guestModes = ["/Volumes/127.0.0.1/etc/rc.local": 0o100755]
        let sheet = QuickLookSheet(item: item, files: model, onClose: {})
            .frame(width: 720, height: 460)
        guard let image = ImageRenderer(content: sheet).nsImage else {
            return XCTFail("the quick look sheet rendered nothing")
        }
        save(image, "QuickLookSheet-guest")
        XCTAssertGreaterThan(image.size.width, 100)
    }

    /// MSL Files' list view on a Linux root, with the real-mode overlay filled
    /// in - the permissions column and the symlink badge the WebDAV mount
    /// can't show. Drawn offscreen so the column layout is seen without
    /// driving the live app to a guest directory.
    func testGuestListViewPermissionsRender() {
        let model = FilesModel()
        model.selectedRoot = FileRoot(
            id: "guest-Milk", name: "Milk", subtitle: "debian", symbol: "shippingbox",
            path: "/Volumes/127.0.0.1", isGuest: true, readOnly: false, section: .linux)
        let base = "/Volumes/127.0.0.1/etc"
        model.items = [
            MSLFileItem(path: "\(base)/ssl", name: "ssl", isDirectory: true, size: 0,
                        modified: Date(), kind: "Folder"),
            MSLFileItem(path: "\(base)/hostname", name: "hostname", isDirectory: false, size: 7,
                        modified: Date(), kind: "Document"),
            MSLFileItem(path: "\(base)/rc.local", name: "rc.local", isDirectory: false, size: 320,
                        modified: Date(), kind: "Shell Script"),
            MSLFileItem(path: "\(base)/os-release", name: "os-release", isDirectory: false, size: 21,
                        modified: Date(), kind: "Alias"),
        ]
        model.guestModes = [
            "\(base)/ssl": 0o040755,
            "\(base)/hostname": 0o100644,
            "\(base)/rc.local": 0o100755,   // executable
            "\(base)/os-release": 0o120777, // symlink -> badge
        ]
        let view = FileListView(files: model)
            .frame(width: 680, height: 260)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let image = ImageRenderer(content: view).nsImage else {
            return XCTFail("the guest list view rendered nothing")
        }
        save(image, "FileListView-guest-permissions")
        XCTAssertGreaterThan(image.size.width, 100)
    }

    /// The chrome://flags-style Experimental Features window, drawn full-height
    /// so a person (or a model) can read the grouping, badges and search bar
    /// without launching the app.
    func testExperimentalFeaturesPanelRenders() {
        // **A disposable settings file.** Assigning `settings` saves, so a
        // model pointed at the real one would rewrite the settings of
        // whoever ran the tests - which is exactly what this test used to do.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-panel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = ExperimentalFeaturesModel(storeURL: temporary)
        // A couple flipped away from their defaults so the "On"/orange
        // change-badges and the outline show up in the snapshot.
        model.settings.gpuAcceleration = true
        model.settings.globalMenuBar = false
        // Render the scrollable content directly: ImageRenderer collapses a
        // ScrollView to nothing, so drawing the whole panel shows only chrome.
        let content = ExperimentalFeaturesPanel(model: model).scrollContent
            .frame(width: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let image = ImageRenderer(content: content).nsImage else {
            return XCTFail("the experimental panel rendered nothing")
        }
        save(image, "ExperimentalFeaturesPanel")
        XCTAssertGreaterThan(image.size.height, 400)
    }

    // MARK: - The distro grid

    /// Every distro card must be the same height.
    ///
    /// `LazyVGrid` sizes a whole row to its tallest item, so one card whose
    /// title wrapped to two lines put a visible step in the New Instance
    /// grid - "CentOS Stream" was the only name long enough to do it. The
    /// grid itself renders as nothing offscreen, so the cards are measured
    /// one at a time at the width the grid gives them.
    func testEveryDistroCardIsTheSameHeight() {
        // What a card really gets: a 560pt sheet, its padding, and three
        // adaptive columns - not the 150pt minimum, which only sets how many
        // columns fit.
        let width: CGFloat = 168
        var heights: [String: CGFloat] = [:]
        for distro in GuestDistro.allCases where !distro.isCustom {
            let renderer = ImageRenderer(content:
                DistroChoice(distro: distro, isSelected: false,
                             isDownloaded: distro == .debian, instanceCount: 2)
                    .frame(width: width))
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                return XCTFail("\(distro.rawValue) rendered nothing")
            }
            heights[distro.rawValue] = image.size.height
            save(image, "distro-card-\(distro.rawValue)")
        }
        // A point, not zero. A title that *wrapped* to two lines and one
        // that merely *reserved* two measure half a point apart - text
        // layout rounding, invisible at any scale. The bug this guards was
        // sixteen points: a one-line card next to a two-line one.
        let tallest = heights.values.max() ?? 0
        let shortest = heights.values.min() ?? 0
        XCTAssertLessThan(tallest - shortest, 1,
                          "cards differ in height, so the grid will have a step: \(heights)")
    }

    /// Nothing is truncated, which is the trap the first fix fell into: one
    /// line with a scale floor shrank to the floor and then cut the name to
    /// "CentOS Str…" anyway, which is worse than the uneven grid was.
    ///
    /// Measured rather than looked at - the width the card gives its title,
    /// against what the longest name actually needs.
    /// Every distro name fits on its one line, with the 0.85 scale floor.
    ///
    /// Measured rather than looked at. The card is a single row now, so an
    /// over-long name has nowhere to wrap to - it would be cut to "CentOS
    /// Str…", and a truncated distro name is the thing this whole layout is
    /// trying to avoid.
    func testEveryDistroNameFitsOnOneLine() {
        let width: CGFloat = 168
        // The card's padding, the 26pt badge and the gap after it, and the
        // trailing count-plus-tick column.
        // The card's padding, the 26pt badge and the gap after it, and the
        // trailing tick. No count any more - the few points it took were the
        // difference between "CentOS Stream" fitting and being cut.
        let available = width - (Design.Spacing.small * 2) - 26 - Design.Spacing.small - 18
        let font = NSFont.preferredFont(forTextStyle: .body)
        for distro in GuestDistro.allCases where !distro.isCustom {
            let needed = (distro.displayName as NSString)
                .size(withAttributes: [.font: font]).width
            // At FULL size, not at the scale floor: the floor is a safety
            // net for a future name, not something today's names rely on.
            XCTAssertLessThan(needed, available,
                              "\(distro.displayName) needs \(needed)pt and has \(available)pt")
        }
    }

    /// And no blurb: at this width it was always truncated, so it cost a
    /// line and said nothing.
    func testTheCardCarriesNoBlurb() {
        let renderer = ImageRenderer(content:
            DistroChoice(distro: .rocky, isSelected: false, isDownloaded: false, instanceCount: 0)
                .frame(width: 168))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return XCTFail("rendered nothing") }
        save(image, "distro-card-lean")
        // One line of text plus padding. Two lines was ~62pt.
        XCTAssertLessThan(image.size.height, 48,
                          "the card grew a second line again")
    }

    // MARK: - The logo picker

    /// `InstanceLogoSheet` sets its own size, so it is rendered at that size
    /// rather than through `assertRenders`'s 560-point card frame.
    private func renderSheet(_ view: some View, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let renderer = ImageRenderer(content: view.frame(width: 468, height: 540))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            return XCTFail("\(name) rendered nothing at all", file: file, line: line)
        }
        save(image, name)
        // The whole sheet, not a collapsed stack: sixty symbols and twelve
        // swatches have to actually take up the space.
        XCTAssertEqual(image.size.width, 468, accuracy: 2, file: file, line: line)
        XCTAssertEqual(image.size.height, 540, accuracy: 2, file: file, line: line)
    }

    /// The grids themselves, at their natural height. This is the one that
    /// proves seventy-two cells lay out: `ImageRenderer` draws a ScrollView's
    /// content as nothing, so the whole-sheet renders below show the chrome
    /// and an empty panel no matter what is inside it.
    func testLogoChoicesRender() {
        let model = AppModel()
        model.appearances["Milk"] = InstanceAppearance(symbol: "crown.fill", tint: "#8E4EC6")
        let renderer = ImageRenderer(content:
            LogoChoices(instance: live).environmentObject(model).frame(width: 420).padding())
        renderer.scale = 2
        guard let image = renderer.nsImage else { return XCTFail("the grids rendered nothing") }
        save(image, "logo-choices")
        // Five factions and a colour row. Anything much shorter means the
        // grids collapsed again.
        XCTAssertGreaterThan(image.size.height, 380,
                             "the faction and colour grids didn't lay out")
    }

    /// The default state: nothing chosen, so Reset to Default is off.
    func testLogoSheetRendersAtItsDefault() {
        renderSheet(InstanceLogoSheet(instance: live).environmentObject(AppModel()),
                    "logo-sheet-default")
    }

    /// With a faction and a colour chosen, which is the branch that draws the
    /// selection ring in two different grids.
    func testLogoSheetRendersWithAChosenFaction() {
        let model = AppModel()
        model.appearances["Milk"] = InstanceAppearance(symbol: "crown.fill", tint: "#8E4EC6")
        renderSheet(InstanceLogoSheet(instance: live).environmentObject(model),
                    "logo-sheet-chosen")
    }

    /// A picture dims the faction grid rather than hiding it, and swaps the
    /// explanatory line - both easy to get wrong and invisible to the
    /// compiler.
    func testLogoSheetRendersWithAPicture() {
        let model = AppModel()
        model.appearances["Milk"] = InstanceAppearance(image: "nothing-here.png")
        renderSheet(InstanceLogoSheet(instance: live).environmentObject(model),
                    "logo-sheet-picture")
    }

    /// The picture branch of the badge - `scaledToFill` inside a clip - which
    /// nothing else here draws, because the sheet renders use a file that
    /// isn't there.
    func testBadgeWithAPictureRenders() {
        let picture = NSImage(size: NSSize(width: 120, height: 60))
        picture.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 60).fill()
        NSColor.white.setFill()
        NSRect(x: 50, y: 10, width: 20, height: 40).fill()
        picture.unlockFocus()
        assertRenders(
            HStack(spacing: 16) {
                DistroBadge(distro: .debian, size: 26, image: picture)
                DistroBadge(distro: .debian, size: 44, image: picture)
            },
            "instance-badge-picture")
    }

    /// The badge itself, in both sizes it is drawn at, with and without a
    /// chosen look.
    func testInstanceBadgeRenders() {
        let model = AppModel()
        model.appearances["Milk"] = InstanceAppearance(symbol: "flame.fill", tint: "#E5484D")
        assertRenders(
            HStack(spacing: 16) {
                InstanceBadge(instance: live, size: 26)
                InstanceBadge(instance: live, size: 44)
                InstanceBadge(instance: stopped, size: 26)
                InstanceBadge(instance: stopped, size: 44)
            }
            .environmentObject(model),
            "instance-badges")
    }
}

/// The permissions nudge must happen once on a Mac, not every launch.
@MainActor
final class PermissionsIntroductionTests: XCTestCase {
    private let key = "msl.permissions.introduced"
    private var saved: Bool!

    override func setUp() {
        saved = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
    override func tearDown() { UserDefaults.standard.set(saved, forKey: key) }

    func testAFreshMacHasNotBeenIntroduced() {
        XCTAssertFalse(PermissionsAndStartupButton.hasBeenIntroduced,
                       "a first launch must pulse the row - nothing MSL does works until macOS is told to let it")
    }

    func testOnceIntroducedItStaysThatWay() {
        PermissionsAndStartupButton.hasBeenIntroduced = true
        XCTAssertTrue(PermissionsAndStartupButton.hasBeenIntroduced,
                      "pulsing on every launch would be nagging, not a nudge")
    }
}
