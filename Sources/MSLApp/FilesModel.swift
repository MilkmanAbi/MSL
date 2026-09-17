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

        var isQuery: Bool { self != .directory }
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
    let url: URL
    var id: String { url.path }
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
    @Published var selectedRoot: FileRoot?
    @Published var path: [String] = []
    @Published var items: [MSLFileItem] = []
    @Published var selection: Set<String> = []
    @Published var showHidden = false
    @Published var search = ""
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var renaming: String?
    @Published var quickLookTarget: QuickLookTarget?
    @Published var infoTarget: MSLFileItem?
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

    /// `visibleItems` split into Finder's group headings. A single unnamed
    /// group when grouping is off, so the views can render one shape rather
    /// than branching.
    var groupedItems: [(title: String, items: [MSLFileItem])] {
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
    @Published private var directoryCache: [String: [MSLFileItem]] = [:]

    /// Held for its lifetime: `NSMetadataQuery` is notification-driven and
    /// silently never fires if it is released.
    private let spotlight = SpotlightQuery()

    private var back: [NavigationStep] = []
    private var forward: [NavigationStep] = []

    private var provider: LocalFileProvider? { selectedRoot?.provider }

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

    var visibleItems: [MSLFileItem] {
        var result = showHidden ? items : items.filter { !$0.isHidden }
        if !search.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return sorted(result)
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
    var columnChain: [(path: String, items: [MSLFileItem], selected: String?)] {
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
        let home = NSHomeDirectory()
        var built: [FileRoot] = [
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
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first
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

    /// Handles `msl://files?instance=<name>&path=<guest path>[&select=1]`.
    /// Returns whether the URL was one; the path is shown now if the
    /// instance's root exists, or as soon as it appears.
    @discardableResult
    func reveal(_ url: URL) -> Bool {
        guard url.scheme == "msl", url.host == "files",
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

    func open(_ item: MSLFileItem) {
        guard item.isBrowsableDirectory else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        pushHistory()
        path.append(item.path)
        selection = []
        Task { await reload() }
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
        // Column view needs every ancestor, not just the current directory.
        if viewMode == .column { await loadAncestors() }
    }

    private func runQuery(_ kind: FileRoot.Kind) async {
        loading = true
        errorMessage = nil
        let scope: SpotlightQuery.Scope
        switch kind {
        case .tag(let name): scope = .tag(name)
        case .recents: scope = .recents
        case .directory: return
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

        let candidates = roots.filter {
            !$0.kind.isQuery
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
        if let path = selection.first {
            quickLookTarget = QuickLookTarget(url: URL(fileURLWithPath: path))
        }
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
    func openInTerminal(_ item: MSLFileItem) {
        let directory = shellDirectory(for: item)
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
                selectionAnchor = item.path
            }
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let ordered = visibleItems.map(\.path)
            if let start = ordered.firstIndex(of: anchor),
               let end = ordered.firstIndex(of: item.path) {
                let range = start <= end ? start...end : end...start
                selection = Set(ordered[range])
                return
            }
        }
        selection = [item.path]
        selectionAnchor = item.path
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
        run { provider in
            for url in urls {
                // Dropping a folder is a recursive copy; `copyItem` already
                // does that, so nothing special is needed beyond letting it.
                try await provider.importFile(from: url, into: destination)
            }
        }
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
