import AppKit
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

/// Real macOS file icons for the browser, cached hard.
///
/// `NSWorkspace.icon(forFile:)` is the whole reason the window stops looking
/// like a debug tool - it returns the genuine document, archive and
/// application icons Finder draws, including an app's own artwork. But it
/// answers per *path*: it stats the file, and for a bundle it reads
/// `Info.plist` and the icon resource inside. Called per row while
/// scrolling, on the guest - which is a WebDAV mount, so every stat is a
/// network round trip - that would stall the list.
///
/// So the lookup is keyed by what actually determines the icon:
///
/// - **Plain files** share one icon per file type, so the cache key is the
///   extension. A thousand `.txt` files cost one lookup, and `icon(for:)`
///   on a `UTType` never touches the filesystem at all.
/// - **Bundles and plain directories** genuinely differ per path (an app
///   has its own artwork; a folder may be customised), so those are keyed
///   by path - but a plain folder with no custom icon is by far the common
///   case, so it shares the generic folder icon unless the file system says
///   otherwise.
///
/// The measurement caveat is real: there is no bootable guest to profile
/// this against, so the cache is built in rather than added once it proved
/// slow. On the Mac side it is pure win either way.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private var byExtension: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    /// Bounded so a long browsing session cannot grow without limit; app
    /// icons are the only expensive entries and there are never many.
    private let pathLimit = 512

    private init() {}

    func icon(for item: MSLFileItem) -> NSImage {
        if item.isBundle || item.isDirectory {
            return pathIcon(item)
        }
        let key = (item.name as NSString).pathExtension.lowercased()
        if key.isEmpty {
            // No extension: the type cannot be inferred from the name, so
            // fall back to the generic document rather than paying a
            // per-path lookup for what is usually a README or a dotfile.
            return cached(&byExtension, "") { NSWorkspace.shared.icon(for: .data) }
        }
        return cached(&byExtension, key) {
            // Resolving the type from the extension alone keeps this off
            // the filesystem entirely.
            if let type = UTType(filenameExtension: key) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
    }

    /// Directories and bundles get a genuine per-path lookup.
    ///
    /// Tempting to shortcut plain folders to the generic folder icon, but
    /// that is visibly wrong in exactly the place people look first:
    /// `/Applications` has custom folder icons for Utilities, Developer and
    /// Games, and a browser that draws them all plain blue does not look
    /// like Finder. `URLResourceValues.customIcon` is no help in deciding -
    /// it is typed `NSImage?` and documented as always nil - so there is no
    /// cheap way to ask "is this folder ordinary". The cost is one lookup
    /// per folder for the life of the process, not one per redraw, which is
    /// affordable even across a WebDAV mount.
    private func pathIcon(_ item: MSLFileItem) -> NSImage {
        if let hit = byPath[item.path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        if byPath.count >= pathLimit { byPath.removeAll(keepingCapacity: true) }
        byPath[item.path] = icon
        return icon
    }

    private func cached(_ store: inout [String: NSImage], _ key: String,
                        _ make: () -> NSImage) -> NSImage {
        if let hit = store[key] { return hit }
        let icon = make()
        store[key] = icon
        return icon
    }
}

/// A file's real macOS icon, at a given point size.
struct FileIcon: View {
    let item: MSLFileItem
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIconCache.shared.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
