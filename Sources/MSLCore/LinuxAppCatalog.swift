import AppKit
import Foundation

/// One Linux application, as MSL shows it: a `.desktop` entry that has
/// been resolved far enough to put on screen and turn into a real macOS
/// `.app`.
public struct LinuxApp: Identifiable, Codable, Hashable {
    public var id: String { desktopPath }
    public let desktopPath: String
    public let name: String
    public let command: String
    public let comment: String?
    /// Filename of the extracted icon inside the instance's catalog
    /// directory, if one was found in the guest.
    public var iconFile: String?
    /// The raw `Icon=` value, kept so a better icon can be fetched later
    /// without re-scanning every `.desktop` file in the instance.
    public var iconName: String?
    /// Whether `iconFile` is the best available art (a vector, or a large
    /// bitmap) rather than the small one grabbed during a scan.
    public var iconIsHighResolution: Bool = false
    /// Which packaging system exported this entry.
    public var source: AppSource = .system

    public init(
        desktopPath: String, name: String, command: String, comment: String?,
        iconFile: String? = nil, iconName: String? = nil,
        iconIsHighResolution: Bool = false, source: AppSource = .system
    ) {
        self.desktopPath = desktopPath
        self.name = name
        self.command = command
        self.comment = comment
        self.iconFile = iconFile
        self.iconName = iconName
        self.iconIsHighResolution = iconIsHighResolution
        self.source = source
    }

    /// Distinguishes two entries the user sees under the same name - the
    /// same app packaged twice is common once Flatpak and Snap are scanned.
    public var qualifiedName: String {
        source == .system ? name : "\(name) (\(source.label))"
    }
}

/// Scans an instance for its installed GUI applications, pulls their icons
/// out of the guest, and caches both on the host.
///
/// The cache is what makes the app usable: scanning needs the VM *running*,
/// and booting a VM to redraw a list the user has already seen would be
/// absurd. So a scan is an explicit, visible action, and its results
/// persist in `MSLPaths.appCatalogDirectory(instance:)` until the next one.
public enum LinuxAppCatalog {
    /// Byte cap while scanning. Small on purpose: this runs for every app
    /// at once, and a vector icon - which is what the scorer prefers
    /// anyway - is usually a few kilobytes.
    private static let scanIconBytes = 150_000

    /// Byte cap when fetching one specific icon because the user is
    /// actually turning that app into a macOS bundle. Much larger: it is a
    /// single file, and this is the art that ends up in the `.icns`.
    private static let bundleIconBytes = 4_000_000

    // MARK: - Scanning

    /// Scans `instance` (which must be running) and returns its apps, with
    /// a display icon for each. Blocking - call off the main thread.
    public static func scan(
        instance: String, distro: GuestDistro, progress: ((String) -> Void)? = nil
    ) throws -> [LinuxApp] {
        progress?("Looking for applications…")
        let entries = try DesktopEntryScanner.scan(instance: instance, distro: distro)

        var apps = entries
            .map {
                LinuxApp(
                    desktopPath: $0.path, name: $0.name, command: $0.launchCommand,
                    comment: $0.comment ?? $0.genericName,
                    iconName: $0.icon, source: $0.source)
            }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.source.rawValue < $1.source.rawValue
            }

        // Entries are NOT de-duplicated by visible name. Once Flatpak and
        // Snap directories are scanned, one application legitimately shows
        // up two or three times with an identical `Name=`, and which copy
        // survives a name-based filter comes down to `find` order. For a
        // feature whose whole purpose is letting the user choose what to
        // put on their Dock, silently dropping two of three is wrong - they
        // are distinguished by `source` in the UI instead. The path is the
        // identity, and paths are unique.
        var seenPaths = Set<String>()
        apps = apps.filter { seenPaths.insert($0.desktopPath).inserted }

        progress?("Fetching icons…")
        let iconDirectory = MSLPaths.appCatalogDirectory(instance: instance)
            .appendingPathComponent("icons")
        try? FileManager.default.removeItem(at: iconDirectory)
        MSLPaths.ensureDirectory(iconDirectory)

        let resolved = (try? resolveIcons(
            for: apps, instance: instance, distro: distro, maxBytes: scanIconBytes)) ?? [:]
        for index in apps.indices {
            guard let name = apps[index].iconName,
                  let found = resolved[name],
                  let file = write(found.data, named: name, extension: found.fileExtension,
                                   into: iconDirectory) else { continue }
            apps[index].iconFile = file
            apps[index].iconIsHighResolution = found.isHighResolution
        }

        save(apps, instance: instance)
        progress?("Found \(apps.count) applications")
        return apps
    }

    /// Resolves `Icon=` values to bytes: one round trip to list matching
    /// files, host-side ranking, then one round trip for the winners.
    ///
    /// Split in two so the ranking happens here rather than in shell. It
    /// has to compare a vector against a `48x48` bitmap against a file in a
    /// flat directory with no size at all, which is awkward in `sh` and
    /// trivial - and testable without a guest - in Swift.
    private static func resolveIcons(
        for apps: [LinuxApp], instance: String, distro: GuestDistro, maxBytes: Int
    ) throws -> [String: (data: Data, fileExtension: String, isHighResolution: Bool)] {
        let names = Set(apps.compactMap { $0.iconName }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return [:] }

        // An absolute `Icon=` needs no searching. Snap writes them that way
        // (`/snap/<app>/current/meta/gui/icon.png`), and so do plenty of
        // hand-written entries.
        let absolute = names.filter { $0.hasPrefix("/") }
        let candidates = try DesktopEntryScanner.listIconCandidates(
            names: names, instance: instance, distro: distro)
        let best = DesktopEntryScanner.bestIcons(among: candidates)

        var pathsToFetch = absolute.map { (name: $0, path: $0) }
        pathsToFetch += best.map { (name: $0.key, path: $0.value.path) }

        let bytes = try DesktopEntryScanner.fetchFiles(
            paths: pathsToFetch.map { $0.path }, instance: instance,
            distro: distro, maxBytes: maxBytes)

        var result: [String: (data: Data, fileExtension: String, isHighResolution: Bool)] = [:]
        for pair in pathsToFetch {
            guard let data = bytes[pair.path] else { continue }
            let ext = (pair.path as NSString).pathExtension.lowercased()
            let isVector = ext == "svg"
            let highRes = isVector || (best[pair.name]?.declaredSize ?? 0) >= 256
            result[pair.name] = (data, ext.isEmpty ? "png" : ext, highRes)
        }
        return result
    }

    /// Fetches the best available art for one app. Does not boot anything -
    /// the caller must have the instance running.
    ///
    /// Used when the user actually adds an app to the Dock or Applications
    /// folder. A scan deliberately grabs something small for every app at
    /// once; this goes back for the file that belongs in a 1024pt `.icns`,
    /// which is worth a round trip for one app and would not be for sixty.
    /// Returns the updated app, or the original when nothing better exists.
    public static func upgradeIcon(
        for app: LinuxApp, instance: String, distro: GuestDistro
    ) -> LinuxApp {
        guard let name = app.iconName, !name.isEmpty, !app.iconIsHighResolution else { return app }
        guard let resolved = try? resolveIcons(
            for: [app], instance: instance, distro: distro, maxBytes: bundleIconBytes),
              let found = resolved[name] else { return app }

        let directory = MSLPaths.appCatalogDirectory(instance: instance)
            .appendingPathComponent("icons")
        MSLPaths.ensureDirectory(directory)
        guard let file = write(found.data, named: name, extension: found.fileExtension,
                               into: directory) else { return app }

        var updated = app
        updated.iconFile = file
        updated.iconIsHighResolution = found.isHighResolution

        // Keep the cache in step so the grid shows the better art too.
        var all = cached(instance: instance)
        if let index = all.firstIndex(where: { $0.desktopPath == app.desktopPath }) {
            all[index] = updated
            save(all, instance: instance)
        }
        return updated
    }

    private static func write(
        _ data: Data, named name: String, extension fileExtension: String, into directory: URL
    ) -> String? {
        let file = safeFileName(name) + "." + fileExtension
        guard (try? data.write(to: directory.appendingPathComponent(file))) != nil else { return nil }
        return file
    }
    // MARK: - Cache

    private static func catalogFile(instance: String) -> URL {
        MSLPaths.appCatalogDirectory(instance: instance).appendingPathComponent("apps.json")
    }

    public static func cached(instance: String) -> [LinuxApp] {
        guard let data = try? Data(contentsOf: catalogFile(instance: instance)),
              let apps = try? JSONDecoder().decode([LinuxApp].self, from: data) else { return [] }
        return apps
    }

    /// When the cached list was last refreshed, so the UI can say so rather
    /// than presenting stale data as current.
    public static func lastScanned(instance: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: catalogFile(instance: instance).path)[.modificationDate] as? Date
    }

    private static func save(_ apps: [LinuxApp], instance: String) {
        let directory = MSLPaths.appCatalogDirectory(instance: instance)
        MSLPaths.ensureDirectory(directory)
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: catalogFile(instance: instance), options: .atomic)
    }

    public static func clearCache(instance: String) {
        try? FileManager.default.removeItem(at: MSLPaths.appCatalogDirectory(instance: instance))
    }

    // MARK: - Icons

    /// The icon to draw for `app`: the one pulled out of the guest if there
    /// is one, otherwise a generated monogram tile. Never `nil` - a missing
    /// icon should look deliberate, not broken.
    public static func icon(for app: LinuxApp, instance: String) -> NSImage {
        if let file = app.iconFile {
            let url = MSLPaths.appCatalogDirectory(instance: instance)
                .appendingPathComponent("icons").appendingPathComponent(file)
            if let image = NSImage(contentsOf: url), image.isValid { return image }
        }
        return monogram(for: app.name)
    }

    /// Whether a real icon was found for `app`, as opposed to the generated
    /// fallback - the UI has no other way to tell them apart.
    public static func hasRealIcon(for app: LinuxApp, instance: String) -> Bool {
        guard let file = app.iconFile else { return false }
        let url = MSLPaths.appCatalogDirectory(instance: instance)
            .appendingPathComponent("icons").appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A rounded tile with the app's first letter, coloured deterministically
    /// from its name so the same app is always the same colour.
    public static func monogram(for name: String, size: CGFloat = 128) -> NSImage {
        let letter = String(name.first.map(String.init)?.uppercased() ?? "?")
        // NOT `hashValue`: Swift seeds its hasher randomly per process, so
        // the same app came out a different colour on every launch - which
        // is the exact opposite of the point of colouring it by name.
        let hue = CGFloat(stableHash(name.lowercased()) % 360) / 360.0
        let background = NSColor(hue: hue, saturation: 0.42, brightness: 0.78, alpha: 1.0)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                                xRadius: size * 0.22, yRadius: size * 0.22)
        background.setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let text = NSAttributedString(string: letter, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
        image.unlockFocus()
        return image
    }

    // MARK: - Helpers

    /// FNV-1a over the UTF-8 bytes: tiny, stable across processes and
    /// across runs, which is all this needs.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func safeFileName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}
