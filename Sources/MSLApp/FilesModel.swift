import AppKit
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

/// One browsable root in the sidebar.
struct FileRoot: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let path: String
    let isGuest: Bool
    /// A stand-in root from `MSL_FILES_EXTRA_ROOT`, shown separately so it
    /// is never mistaken for a real instance.
    var isDevelopment: Bool = false
    let readOnly: Bool
    /// Sidebar grouping, mirroring Finder's own taxonomy.
    var section: Section = .locations
    /// Where this root's *top level* comes from. Tags and Recents are saved
    /// searches, not directories - but descending into a folder from a
    /// search result is ordinary directory browsing again, which is why
    /// this describes the root and not the whole root's behaviour.
    var kind: Kind = .directory

    enum Kind: Hashable {
        case directory
        case tag(String)
        case recents
        /// The MSL dashboard - not a directory at all, but a panel about the
        /// project's own storage. The one root the detail pane draws itself
        /// rather than as a file listing.
        case dashboard

        /// A Spotlight-backed listing (tags, recents), as opposed to a real
        /// directory or the dashboard. Drives whether the browser runs a
        /// query and disables writing.
        var isQuery: Bool {
            switch self {
            case .tag, .recents: return true
            case .directory, .dashboard: return false
            }
        }
    }

    enum Section: String, CaseIterable {
        /// Finder puts Recents above the Favorites header, in a group with
        /// no title of its own.
        case top = ""
        case favorites = "Favorites"
        case locations = "Locations"
        case linux = "Linux"
        case development = "Development"
        case tags = "Tags"
    }

    var provider: LocalFileProvider {
        LocalFileProvider(displayName: name, rootPath: path, readOnly: readOnly)
    }
}

/// How the browser draws a directory. Finder's four, same order, same
/// meanings.
enum FileViewMode: String, CaseIterable, Identifiable {
    case icon, list, column, gallery
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .column: return "rectangle.split.3x1"
        case .gallery: return "square.bottomthird.inset.filled"
        }
    }

    var label: String {
        switch self {
        case .icon: return "as Icons"
        case .list: return "as List"
        case .column: return "as Columns"
        case .gallery: return "as Gallery"
        }
    }
}

/// A sortable column. `kind` and `created` exist because the list view
/// offers them as columns, the way Finder's does.
enum FileSortKey: String, CaseIterable, Identifiable {
    case name, size, kind, modified, created
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Added"
        }
    }
}

/// Finder's "Group By": items collected under headings instead of one flat
/// list. Sorting still applies *within* each group.
enum FileGrouping: String, CaseIterable, Identifiable {
    case none, name, kind, modified, size, tags
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }
}

/// One step in the back/forward stack: a root and a directory chain within
/// it. Both are needed - going back can cross roots.
private struct NavigationStep: Equatable {
    let rootID: String
    let path: [String]
}

/// A file being previewed. `URL` is not `Identifiable`, which
/// `.sheet(item:)` requires, and retroactively conforming a Foundation type
/// would apply app-wide for the benefit of one sheet.
struct QuickLookTarget: Identifiable, Equatable {
    let item: MSLFileItem
    var url: URL { URL(fileURLWithPath: item.path) }
    var id: String { item.path }
}

/// Small typed wrapper over `UserDefaults` for the view preferences.
enum Defaults {
    static func load<T: RawRepresentable>(_ key: String, _ fallback: T) -> T
    where T.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = T(rawValue: raw) else { return fallback }
        return value
    }

    static func save<T: RawRepresentable>(_ key: String, _ value: T) where T.RawValue == String {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    /// `bool(forKey:)` returns false for a key that was never written, which
    /// would silently turn any default-on preference off on first launch.
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

/// State for one browser window.
///
/// The guest roots come from `Instance.sandboxMountPath`, which the daemon
/// reports only while an instance is running - the mount is created when the
/// VM comes up and torn down when it stops. An instance that isn't running
/// therefore has no filesystem to show, which the sidebar says rather than
/// showing an empty folder.
@MainActor
final class FilesModel: ObservableObject {
    @Published var roots: [FileRoot] = []
    @Published var selectedRoot: FileRoot? {
        // Every path that changes the root (the sidebar, Go, back/forward,
        // reveal) runs through here, so the guest disk line is refreshed in
        // exactly one place.
        didSet {
            if selectedRoot?.id != oldValue?.id { refreshGuestDiskSummary(for: selectedRoot) }
        }
    }
    @Published var path: [String] = []
    @Published var items: [MSLFileItem] = [] {
        // A monotonic stamp so `visibleItems`/`groupedItems` can tell "same
        // listing" from "new listing" in O(1) instead of comparing arrays -
        // see the memoization below. Bumped on every assignment, which is the
        // only way `items` changes.
        didSet { itemsVersion &+= 1 }
    }
    private var itemsVersion = 0
    @Published var selection: Set<String> = []
    /// The *real* Linux `st_mode` for the current directory's rows, keyed by
    /// host path - permissions and file type the WebDAV mount fakes (it
    /// reports the mounter's own uid and a made-up `rwx------`). Filled by
    /// `overlayGuestModes()` from mslhd's `fileopsd` relay after each listing,
    /// and empty for Mac roots or when the relay is unavailable, in which case
    /// the UI simply shows no Linux mode rather than a wrong one.
    @Published var guestModes: [String: UInt32] = [:]
    /// Git state for the folders in the current listing, keyed by host path.
    @Published var gitBadges: [String: Git.Badge] = [:]
    private var gitBadgeToken: UUID?
    /// Guards against a slow overlay landing after the user has already moved
    /// on: only the newest request's result is applied.
    private var overlayToken = UUID()

    /// True while a text field (the toolbar search field, an inline rename,
    /// the Go-to-Folder sheet) is being edited. The bare-key file shortcuts -
    /// ⌘C, ⌘V, Space, Return - disable themselves against this so they don't
    /// steal a keystroke that belongs to the field. It only flips on the first
    /// *edit*, not on focus, so ⌘C and ⌘V also forward to the field editor at
    /// action time (see `FilesView.shortcuts`) to cover the focus-before-edit
    /// gap.
    @Published var isEditingText = false
    /// Remembered between launches: someone who works in dotfiles should not
    /// have to switch this on every time they open the window.
    @Published var showHidden = UserDefaults.standard.bool(forKey: "MSLFilesShowHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "MSLFilesShowHidden") }
    }
    @Published var search = ""
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var renaming: String?
    @Published var quickLookTarget: QuickLookTarget?
    /// The file open in the text editor, if any.
    @Published var editorTarget: FileTextEditorTarget?
    @Published var infoTarget: MSLFileItem?
    /// The folder whose git panel is open, if any.
    @Published var gitTarget: GitPanelTarget?
    /// Items the volume could not move to the Trash, awaiting the user's
    /// decision to delete them for good.
    @Published var pendingPermanentDelete: Set<String> = []
    /// Finder's View menu can hide each of these independently.
    @Published var showPathBar = Defaults.bool("files.showPathBar", true) {
        didSet { UserDefaults.standard.set(showPathBar, forKey: "files.showPathBar") }
    }
    @Published var showStatusBar = Defaults.bool("files.showStatusBar", true) {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: "files.showStatusBar") }
    }
    @Published var goToFolderPresented = false

    // Remembered across launches, the way Finder remembers a view mode.
    // Deliberately `@Published` + `UserDefaults` rather than `@AppStorage`:
    // that wrapper only republishes inside a `View`, so setting it on a
    // model would persist the value and never redraw anything.
    @Published var viewMode: FileViewMode = Defaults.load("files.viewMode", .list) {
        didSet {
            Defaults.save("files.viewMode", viewMode)
            if viewMode == .column { Task { await loadAncestors() } }
        }
    }
    /// The sort for the *current* root. Finder keeps view settings per
    /// location, and the difference shows immediately: Recents sorted by
    /// name instead of by date is not a recents list at all.
    var sortKey: FileSortKey {
        get { sortOverrides[selectedRoot?.id ?? ""]?.key ?? defaultSortKey }
        set {
            objectWillChange.send()
            var entry = sortOverrides[selectedRoot?.id ?? ""]
                ?? (key: defaultSortKey, ascending: defaultSortAscending)
            entry.key = newValue
            sortOverrides[selectedRoot?.id ?? ""] = entry
            rememberDefaultSort(entry)
        }
    }

    var sortAscending: Bool {
        get { sortOverrides[selectedRoot?.id ?? ""]?.ascending ?? defaultSortAscending }
        set {
            objectWillChange.send()
            var entry = sortOverrides[selectedRoot?.id ?? ""]
                ?? (key: defaultSortKey, ascending: defaultSortAscending)
            entry.ascending = newValue
            sortOverrides[selectedRoot?.id ?? ""] = entry
            rememberDefaultSort(entry)
        }
    }

    /// Per-root view settings. Seeded for a root the first time it is
    /// selected, so a search root can start "newest first" without changing
    /// what every directory does.
    @Published private var sortOverrides: [String: (key: FileSortKey, ascending: Bool)] = [:]

    private var defaultSortKey = Defaults.load("files.sortKey", FileSortKey.name)
    private var defaultSortAscending = Defaults.bool("files.sortAscending", true)

    /// Only a directory's sort becomes the remembered default. A search
    /// root's "newest first" is a property of that root, not a preference
    /// the user expressed about folders.
    private func rememberDefaultSort(_ entry: (key: FileSortKey, ascending: Bool)) {
        guard selectedRoot?.kind.isQuery != true else { return }
        defaultSortKey = entry.key
        defaultSortAscending = entry.ascending
        Defaults.save("files.sortKey", entry.key)
        UserDefaults.standard.set(entry.ascending, forKey: "files.sortAscending")
    }
    /// Finder calls this "Keep folders on top when sorting by name" and
    /// ships it off. On here it defaults on: this browser is mostly used to
    /// walk a tree, where hunting a folder out of an alphabetical mix is
    /// the common annoyance.
    @Published var foldersOnTop = Defaults.bool("files.foldersOnTop", true) {
        didSet { UserDefaults.standard.set(foldersOnTop, forKey: "files.foldersOnTop") }
    }

    @Published var grouping: FileGrouping = Defaults.load("files.grouping", .none) {
        didSet { Defaults.save("files.grouping", grouping) }
    }

    /// The highlight layer. Cosmetic only - see `FilesTheme`.
    @Published var theme: FilesTheme = FilesTheme.load() {
        didSet { theme.save() }
    }

    /// The base the highlight sits on: System, Light, Dark or Darker.
    @Published var appearance: FilesAppearance = FilesAppearance.load() {
        didSet { appearance.save() }
    }

    /// Carries a duller version of the highlight into the folder area.
    @Published var tintFolderArea = Defaults.bool("files.tintFolderArea", false) {
        didSet { UserDefaults.standard.set(tintFolderArea, forKey: "files.tintFolderArea") }
    }

    /// Whether the file views should show the window's backdrop instead of
    /// their own opaque background.
    var usesCustomBackdrop: Bool { appearance == .darker || tintFolderArea }

    /// The MSL dashboard is selected: the detail pane shows the project's
    /// storage panel instead of a file listing.
    var isShowingDashboard: Bool { selectedRoot?.kind == .dashboard }

    /// The live instance list, kept so a guest root can find its distro (and
    /// thus its disk image) for the real used/free figures.
    private(set) var instances: [Instance] = []
    /// The selected guest root's disk line for the status bar - "X used · Y
    /// free · Dynamic". `nil` on a Mac root, where the volume's own free space
    /// is shown instead.
    @Published private(set) var guestDiskSummary: String?

    /// `visibleItems` split into Finder's group headings. A single unnamed
    /// group when grouping is off, so the views can render one shape rather
    /// than branching.
    var groupedItems: [(title: String, items: [MSLFileItem])] {
        let sig = visibleSignature
        if let cache = groupedCache, cache.sig == sig, cache.grouping == grouping {
            return cache.value
        }
        let value = computeGrouped()
        groupedCache = (sig, grouping, value)
        return value
    }

    private func computeGrouped() -> [(title: String, items: [MSLFileItem])] {
        let items = visibleItems
        guard grouping != .none else { return [("", items)] }

        var order: [String] = []
        var buckets: [String: [MSLFileItem]] = [:]
        for item in items {
            for title in groupTitles(for: item) {
                if buckets[title] == nil { order.append(title) }
                buckets[title, default: []].append(item)
            }
        }
        // Date and size groups have a meaningful order of their own;
        // everything else reads best alphabetically.
        if grouping == .modified || grouping == .size {
            order.sort { rank(of: $0) < rank(of: $1) }
        } else {
            order.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// A file can appear under more than one heading only when grouping by
    /// tags, which is how Finder does it too - a file tagged Red and Blue
    /// shows under both.
    private func groupTitles(for item: MSLFileItem) -> [String] {
        switch grouping {
        case .none: return [""]
        case .name:
            let first = item.name.first.map(String.init)?.uppercased() ?? "#"
            return [first.rangeOfCharacter(from: .letters) != nil ? first : "#"]
        case .kind: return [item.kind ?? "Other"]
        case .modified: return [Self.dateBucket(item.modified)]
        case .size: return [Self.sizeBucket(item)]
        case .tags:
            return item.tags.isEmpty ? ["No Tags"] : item.tags.map(\.name)
        }
    }

    private static let dateBuckets = ["Today", "Yesterday", "Previous 7 Days",
                                      "Previous 30 Days", "Earlier"]
    private static let sizeBuckets = ["Zero KB", "Under 1 MB", "1 MB to 10 MB",
                                      "10 MB to 100 MB", "Over 100 MB", "Folders"]

    private func rank(of title: String) -> Int {
        Self.dateBuckets.firstIndex(of: title)
            ?? Self.sizeBuckets.firstIndex(of: title)
            ?? Int.max
    }

    private static func dateBucket(_ date: Date?) -> String {
        guard let date else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        return "Earlier"
    }

    private static func sizeBucket(_ item: MSLFileItem) -> String {
        if item.isDirectory { return "Folders" }
        switch item.size {
        case 0: return "Zero KB"
        case ..<1_000_000: return "Under 1 MB"
        case ..<10_000_000: return "1 MB to 10 MB"
        case ..<100_000_000: return "10 MB to 100 MB"
        default: return "Over 100 MB"
        }
    }

    /// Directories already listed, keyed by path. Column view needs several
    /// levels visible at once, and re-listing an ancestor every time the
    /// selection moves would be a round trip per keystroke on the guest.
    /// Invalidated wholesale on any mutation, which is cheap and cannot go
    /// stale in a way the user would see.
    @Published private var directoryCache: [String: [MSLFileItem]] = [:] {
        didSet { directoryCacheVersion &+= 1 }
    }
    private var directoryCacheVersion = 0

    /// Held for its lifetime: `NSMetadataQuery` is notification-driven and
    /// silently never fires if it is released.
    private let spotlight = SpotlightQuery()

    private var back: [NavigationStep] = []
    private var forward: [NavigationStep] = []

    private var provider: LocalFileProvider? { selectedRoot?.provider }
    /// The provider for the current root, for views that need to list on their
    /// own (the Quick Look folder count). Same object `reload` uses.
    var currentProvider: LocalFileProvider? { provider }

    var currentPath: String { path.last ?? selectedRoot?.path ?? NSHomeDirectory() }

    /// True when the list is Spotlight results rather than a directory.
    /// Only at the root: descend into a folder from a result and this is
    /// ordinary browsing again.
    var isShowingQueryResults: Bool {
        (selectedRoot?.kind.isQuery ?? false) && path.isEmpty
    }

    /// Results have no containing directory, so there is nowhere to create,
    /// drop or paste into. Everything that writes hangs off this, which is
    /// why those affordances disable themselves rather than failing.
    var canWrite: Bool {
        guard !isShowingQueryResults else { return false }
        return provider?.isWritable ?? false
    }

    /// Column view lays out a directory chain, which search results do not
    /// have. Rather than rendering an empty or nonsensical set of columns,
    /// the browser falls back to the list for these roots - and the segment
    /// is disabled so the mode never looks broken.
    var effectiveViewMode: FileViewMode {
        isShowingQueryResults && viewMode == .column ? .list : viewMode
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The single item in focus - what the gallery previews and the
    /// inspector describes. Multi-selection has no single subject, so the
    /// inspector reports the count instead.
    var focusedItem: MSLFileItem? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return items.first { $0.path == path }
    }

    /// Everything that changes what `visibleItems` produces, in one cheap-to-
    /// compare value. `itemsVersion` stands in for the array (comparing the
    /// listing element-by-element on every access would defeat the point).
    private struct VisibleSignature: Equatable {
        let itemsVersion: Int
        let showHidden: Bool
        let search: String
        let sortKey: FileSortKey
        let sortAscending: Bool
        let foldersOnTop: Bool
        let isQuery: Bool
    }
    private var visibleSignature: VisibleSignature {
        VisibleSignature(itemsVersion: itemsVersion, showHidden: showHidden, search: search,
                         sortKey: sortKey, sortAscending: sortAscending,
                         foldersOnTop: foldersOnTop, isQuery: isShowingQueryResults)
    }
    private var visibleCache: (sig: VisibleSignature, value: [MSLFileItem])?
    private var groupedCache: (sig: VisibleSignature, grouping: FileGrouping,
                               value: [(title: String, items: [MSLFileItem])])?

    /// The rows on screen: hidden files filtered, search applied, sorted.
    ///
    /// Memoized. This used to filter and `localizedStandardCompare`-sort the
    /// whole directory *on every access*, and a single redraw reads it four to
    /// six times (each view body, `groupedItems`, the item count, the empty
    /// check, the Tags menu) - so a 2000-entry folder paid for half a dozen
    /// full locale-aware sorts per frame, which was the lag. Now it recomputes
    /// only when something in `VisibleSignature` actually changes; a plain
    /// re-render (selection, hover, the permissions overlay landing) reuses the
    /// cached array.
    var visibleItems: [MSLFileItem] {
        let sig = visibleSignature
        if let cache = visibleCache, cache.sig == sig { return cache.value }
        var result = showHidden ? items : items.filter { !$0.isHidden }
        if !search.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        let value = sorted(result)
        visibleCache = (sig, value)
        return value
    }

    /// Applies the user's sort. Ties always break on name so the order is
    /// total - otherwise rows shuffle between reloads whenever the sort key
    /// is equal, which reads as a flicker.
    func sorted(_ input: [MSLFileItem]) -> [MSLFileItem] {
        input.sorted { lhs, rhs in
            // Search results are a flat list of hits; hoisting folders to
            // the top of "most recently used" would bury the actual answer.
            if foldersOnTop, !isShowingQueryResults,
               lhs.isBrowsableDirectory != rhs.isBrowsableDirectory {
                return lhs.isBrowsableDirectory
            }
            let ordered: Bool
            switch sortKey {
            case .name:
                return nameOrder(lhs, rhs)
            case .size:
                if lhs.size == rhs.size { return nameOrder(lhs, rhs) }
                ordered = lhs.size < rhs.size
            case .kind:
                let a = lhs.kind ?? "", b = rhs.kind ?? ""
                if a == b { return nameOrder(lhs, rhs) }
                ordered = a.localizedStandardCompare(b) == .orderedAscending
            case .modified:
                let a = lhs.modified ?? .distantPast, b = rhs.modified ?? .distantPast
                if a == b { return nameOrder(lhs, rhs) }
                ordered = a < b
            case .created:
                let a = lhs.created ?? .distantPast, b = rhs.created ?? .distantPast
                if a == b { return nameOrder(lhs, rhs) }
                ordered = a < b
            }
            return sortAscending ? ordered : !ordered
        }
    }

    private func nameOrder(_ lhs: MSLFileItem, _ rhs: MSLFileItem) -> Bool {
        let ascending = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        return sortAscending ? ascending : !ascending
    }

    func toggleSort(_ key: FileSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    /// Breadcrumb components from the selected root down to the current
    /// directory, as (label, path) pairs.
    var breadcrumbs: [(name: String, path: String)] {
        guard let root = selectedRoot else { return [] }
        // A query root's own crumb carries an empty path: clicking it goes
        // back to the results rather than to a directory.
        var crumbs = [(root.name, root.kind.isQuery ? "" : root.path)]
        for step in path {
            crumbs.append(((step as NSString).lastPathComponent, step))
        }
        return crumbs
    }

    // MARK: - Column view

    /// The directory chain column view draws, one entry per column.
    ///
    /// Derived from `path` rather than stored beside it. Column view is a
    /// second presentation of the same navigation state, not its own state -
    /// keeping a parallel array would let the columns and the breadcrumbs
    /// disagree, which is the classic way this feature breaks.
    private struct ColumnSignature: Equatable {
        let sig: VisibleSignature
        let cacheVersion: Int
        let path: [String]
        let selection: String?
    }
    private var columnCache: (sig: ColumnSignature,
                              value: [(path: String, items: [MSLFileItem], selected: String?)])?

    /// Memoized like `visibleItems`: column view is the mode where the cost
    /// bit hardest - it filters and `localizedStandardCompare`-sorts *every*
    /// column on every render, not just the current directory. Recomputed only
    /// when the listing, the path, the selection or the sort actually change.
    var columnChain: [(path: String, items: [MSLFileItem], selected: String?)] {
        let signature = ColumnSignature(sig: visibleSignature, cacheVersion: directoryCacheVersion,
                                        path: path, selection: selection.first)
        if let cache = columnCache, cache.sig == signature { return cache.value }
        let value = computeColumnChain()
        columnCache = (signature, value)
        return value
    }

    private func computeColumnChain() -> [(path: String, items: [MSLFileItem], selected: String?)] {
        let deepest = breadcrumbs.count - 1
        return breadcrumbs.enumerated().map { index, crumb in
            // Search narrows the directory being looked at, not the path
            // taken to reach it. Filtering ancestors too would empty every
            // column the moment the query stopped matching a parent folder's
            // name, and the chain showing where you are would vanish.
            let contents = sorted(filtered(directoryCache[crumb.path] ?? [],
                                           applySearch: index == deepest))
            // What's selected in this column is whatever the next column is
            // showing - or, in the last column, the actual selection.
            let selected: String? = index + 1 < breadcrumbs.count
                ? breadcrumbs[index + 1].path
                : selection.first
            return (crumb.path, contents, selected)
        }
    }

    private func filtered(_ input: [MSLFileItem], applySearch: Bool = true) -> [MSLFileItem] {
        var result = showHidden ? input : input.filter { !$0.isHidden }
        if applySearch, !search.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return result
    }

    /// Selects `item` at column `index`: descends if it is a folder,
    /// otherwise just focuses it so the preview column can describe it.
    func selectInColumn(_ item: MSLFileItem, at index: Int) {
        pushHistory()
        path = Array(path.prefix(index))
        if item.isBrowsableDirectory {
            path.append(item.path)
            selection = []
        } else {
            selection = [item.path]
        }
        Task { await reload() }
    }

    // MARK: - Roots

    func rebuildRoots(from instances: [Instance]) {
        self.instances = instances
        let home = NSHomeDirectory()
        var built: [FileRoot] = [
            // The MSL dashboard sits at the very top - it's what makes this a
            // window into the project, not just another file browser.
            FileRoot(id: "msl-dashboard", name: "MSL", subtitle: "Storage & shortcuts",
                     symbol: "cube.transparent", path: home, isGuest: false,
                     readOnly: true, section: .top, kind: .dashboard),
            FileRoot(id: "recents", name: "Recents", subtitle: "Recently used",
                     symbol: "clock", path: home, isGuest: false, readOnly: true,
                     section: .top, kind: .recents),
            FileRoot(id: "mac-home", name: (home as NSString).lastPathComponent,
                     subtitle: "Home", symbol: "house",
                     path: home, isGuest: false, readOnly: false, section: .favorites),
        ]
        // The standard places, the way Finder's Favorites list opens with
        // them. Skipped when missing rather than shown broken.
        let favorites: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("Documents", "doc", .documentDirectory),
            ("Downloads", "arrow.down.circle", .downloadsDirectory),
            ("Applications", "square.grid.3x3", .applicationDirectory),
        ]
        for (name, symbol, directory) in favorites {
            // Applications means the *system* /Applications, where apps
            // actually are. `.userDomainMask` resolves to ~/Applications,
            // which is almost always empty - so the sidebar entry looked
            // broken. Everything else stays user-domain, as Finder has it.
            let searchDomain: FileManager.SearchPathDomainMask =
                directory == .applicationDirectory ? .localDomainMask : .userDomainMask
            guard let url = FileManager.default.urls(for: directory, in: searchDomain).first
                    ?? (directory == .applicationDirectory
                        ? URL(fileURLWithPath: "/Applications") : nil),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            built.append(FileRoot(
                id: "mac-\(name.lowercased())", name: name, subtitle: "This Mac",
                symbol: symbol, path: url.path, isGuest: false,
                readOnly: !FileManager.default.isWritableFile(atPath: url.path),
                section: .favorites))
        }
        built.append(FileRoot(
            id: "mac-root", name: "Macintosh HD", subtitle: "This Mac",
            symbol: "internaldrive", path: "/", isGuest: false,
            readOnly: true, section: .locations))

        for instance in instances {
            guard let mount = instance.sandboxMountPath else { continue }
            // `sharing.files` - MSL's own browser stops offering the
            // instance at all.
            //
            // **And it is honest about what that is worth.** The listing
            // underneath comes from the WebDAV mount, not from MSL, so
            // Finder can still reach the same files unless `sharing.webdav`
            // is denied too. What this refusal does close is MSL Files, and
            // the daemon separately refuses the `fileList`/`fileChmod`
            // requests, so the real Linux permissions and "Make
            // Executable" go with it. The catalogue entry says all three
            // parts - see README 30 section 10.2.
            guard MSLAPGate.allows("sharing.files", instance: instance.name) else { continue }
            built.append(FileRoot(
                id: "guest-\(instance.name)",
                // The mount itself is named after a loopback address, which
                // is why this feels invisible in Finder. Naming it here is
                // most of the point of this window.
                name: instance.name,
                subtitle: "\(instance.distro.displayName) · Linux",
                symbol: "shippingbox",
                path: mount, isGuest: true,
                // Discovered rather than assumed: the guest is served over
                // WebDAV, which macOS mounts read-only when the server
                // advertises no LOCK support.
                readOnly: !FileManager.default.isWritableFile(atPath: mount),
                section: .linux))
        }
        // Development hook, kept in release builds on purpose: the guest
        // pane only appears while an instance is running, so without a
        // bootable image this window cannot be worked on at all. Pointing
        // `MSL_FILES_EXTRA_ROOT` at any directory adds it as a stand-in.
        //
        // It lands in its own "Development" section rather than under
        // Linux. A local directory listed beside real instances would read
        // as guest state, which is a good way to believe something about a
        // guest that isn't true. It grants no access the user did not
        // already have.
        if let extra = ProcessInfo.processInfo.environment["MSL_FILES_EXTRA_ROOT"],
           FileManager.default.fileExists(atPath: extra) {
            built.append(FileRoot(
                id: "guest-extra", name: (extra as NSString).lastPathComponent,
                subtitle: "stand-in root", symbol: "hammer",
                path: extra, isGuest: false, isDevelopment: true,
                readOnly: !FileManager.default.isWritableFile(atPath: extra),
                section: .development))
        }

        // Finder lists all seven standard tags whether or not anything
        // carries them, so they are a stable place to drop files onto.
        for name in FileTag.standardNames {
            built.append(FileRoot(
                id: "tag-\(name)", name: name, subtitle: "Tag",
                symbol: "circle.fill", path: home, isGuest: false, readOnly: true,
                section: .tags, kind: .tag(name)))
        }

        roots = built
        if selectedRoot == nil || !built.contains(where: { $0.id == selectedRoot?.id }) {
            select(built.first)
        }
        applyPendingReveal()
    }

    // MARK: - Reveal from Linux

    /// A place a Linux app asked to show, waiting for its instance's root.
    private var pendingReveal: (instance: String, path: String, select: Bool)?

    /// Handles `msl-files://files?instance=<name>&path=<guest path>[&select=1]`
    /// (and the pre-split `msl://files?...`, which MSL.app forwards here).
    /// Returns whether the URL was one; the path is shown now if the
    /// instance's root exists, or as soon as it appears.
    @discardableResult
    func reveal(_ url: URL) -> Bool {
        guard url.scheme == MSLFilesIdentity.urlScheme || url.scheme == MSLFilesIdentity.legacyScheme,
              url.host == "files",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let instance = items.first(where: { $0.name == "instance" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/")
        else { return false }
        let select = items.first(where: { $0.name == "select" })?.value == "1"
        pendingReveal = (instance, path, select)
        applyPendingReveal()
        return true
    }

    private func applyPendingReveal() {
        guard let pending = pendingReveal,
              let root = roots.first(where: { $0.id == "guest-\(pending.instance)" }) else { return }
        pendingReveal = nil
        // The guest's whole filesystem is the mount, so a guest path is the
        // same path under it.
        let full = pending.path == "/" ? root.path : root.path + pending.path
        if pending.select, pending.path != "/" {
            navigate(to: (full as NSString).deletingLastPathComponent)
            selection = [full]
        } else {
            navigate(to: full)
        }
    }

    func roots(in section: FileRoot.Section) -> [FileRoot] {
        roots.filter { $0.section == section }
    }

    // MARK: - Navigation

    /// Re-clicking the sidebar root you are already inside returns you to its
    /// top, exactly as Finder does. `List(selection:)` never fires its setter
    /// for a row that is already selected - so `select(_:)` above never even
    /// runs on a re-click - which is why the sidebar drives this from a
    /// `.simultaneousGesture` instead. A no-op unless we have actually
    /// descended somewhere below the root.
    func returnToTop(_ root: FileRoot) {
        guard root.id == selectedRoot?.id, !path.isEmpty else { return }
        pushHistory()
        path = []
        selection = []
        Task { await reload() }
    }

    func select(_ root: FileRoot?) {
        guard root?.id != selectedRoot?.id else { return }
        pushHistory()
        selectedRoot = root
        if let root, sortOverrides[root.id] == nil, root.kind.isQuery {
            // Recents and tag searches are lists of things you touched, so
            // they open newest first the way Finder's do.
            sortOverrides[root.id] = (key: .modified, ascending: false)
        }
        path = []
        selection = []
        Task { await reload() }
    }

    /// Loads the guest disk line for a root, off the main actor, newest-wins.
    /// Cleared immediately for a Mac root so a stale guest figure never shows.
    private func refreshGuestDiskSummary(for root: FileRoot?) {
        guard let root, root.isGuest,
              let instance = instances.first(where: { $0.name == root.name }) else {
            guestDiskSummary = nil
            return
        }
        guestDiskSummary = nil
        Task {
            let info = await MSLStorageInfo.guestDisk(for: instance)
            if selectedRoot?.id == root.id { guestDiskSummary = info?.summary }
        }
    }

    /// When set, activating a file means "choose this one" rather than
    /// "open it on the Mac" - the file picker sets it, so double-clicking a
    /// row in a Linux app's Open dialog returns that path to the app instead
    /// of launching a Mac app on it (or expanding an archive in place).
    /// Folders still descend normally; a picker is still a browser.
    var chooseFile: ((MSLFileItem) -> Void)?

    func open(_ item: MSLFileItem) {
        if !item.isBrowsableDirectory, let chooseFile {
            chooseFile(item)
            return
        }
        guard item.isBrowsableDirectory else {
            // An archive expands where it sits, the way double-clicking one
            // in Finder does. Handing a .zip to `NSWorkspace` would work
            // (Archive Utility owns it) but a .tar.gz opens in whatever
            // claims it and a .7z has no handler at all, so nothing happened.
            if beginExtracting(item) { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        pushHistory()
        path.append(item.path)
        selection = []
        Task { await reload() }
    }

    /// Archives this can expand with tools every Mac has, by the suffix the
    /// file actually ends with. Order matters: `.tar.gz` must be tested
    /// before `.gz`, or a tarball would be merely decompressed into a `.tar`.
    private static let archiveKinds: [(suffix: String, tool: ArchiveTool)] = [
        (".tar.gz", .tar), (".tgz", .tar), (".tar.bz2", .tar), (".tbz", .tar), (".tbz2", .tar),
        (".tar.xz", .tar), (".txz", .tar), (".tar.zst", .tar), (".tar", .tar),
        (".zip", .ditto), (".gz", .gunzip),
    ]

    private enum ArchiveTool { case tar, ditto, gunzip }

    /// Starts expanding `item` if it is an archive. `false` means "not one of
    /// ours" and the caller should fall back to opening it normally.
    ///
    /// 7-Zip and RAR are deliberately not here: macOS ships nothing that
    /// reads them, so the honest answer is to say so rather than to fail
    /// silently, which is what double-clicking one used to do.
    private func beginExtracting(_ item: MSLFileItem) -> Bool {
        let lower = item.name.lowercased()
        if lower.hasSuffix(".7z") || lower.hasSuffix(".rar") {
            errorMessage = "macOS can't open \u{201C}\(item.name)\u{201D} on its own. "
                + "Install something like Keka or The Unarchiver, or expand it inside a Linux instance."
            return true
        }
        guard let kind = Self.archiveKinds.first(where: { lower.hasSuffix($0.suffix) }) else { return false }
        let source = URL(fileURLWithPath: item.path)
        let parent = source.deletingLastPathComponent()
        guard canWrite else {
            errorMessage = "\u{201C}\(item.name)\u{201D} can't be expanded here - this location is read-only."
            return true
        }
        let base = String(item.name.dropLast(kind.suffix.count))
        Task { await extract(source, tool: kind.tool, into: parent, named: base) }
        return true
    }

    /// Runs the expansion off the main actor and then shows the result.
    ///
    /// Everything lands in a folder beside the archive (Finder's behaviour),
    /// uniquified rather than overwriting - expanding the same download twice
    /// must never silently replace what the first one produced. A lone `.gz`
    /// is one compressed file, not an archive, so it decompresses to a file.
    private func extract(_ source: URL, tool: ArchiveTool, into parent: URL, named base: String) async {
        let destination = Self.uniqueURL(in: parent, name: base, isDirectory: tool != .gunzip)
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                if tool != .gunzip {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                let process = Process()
                switch tool {
                case .tar:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    process.arguments = ["-xf", source.path, "-C", destination.path]
                case .ditto:
                    // `ditto -x -k` is what Archive Utility itself uses, and
                    // unlike `unzip` it keeps resource forks and permissions.
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-x", "-k", source.path, destination.path]
                case .gunzip:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                    process.arguments = ["-c", source.path]
                    process.standardOutput = try FileHandle(forWritingTo: {
                        FileManager.default.createFile(atPath: destination.path, contents: nil)
                        return destination
                    }())
                }
                let errors = Pipe()
                process.standardError = errors
                try process.run()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "MSLFiles", code: Int(process.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "the expander exited with status \(process.terminationStatus)"
                            : message.trimmingCharacters(in: .whitespacesAndNewlines),
                    ])
                }
                return .success(())
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            await reload()
            selection = [destination.path]
        case .failure(let error):
            errorMessage = "Couldn't expand \u{201C}\(source.lastPathComponent)\u{201D} - \(error.localizedDescription)"
        }
    }

    /// `name`, or `name 2`, `name 3`... - never overwriting what is there.
    static func uniqueURL(in parent: URL, name: String, isDirectory: Bool) -> URL {
        var candidate = parent.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path), index < 1000 {
            candidate = parent.appendingPathComponent("\(name) \(index)")
            index += 1
        }
        return candidate
    }

    func goTo(_ target: String) {
        pushHistory()
        if target.isEmpty {
            // The query root's own crumb - back to the search results.
            path = []
        } else if let index = path.firstIndex(of: target) {
            path = Array(path.prefix(through: index))
        } else {
            path = []
        }
        selection = []
        Task { await reload() }
    }

    func goUp() {
        guard !path.isEmpty else { return }
        pushHistory()
        path.removeLast()
        selection = []
        Task { await reload() }
    }

    func goBack() {
        guard let step = back.popLast() else { return }
        forward.append(currentStep())
        restore(step)
    }

    func goForward() {
        guard let step = forward.popLast() else { return }
        back.append(currentStep())
        restore(step)
    }

    private func currentStep() -> NavigationStep {
        NavigationStep(rootID: selectedRoot?.id ?? "", path: path)
    }

    /// Records where we are, so the next navigation can be undone. Any new
    /// navigation clears the forward stack - the same rule a browser uses,
    /// because a forward entry from an abandoned branch is misleading.
    private func pushHistory() {
        back.append(currentStep())
        forward.removeAll()
        if back.count > 100 { back.removeFirst() }
    }

    private func restore(_ step: NavigationStep) {
        if step.rootID != selectedRoot?.id,
           let root = roots.first(where: { $0.id == step.rootID }) {
            selectedRoot = root
        }
        path = step.path
        selection = []
        Task { await reload() }
    }

    // MARK: - Loading

    func reload() async {
        // The dashboard has no directory to list; it draws itself.
        if isShowingDashboard { items = []; return }
        if isShowingQueryResults, let kind = selectedRoot?.kind {
            await runQuery(kind)
            return
        }
        guard let provider else { items = []; return }
        loading = true
        defer { loading = false }
        let target = currentPath
        do {
            let listed = try await provider.list(target)
            items = listed
            directoryCache[target] = listed
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
        // Overlay the real Linux mode onto what the mount just gave us. The
        // rows are already on screen; this fills the permissions in after.
        overlayGuestModes(for: target)
        overlayGitBadges(for: target)
        // Column view needs every ancestor, not just the current directory.
        if viewMode == .column { await loadAncestors() }
    }

    /// Fetches the real Linux `st_mode` for a guest directory's rows from the
    /// `fileopsd` relay and merges it into `guestModes`, keyed by host path.
    ///
    /// Off the main actor (a socket round trip), newest-wins (an old
    /// directory's slow answer never clobbers the current one), and silent on
    /// failure: no relay, an old mslhd or a stopped instance just leaves the
    /// mode unknown, and the UI shows the mount listing without it. Cleared up
    /// front so a previous directory's permissions never linger on these rows.
    private func overlayGuestModes(for hostDir: String) {
        guestModes = [:]
        guard selectedRoot?.isGuest == true,
              case .guestFilesystem(let instance, let guestPath) =
                GuestPathMapper.map(hostPath: hostDir, guestMounts: guestMounts) else { return }
        let token = UUID()
        overlayToken = token
        let base = hostDir
        Task.detached(priority: .utility) {
            let entries = DaemonClient.guestList(instance: instance, guestPath: guestPath)
            guard let entries else { return }
            let modes = Dictionary(entries.map { ("\(base)/\($0.name)", $0.mode) },
                                   uniquingKeysWith: { first, _ in first })
            await MainActor.run {
                guard self.overlayToken == token else { return }
                self.guestModes = modes
            }
        }
    }

    /// Reads every git repository among this directory's subfolders, for the
    /// dots in the listing.
    ///
    /// Modelled on `overlayGuestModes`: off the main actor, newest-wins so a
    /// previous directory's slow answer never decorates these rows, cleared
    /// up front, and silent on failure - a folder MSL could not read simply
    /// has no dot.
    ///
    /// **One command for the whole directory**, not one per folder: this runs
    /// every time a directory is opened, so what matters is the number of
    /// round trips rather than the work inside one.
    private func overlayGitBadges(for hostDir: String) {
        gitBadges = [:]
        let token = UUID()
        gitBadgeToken = token
        let base = hostDir
        let mapped = GuestPathMapper.map(hostPath: hostDir, guestMounts: guestMounts)
        let isGuestRoot = selectedRoot?.isGuest == true

        Task.detached(priority: .utility) {
            var found: [String: Git.Badge] = [:]
            if case .guestFilesystem(let instance, let guestPath) = mapped {
                if case .success(let output) = DaemonClient.guestGit(
                    instance: instance, guestPath: guestPath, operation: .badges) {
                    found = Git.parseBadges(output)
                }
            } else if !isGuestRoot {
                found = GitService.badges(inDirectory: base)
            }
            guard !found.isEmpty else { return }
            let keyed = Dictionary(found.map { ("\(base)/\($0.key)", $0.value) },
                                   uniquingKeysWith: { first, _ in first })
            await MainActor.run {
                guard self.gitBadgeToken == token else { return }
                self.gitBadges = keyed
            }
        }
    }

    /// The git dot for a row, if this directory's pass found one.
    func gitBadge(for item: MSLFileItem) -> Git.Badge? {
        item.isBrowsableDirectory ? gitBadges[item.path] : nil
    }

    /// Re-reads the dots for the folder on screen.
    ///
    /// Editing a file *inside* a repository does not change the listing that
    /// contains it, so nothing about navigating would notice. This is called
    /// when the window comes forward and after the Git panel closes, which
    /// between them cover how the state actually changes - somebody worked in
    /// a terminal, or in an editor, and came back.
    func refreshGitBadges() {
        guard !currentPath.isEmpty else { return }
        overlayGitBadges(for: currentPath)
    }

    /// The real Linux mode for a row, if the overlay has it.
    func linuxMode(for item: MSLFileItem) -> UInt32? { guestModes[item.path] }

    /// A guest regular file that isn't already executable - what "Make
    /// Executable" offers itself for. Unknown mode (relay not answered yet)
    /// counts as eligible: the worst case is a harmless no-op chmod.
    func canMakeExecutable(_ paths: Set<String>) -> Bool {
        paths.contains { host in
            guard guestPath(forHostPath: host) != nil else { return false }
            // Only when the real mode is known: acting on an unknown mode would
            // have to guess the other permission bits, and guessing wide (0o755
            // over a private 0o600 file) would quietly world-read a secret.
            guard let mode = guestModes[host] else { return false }
            return LinuxFileMode.isRegularFile(mode) && !LinuxFileMode.isExecutable(mode)
        }
    }

    /// Sets the execute bits on guest files through the `fileopsd` relay -
    /// `chmod +x`, the "I downloaded a script and it won't run" fix that a
    /// WebDAV `PROPPATCH` can't do because its POSIX bits never reach Linux.
    func makeExecutable(_ paths: Set<String>) {
        let targets: [(instance: String, guestPath: String, mode: UInt32)] = paths.compactMap { host in
            // Only a guest's *own* filesystem: chmod'ing a Mac-home file
            // (`/mnt/mac`) would change it on the Mac, which isn't the intent.
            guard case .guestFilesystem(let instance, let guestPath) =
                    GuestPathMapper.map(hostPath: host, guestMounts: guestMounts) else { return nil }
            // Only files whose real mode we know: preserve every other bit and
            // add execute, never invent a mode (see `canMakeExecutable`).
            guard let current = guestModes[host] else { return nil }
            let mode = (current & 0o7777) | 0o111
            return (instance, guestPath, mode)
        }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let anyFailed = targets.contains { target in
                !DaemonClient.guestChmod(instance: target.instance,
                                         guestPath: target.guestPath, mode: target.mode)
            }
            await MainActor.run {
                if anyFailed {
                    self.errorMessage = "Couldn't change permissions - the instance may be stopped or its image too old."
                }
                Task { await self.reload() }
            }
        }
    }

    private func runQuery(_ kind: FileRoot.Kind) async {
        loading = true
        errorMessage = nil
        let scope: SpotlightQuery.Scope
        switch kind {
        case .tag(let name): scope = .tag(name)
        case .recents: scope = .recents
        case .directory, .dashboard: return
        }
        let results: [MSLFileItem] = await withCheckedContinuation { continuation in
            spotlight.run(scope) { continuation.resume(returning: $0) }
        }
        items = results
        loading = false
    }

    /// Fills the cache for every column left of the current one.
    func loadAncestors() async {
        guard let provider else { return }
        for crumb in breadcrumbs where directoryCache[crumb.path] == nil {
            directoryCache[crumb.path] = (try? await provider.list(crumb.path)) ?? []
        }
    }

    // MARK: - Mutations

    func newFolder() {
        run { provider in
            var name = "untitled folder"
            var attempt = 2
            while FileManager.default.fileExists(
                atPath: (self.currentPath as NSString).appendingPathComponent(name)) {
                name = "untitled folder \(attempt)"
                attempt += 1
            }
            try await provider.createDirectory(
                at: (self.currentPath as NSString).appendingPathComponent(name))
        }
    }

    func rename(_ item: MSLFileItem, to newName: String) {
        renaming = nil
        guard newName != item.name else { return }
        run { provider in try await provider.rename(item.path, to: newName) }
    }

    // MARK: - Power Rename

    /// The paths the Power Rename sheet is open for, sorted so the numbering in
    /// the preview matches the order they'll be renamed. Empty means closed.
    @Published var powerRenameTargets: [String] = []

    /// The names already in the current directory - what a Power Rename preview
    /// checks new names against for collisions.
    var currentDirectoryNames: Set<String> { Set(items.map(\.name)) }

    func beginPowerRename(_ paths: Set<String>) {
        guard canWrite else { return }
        powerRenameTargets = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Applies a computed Power Rename. Renames in two passes - everything to a
    /// unique temporary name first, then to its final name - so a batch that
    /// shuffles names among itself (a->b, b->c) can't have one step clobber a
    /// file another step still needs. Only rows that actually change and carry
    /// no problem are touched.
    func applyPowerRename(_ previews: [PowerRename.Preview]) {
        let changes = previews.filter { $0.changed && $0.problem == nil }
        powerRenameTargets = []
        guard !changes.isEmpty else { return }
        run { provider in
            var staged: [(tempPath: String, finalName: String)] = []
            for change in changes {
                let dir = (change.id as NSString).deletingLastPathComponent
                let tempName = ".msl-rename-\(UUID().uuidString)"
                try await provider.rename(change.id, to: tempName)
                staged.append(((dir as NSString).appendingPathComponent(tempName), change.newName))
            }
            for item in staged {
                try await provider.rename(item.tempPath, to: item.finalName)
            }
        }
    }

    /// Moves to the Trash where the volume has one, and asks first where it
    /// does not.
    ///
    /// Finder's Delete is recoverable, so this one has to be too wherever
    /// that is possible. On a volume with no Trash - the guest, over a
    /// network mount - the only options are "delete for good" or "do
    /// nothing", and doing that silently on a keystroke someone believes is
    /// undoable is how work gets lost.
    func delete(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        run { provider in
            var unsupported: Set<String> = []
            for path in paths {
                if try await provider.trash(path) == false { unsupported.insert(path) }
            }
            if !unsupported.isEmpty {
                await MainActor.run { self.pendingPermanentDelete = unsupported }
            }
        }
    }

    // MARK: - Go

    /// Navigates to any absolute path, picking whichever root contains it.
    ///
    /// This is what makes Finder's Go menu and ⇧⌘G work: those name a
    /// destination, not a root plus a path within it. The deepest matching
    /// root wins, so `~/Documents` opens under Documents rather than under
    /// Macintosh HD, and the breadcrumbs read the way the user expects.
    /// The "/" root is the backstop that always matches.
    func navigate(to target: String) {
        let target = (target as NSString).expandingTildeInPath
        var resolved = (target as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            errorMessage = "“\(target)” doesn't exist."
            return
        }
        // Pointed at a file, go to its folder and select it - Finder does
        // the same rather than refusing.
        var selectAfterwards: String?
        if !isDirectory.boolValue {
            selectAfterwards = resolved
            resolved = (resolved as NSString).deletingLastPathComponent
        }

        // Only real directory roots are navigation targets. The query roots
        // (Recents, tags) and the MSL dashboard aren't places - and the
        // dashboard's path is the home directory, so before this it tied with
        // Home and could win, landing a shortcut back on the dashboard instead
        // of opening the folder.
        let candidates = roots.filter {
            $0.kind == .directory
                && (resolved == $0.path || resolved.hasPrefix($0.path == "/" ? "/" : $0.path + "/"))
        }
        guard let root = candidates.max(by: { $0.path.count < $1.path.count }) else {
            errorMessage = "No place to show “\(resolved)”."
            return
        }

        pushHistory()
        selectedRoot = root
        path = Self.chain(from: root.path, to: resolved)
        selection = selectAfterwards.map { [$0] } ?? []
        Task { await reload() }
    }

    /// Every directory between a root and a target, so the breadcrumbs and
    /// column view have the full chain rather than a single jump.
    private static func chain(from root: String, to target: String) -> [String] {
        guard target != root else { return [] }
        let rootComponents = (root as NSString).pathComponents
        let targetComponents = (target as NSString).pathComponents
        guard targetComponents.count > rootComponents.count else { return [] }
        return (rootComponents.count..<targetComponents.count).map { index in
            NSString.path(withComponents: Array(targetComponents[0...index]))
        }
    }

    func goToRoot(id: String) {
        guard let root = roots.first(where: { $0.id == id }) else { return }
        select(root)
    }

    /// The menu-bar equivalents of what the toolbar and context menu do.
    /// They live here rather than in the view so the menu bar can reach
    /// them through the focused model without duplicating the logic.
    func openSelection() {
        guard let path = selection.first,
              let item = visibleItems.first(where: { $0.path == path }) else { return }
        open(item)
    }

    func showInfoForSelection() {
        if let item = focusedItem { infoTarget = item }
    }

    func beginRenamingSelection() {
        if selection.count == 1 { renaming = selection.first }
    }

    func quickLookSelection() {
        if let path = selection.first { quickLook(path: path) }
    }

    /// Opens Quick Look for a path, resolving it to the row we already know so
    /// the peek can show that row's kind, size and Linux mode. Falls back to a
    /// bare item if the path isn't in the current listing (it always is today,
    /// but a synthesized item still previews correctly).
    func quickLook(path: String) {
        let item = items.first { $0.path == path }
            ?? MSLFileItem(path: path, name: (path as NSString).lastPathComponent,
                           isDirectory: false, size: 0, modified: nil)
        quickLookTarget = QuickLookTarget(item: item)
    }

    func copyPathOfSelection() { copyPaths(selection) }

    /// Finder's ⌥⌘C: the full POSIX path, one per line for a multiple
    /// selection.
    ///
    /// One method rather than two because the menu bar and the context menu
    /// both need it and had drifted apart - the context menu was copying
    /// only the row under the cursor while "Copy" beside it took the whole
    /// selection, so the same right-click produced three files and one path.
    func copyPaths(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
    }

    /// Sniffed once per path: reading the leading bytes over the mount is a
    /// round trip, and the context menu that asks this is rebuilt often.
    private var textSniffCache: [String: Bool] = [:]

    /// Whether to offer "Edit as Text…" and a text preview for this row.
    ///
    /// The name decides it for the common Linux files (`fstab`, `.bashrc`, a
    /// unit file) with no read at all. For everything else that isn't a
    /// directory or a bundle and is small enough - the extensionless build
    /// script, the odd-suffix config - the leading bytes decide, so a text
    /// file MSL Files has never seen the name of still opens, and a binary
    /// with a text-shaped name doesn't pretend it can.
    func canEditAsText(_ item: MSLFileItem) -> Bool {
        guard !item.isDirectory, !item.isBundle else { return false }
        if TextFileKind.looksEditable(name: item.name) { return true }
        // A *declared* extension already answers the question without a read:
        // `.png`/`.so`/`.gz` are text-or-not by definition. Only files with no
        // extension, or one macOS doesn't recognise, reach the byte sniff -
        // which matters because that read is synchronous and, on a guest root,
        // goes over the WebDAV mount (a paused instance would wake mid-read).
        let ext = (item.name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared {
            return type.conforms(to: .text)
        }
        guard item.size <= UInt64(TextFileKind.editableByteLimit) else { return false }
        if let cached = textSniffCache[item.path] { return cached }
        // A short, bounded read of the head of the file - not the whole thing.
        let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: item.path))
        let sample = (try? handle?.read(upToCount: TextFileKind.sniffByteCount)) ?? nil
        try? handle?.close()
        let verdict = sample.map(TextFileKind.looksTextual(sample:)) ?? false
        textSniffCache[item.path] = verdict
        return verdict
    }

    /// The Linux path a host path has *inside a guest*, if any guest can see
    /// it - the item's own path, not its enclosing folder (unlike
    /// `guestMapping`, which a shell needs a directory for).
    /// Opens the git panel on whichever folder the person means: a selected
    /// folder, or the one being browsed.
    func showGitForSelectionOrCurrentFolder() {
        if let item = focusedItem, item.isBrowsableDirectory {
            gitTarget = GitPanelTarget(path: item.path, name: item.name)
            return
        }
        let path = currentPath
        let name = (path as NSString).lastPathComponent
        gitTarget = GitPanelTarget(path: path, name: name.isEmpty ? path : name)
    }

    /// Which instance a Mac path actually lives inside, or nil for an
    /// ordinary Mac folder.
    ///
    /// Note that the Mac's own home directory is shared *into* every
    /// instance, so a path there maps to a guest path without belonging to
    /// any one instance - which is why this returns nil for that case while
    /// `guestPath(forHostPath:)` returns a path. Anything that must run
    /// inside a particular guest needs this one.
    func instanceOwning(hostPath: String) -> String? {
        switch GuestPathMapper.map(hostPath: hostPath, guestMounts: guestMounts) {
        case .guestFilesystem(let instance, _): return instance
        case .macHomeShare, .unreachable: return nil
        }
    }

    func guestPath(forHostPath hostPath: String) -> String? {
        switch GuestPathMapper.map(hostPath: hostPath, guestMounts: guestMounts) {
        case .guestFilesystem(_, let guestPath), .macHomeShare(let guestPath):
            return guestPath
        case .unreachable:
            return nil
        }
    }

    /// Whether any of these rows maps to a Linux path - what "Copy Linux Path"
    /// checks before offering itself. A folder deep in the Mac filesystem, or
    /// on another volume, has no guest path at all.
    func hasLinuxPath(_ paths: Set<String>) -> Bool {
        paths.contains { guestPath(forHostPath: $0) != nil }
    }

    /// The Linux path(s) for these rows, one per line - the path your guest
    /// shell, a Dockerfile `COPY`, or a config file wants, not the
    /// `/Volumes/127.0.0.1/...` the Mac sees.
    func copyLinuxPaths(_ paths: Set<String>) {
        let mapped = paths.sorted().compactMap { guestPath(forHostPath: $0) }
        guard !mapped.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mapped.joined(separator: "\n"), forType: .string)
    }

    func revealSelectionInFinder() {
        let urls = selection.sorted().map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Opening a shell here

    /// Where a shell should start for this row: the folder itself, or the
    /// folder containing the file. Finder's "New Terminal at Folder" does
    /// the same, and it is what makes the item useful on a file.
    func shellDirectory(for item: MSLFileItem) -> String {
        item.isBrowsableDirectory
            ? item.path
            : (item.path as NSString).deletingLastPathComponent
    }

    /// Every running instance's host mount. `FilesModel` only builds a
    /// `.linux` root when the daemon reported a `sandboxMountPath`, and it
    /// reports one only while the instance is running - so this is already
    /// "the instances a shell could actually be opened in".
    var guestMounts: [GuestMount] {
        // `name` is load-bearing here: for a `.linux` root it is the
        // instance name verbatim (`rebuildRoots` sets `name: instance.name`
        // and puts the pretty "Alpine · Linux" string in `subtitle`), and it
        // is passed straight to `msl <instance>`. Decorating it for display
        // would produce `msl 'Alpine - default'` and fail at the Terminal
        // layer with nothing useful to read - put such things in `subtitle`.
        roots(in: .linux).map { GuestMount(instance: $0.name, mountPath: $0.path) }
    }

    /// Where this row lives as far as a guest is concerned.
    ///
    /// Resolved from the path, never from `selectedRoot`: the Tags and
    /// Recents roots are Spotlight queries over the home folder, so their
    /// rows are host paths regardless of which root the user is looking at.
    func guestMapping(for item: MSLFileItem) -> GuestPathMapping {
        GuestPathMapper.map(hostPath: shellDirectory(for: item), guestMounts: guestMounts)
    }

    /// Opens Terminal.app on the Mac side, at this row's folder.
    /// `nil` means the folder being shown, which is what the background
    /// menu asks for; an item means that row's folder (or its parent).
    func openInTerminal(_ item: MSLFileItem?) {
        let directory = item.map { shellDirectory(for: $0) } ?? currentPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", directory]
        do {
            try process.run()
        } catch {
            errorMessage = "Couldn't open Terminal here. (\(error.localizedDescription))"
        }
    }

    /// Opens a Linux shell in `instance`, already `cd`-ed to this row.
    ///
    /// Goes through Terminal.app for the same reason `AppModel.openTerminal`
    /// does: `msl` is an interactive terminal program and needs a real tty,
    /// which a `Process` launched from here would not give it.
    ///
    /// The quoting is the delicate part, because the command crosses four
    /// layers on the way to the guest - the AppleScript string literal,
    /// Terminal's own shell, `msl` re-joining its argv with spaces, and
    /// finally `sh -c` inside the guest. The guest command is therefore
    /// quoted as **one** shell word here, so Terminal's shell hands `msl` a
    /// single argument and the quotes that the guest's shell needs are still
    /// intact when they get there.
    /// Deliberately recomputes the mapping rather than taking a path from
    /// the caller. Passing the guest path in would let the view hand over
    /// one derived from `item.path` while the enable/disable state came
    /// from `guestMapping(for:)` - which resolves the *enclosing* folder
    /// for a file - and the shell would open somewhere other than the
    /// greyed-out check was reasoning about.
    func openInMSL(_ item: MSLFileItem, instance: String) {
        let guestPath: String
        switch guestMapping(for: item) {
        case .guestFilesystem(_, let path): guestPath = path
        case .macHomeShare(let path): guestPath = path
        case .unreachable:
            errorMessage = "\u{201C}\(item.name)\u{201D} isn't visible from inside Linux."
            return
        }
        let line = [MSLPaths.tool("msl").path, instance,
                    GuestPathMapper.interactiveShellCommand(in: guestPath)]
            .map(DesktopEntry.shellQuote)
            .joined(separator: " ")
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptLiteral(line))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            errorMessage = "Couldn't open a Linux shell here. (\(error.localizedDescription))"
        }
    }

    /// Escapes a shell command line for embedding in an AppleScript string
    /// literal. Backslash first - escaping it after the quotes would double
    /// the backslashes this very step introduced.
    private func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Opens Terminal.app running a deep disk report inside `instance` - the
    /// authoritative guest view of the disk, in one click. Starts the instance
    /// if it isn't running (any `msl <instance>` session boots it), so it
    /// works from a stopped instance too.
    ///
    /// The report is a script written to the Mac-home share (`/mnt/mac`),
    /// never an inline `sh -c`: the guest's shell drops the quotes on a
    /// one-liner passed through `msl` and the command hangs (a scar this
    /// project already carries). Running `sh <path>` hands the guest one
    /// argument - a path - and sidesteps all of it.
    func analyzeGuestDisk(instance: String) {
        // Written to a no-space path under home, so the guest reaches it at a
        // predictable /mnt/mac path with nothing to quote.
        let hostScript = NSHomeDirectory() + "/.msl-disk-analysis.sh"
        let guestScript = GuestPathMapper.macHomeMountPoint + "/.msl-disk-analysis.sh"
        let report = """
        #!/bin/sh
        echo '===== Disk usage (df -h) ====='; df -h
        echo; echo '===== Root filesystem ====='; df -h /
        echo; echo '===== Inodes (df -i) ====='; df -i
        echo; echo '===== Largest directories under / (this can take a moment) ====='
        du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -20
        echo; echo '===== Mounts ====='; mount | grep -v -e cgroup -e /sys -e /proc
        echo; echo '(disk report complete)'
        """
        do {
            try report.write(toFile: hostScript, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't prepare the disk report. (\(error.localizedDescription))"
            return
        }
        // `msl <instance> -u root sh <script>` - instance boots if stopped,
        // runs as root so `du /` can read everything, output stays on screen.
        let line = [MSLPaths.tool("msl").path, instance, "-u", "root", "sh", guestScript]
            .map(DesktopEntry.shellQuote)
            .joined(separator: " ")
        let script = """
        tell application "Terminal"
            activate
            do script "clear; echo 'Analyzing \(appleScriptLiteral(instance))…'; \(appleScriptLiteral(line))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            errorMessage = "Couldn't open the disk report. (\(error.localizedDescription))"
        }
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.path))
    }

    // MARK: - Selection

    /// Where a shift-click measures from. Finder extends from the last
    /// item clicked without a modifier, not from the nearest edge.
    private var selectionAnchor: String?

    /// One click on an item, with Finder's modifier rules.
    ///
    /// Selection is handled here rather than left to `List(selection:)`
    /// because a row carrying an `.onTapGesture(count: 2)` - which every
    /// row needs, since double-click is how a file browser opens things -
    /// swallows the single click before the list's own selection handling
    /// ever sees it. Rows looked selectable and simply were not. Doing it
    /// explicitly also means icon and gallery view get the same
    /// ⌘-toggle/⇧-extend behaviour for free, which they had no way to
    /// inherit.
    func handleTap(on item: MSLFileItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.path) {
                selection.remove(item.path)
            } else {
                selection.insert(item.path)
            }
            setAnchor(item.path)
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let ordered = visibleItems.map(\.path)
            if let start = ordered.firstIndex(of: anchor),
               let end = ordered.firstIndex(of: item.path) {
                let range = start <= end ? start...end : end...start
                selection = rangeBase.union(ordered[range])
                selectionCursor = item.path
                return
            }
        }
        selection = [item.path]
        setAnchor(item.path)
    }

    /// What was selected besides the range when the anchor was set. A shift
    /// range is added on top of it, which is AppKit's rule: items picked with
    /// ⌘ survive a later shift-click, and shift-clicking back toward the anchor
    /// shrinks the range instead of only ever growing it.
    private var rangeBase: Set<String> = []

    private func setAnchor(_ path: String) {
        selectionAnchor = path
        selectionCursor = path
        rangeBase = selection.subtracting([path])
    }

    /// Where the arrow keys move from: the last item clicked or arrived at.
    private var selectionCursor: String?

    /// Arrow-key navigation, the same in every view mode now that selection
    /// lives in the model rather than in a `List`. `extend` (shift) grows the
    /// selection from the anchor, as Finder does.
    func moveSelection(by delta: Int, extend: Bool) {
        let ordered = visibleItems.map(\.path)
        guard !ordered.isEmpty else { return }
        let from = selectionCursor.flatMap { ordered.firstIndex(of: $0) }
            ?? selection.compactMap { ordered.firstIndex(of: $0) }.max()
        let target: Int
        if let from {
            target = min(max(from + delta, 0), ordered.count - 1)
        } else {
            target = delta >= 0 ? 0 : ordered.count - 1
        }
        let path = ordered[target]
        if extend, let anchor = selectionAnchor, let start = ordered.firstIndex(of: anchor) {
            let range = start <= target ? start...target : target...start
            selection = rangeBase.union(ordered[range])
            selectionCursor = path
        } else {
            selection = [path]
            setAnchor(path)
        }
    }

    /// Applies or removes a tag across the selection.
    ///
    /// A no-op on the guest rather than an error: macOS tags are an
    /// extended attribute a Linux filesystem reached over WebDAV cannot
    /// carry, so the menu reports that instead of failing per file.
    func toggleTag(_ name: String, on paths: Set<String>) {
        guard !paths.isEmpty else { return }
        Task {
            do {
                for path in paths { try FileTagStore.toggle(name, at: path) }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't change tags here. \(error.localizedDescription)"
            }
            await reload()
        }
    }

    /// Puts the selection on the pasteboard as file URLs, which is what
    /// Finder does - so a copy here pastes into Finder and vice versa.
    func copyToPasteboard(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let urls = paths.sorted().map { URL(fileURLWithPath: $0) as NSURL }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    var pasteboardHasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    func pasteFromPasteboard() {
        guard canWrite,
              let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return }
        receive(urls)
    }

    /// Finder's ⌃⌘N: put the selection into a new folder together.
    func newFolderWithSelection() {
        guard canWrite, !selection.isEmpty else { return }
        let targets = selection
        run { provider in
            var name = "New Folder With Items"
            var attempt = 2
            let parent = self.currentPath
            while FileManager.default.fileExists(
                atPath: (parent as NSString).appendingPathComponent(name)) {
                name = "New Folder With Items \(attempt)"
                attempt += 1
            }
            let folder = (parent as NSString).appendingPathComponent(name)
            try await provider.createDirectory(at: folder)
            for path in targets {
                let destination = (folder as NSString)
                    .appendingPathComponent((path as NSString).lastPathComponent)
                try FileManager.default.moveItem(atPath: path, toPath: destination)
            }
        }
    }

    /// Finder's Compress. Uses `ditto` rather than `zip` because that is
    /// what Finder itself runs: it preserves resource forks and HFS
    /// metadata, so the archive is the same one Finder would have made.
    func compress(_ paths: Set<String>) {
        guard canWrite, !paths.isEmpty else { return }
        let targets = paths.sorted()
        run { _ in
            let parent = self.currentPath
            let base = targets.count == 1
                ? ((targets[0] as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                : "Archive"
            var name = "\(base).zip"
            var attempt = 2
            while FileManager.default.fileExists(
                atPath: (parent as NSString).appendingPathComponent(name)) {
                name = "\(base) \(attempt).zip"
                attempt += 1
            }
            let destination = (parent as NSString).appendingPathComponent(name)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
                + targets + [destination]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MSLFileError.notWritable("Compressing")
            }
        }
    }

    /// Finder's ⌘D: a copy beside the original, named "x copy".
    func duplicate(_ paths: Set<String>) {
        guard canWrite, !paths.isEmpty else { return }
        run { provider in
            for path in paths {
                let source = URL(fileURLWithPath: path)
                let ext = source.pathExtension
                let stem = source.deletingPathExtension().lastPathComponent
                let directory = source.deletingLastPathComponent()

                var candidate = "\(stem) copy"
                var attempt = 2
                while FileManager.default.fileExists(atPath: directory
                    .appendingPathComponent(candidate)
                    .appendingPathExtension(ext).path) {
                    candidate = "\(stem) copy \(attempt)"
                    attempt += 1
                }
                let destination = ext.isEmpty
                    ? directory.appendingPathComponent(candidate)
                    : directory.appendingPathComponent(candidate).appendingPathExtension(ext)
                try await provider.exportFile(path, to: destination)
            }
        }
    }

    /// Free space on the volume holding the current directory, the way
    /// Finder's status bar reports it.
    var availableCapacity: String? {
        guard let root = selectedRoot else { return nil }
        let values = try? URL(fileURLWithPath: root.path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Deletes for good, after the user has confirmed there is no Trash.
    func confirmPermanentDelete() {
        let targets = pendingPermanentDelete
        pendingPermanentDelete = []
        run { provider in
            for path in targets { try await provider.remove(path) }
        }
    }

    /// Accepts a drop of host file URLs into `directory` (the current one
    /// unless a folder was the drop target).
    func receive(_ urls: [URL], into directory: String? = nil) {
        let destination = directory ?? currentPath
        // Read now, on the main actor, while the drop is still happening -
        // by the time the work below runs the key may be back up.
        let forceCopy = NSEvent.modifierFlags.contains(.option)
        run { provider in
            for url in urls {
                if !forceCopy, Self.sameFilesystem(url.path, destination) {
                    try Self.move(url.path, into: destination)
                    continue
                }
                // Dropping a folder is a recursive copy; `copyItem` already
                // does that, so nothing special is needed beyond letting it.
                try await provider.importFile(from: url, into: destination)
                await self.restoreExecutableBits(from: url, landingIn: destination)
            }
        }
    }

    /// Whether a row's path is a folder files can be dropped into, for the
    /// AppKit drop destination resolving what is under the cursor.
    func dropFolder(at path: String) -> String? {
        guard canWrite,
              let item = visibleItems.first(where: { $0.path == path }),
              item.isBrowsableDirectory
        else { return nil }
        return item.path
    }

    /// Whether a drag within this pair of paths should move rather than copy.
    ///
    /// Finder's rule, and what people mean by "proper" drag and drop: within
    /// one volume a drag moves, across volumes it copies, and holding option
    /// always copies. Dragging a file into a sibling folder and finding two
    /// of it is the thing that makes a file browser feel wrong.
    ///
    /// The test is the device number rather than anything about MSL,
    /// because that is exactly the condition under which a move is possible
    /// at all: `rename(2)` cannot cross a filesystem. It also lands the
    /// Mac/Linux question on the right answer without having to ask it -
    /// an instance's mount is its own device, so Mac to Linux and between
    /// two instances both copy.
    nonisolated static func sameFilesystem(_ source: String, _ destination: String) -> Bool {
        var a = stat(), b = stat()
        guard stat(source, &a) == 0, stat(destination, &b) == 0 else { return false }
        return a.st_dev == b.st_dev
    }

    /// Moves, refusing to clobber and refusing to swallow a folder into
    /// itself - which `rename(2)` would otherwise report as a baffling
    /// EINVAL after the row had already disappeared.
    nonisolated static func move(_ source: String, into directory: String) throws {
        let name = (source as NSString).lastPathComponent
        let target = (directory as NSString).appendingPathComponent(name)
        guard target != source else { return }
        guard !directory.hasPrefix(source + "/") else {
            throw MSLFileError.alreadyExists(name)
        }
        guard !FileManager.default.fileExists(atPath: target) else {
            throw MSLFileError.alreadyExists(name)
        }
        try FileManager.default.moveItem(atPath: source, toPath: target)
    }

    /// Puts back the executable bit that the WebDAV mount drops on the way
    /// into an instance.
    ///
    /// **A dragged script arrives unrunnable otherwise.** The mount does not
    /// carry POSIX modes through to the real Linux inode - which is why
    /// "Make Executable" exists as a separate daemon round trip at all - so
    /// a `-rwxr-xr-x` file on the Mac lands as `-rw-r--r--` in the guest,
    /// and the person who dragged it over gets "permission denied" from a
    /// file they can see is theirs.
    ///
    /// **The mount lies in both directions, which is why neither mode here
    /// comes from it.** Asked about a file that is really `644` inside the
    /// instance, the mount reports `700`. Trusting it would make every
    /// drag between two Linux folders mark its file executable and flatten
    /// the group and other bits on the way past - a worse bug than the one
    /// being fixed. So the source mode is read from the instance when the
    /// source is itself inside one, and only the executable bits are ever
    /// taken from it; everything else about the landed file's mode is left
    /// exactly as the instance already has it.
    private func restoreExecutableBits(from source: URL, landingIn directory: String) async {
        let landed = (directory as NSString)
            .appendingPathComponent(source.lastPathComponent)
        guard let instance = instanceOwning(hostPath: landed),
              let landedGuestPath = guestPath(forHostPath: landed) else { return }

        guard let executable = await executableBits(of: source), executable != 0 else { return }

        // The landed file's real mode, from the instance rather than the
        // mount, so the bits that are not ours to touch survive.
        let parent = (landedGuestPath as NSString).deletingLastPathComponent
        let name = (landedGuestPath as NSString).lastPathComponent
        let landedMode = await Task.detached(priority: .utility) {
            DaemonClient.guestList(instance: instance, guestPath: parent)?
                .first { $0.name == name }?.mode
        }.value
        guard let landedMode else { return }

        let wanted = (landedMode & 0o7777) | executable
        guard wanted != (landedMode & 0o7777) else { return }
        _ = await Task.detached(priority: .utility) {
            DaemonClient.guestChmod(instance: instance, guestPath: landedGuestPath, mode: wanted)
        }.value
    }

    /// The executable bits of the file being dropped, from whichever side of
    /// the line actually knows them.
    private func executableBits(of source: URL) async -> UInt32? {
        // A source inside an instance: ask the instance, because the mount
        // would answer 700 whatever the truth is.
        if let sourceInstance = instanceOwning(hostPath: source.path),
           let sourceGuestPath = guestPath(forHostPath: source.path) {
            let parent = (sourceGuestPath as NSString).deletingLastPathComponent
            let name = (sourceGuestPath as NSString).lastPathComponent
            let mode = await Task.detached(priority: .utility) {
                DaemonClient.guestList(instance: sourceInstance, guestPath: parent)?
                    .first { $0.name == name }?.mode
            }.value
            return mode.map { $0 & 0o111 }
        }
        // An ordinary Mac file, where the mode means what it says.
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        return (attributes?[.posixPermissions] as? NSNumber).map { $0.uint32Value & 0o111 }
    }

    private func run(_ work: @escaping (LocalFileProvider) async throws -> Void) {
        guard let provider else { return }
        Task {
            do {
                try await work(provider)
                errorMessage = nil
            } catch {
                markReadOnlyIfVolumeRefused(error)
                errorMessage = error.localizedDescription
            }
            // Anything written invalidates ancestors too - a new folder
            // changes its parent's listing, which column view is showing.
            directoryCache.removeAll(keepingCapacity: true)
            await reload()
        }
    }

    /// Turns "that write failed because the volume is read-only" into "this
    /// root is read-only", so the UI stops offering what cannot work.
    /// See `isReadOnlyVolumeError` for why this is discovered and not
    /// predicted.
    private func markReadOnlyIfVolumeRefused(_ error: Error) {
        guard isReadOnlyVolumeError(error), let current = selectedRoot,
              !current.readOnly else { return }

        let corrected = FileRoot(
            id: current.id, name: current.name, subtitle: current.subtitle,
            symbol: current.symbol, path: current.path, isGuest: current.isGuest,
            isDevelopment: current.isDevelopment, readOnly: true,
            section: current.section)
        if let index = roots.firstIndex(where: { $0.id == current.id }) { roots[index] = corrected }
        selectedRoot = corrected
    }
}
