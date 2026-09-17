import AppKit
import MSLCore
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails for icon and gallery view.
///
/// A generic document glyph where Finder shows the actual picture is the
/// single biggest "this isn't Finder" tell, so image and PDF content is
/// drawn for real. Unlike `FileIconCache` this genuinely reads the file, so
/// it is deliberately conservative:
///
/// - **Asynchronous, always.** The icon draws immediately and the thumbnail
///   replaces it when it arrives. Nothing ever waits.
/// - **Size-capped.** Above `maximumBytes` the icon stands. A thumbnail is
///   a nicety and reading 200 MB to draw one is not worth it - especially
///   on the guest, where the file crosses a WebDAV mount.
/// - **Cached by identity, not just path**, so editing a file updates its
///   thumbnail instead of showing a stale one forever.
///
/// `QLThumbnailGenerator` does its own work off the main thread and
/// coalesces duplicate requests, so no queue of our own is needed.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    /// Bumped whenever a thumbnail lands, so views re-read the cache. One
    /// counter rather than per-path state keeps this a single publish.
    @Published private(set) var generation = 0

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let maximumBytes: UInt64 = 64 * 1024 * 1024
    private let limit = 400

    private init() {}

    /// The thumbnail for `item` if one is ready; otherwise nil, and one is
    /// requested. Callers draw the file icon meanwhile.
    func thumbnail(for item: MSLFileItem, size: CGFloat) -> NSImage? {
        guard !item.isDirectory || item.isBundle else { return nil }
        guard item.size <= maximumBytes else { return nil }
        let key = key(item, size: size)
        if let hit = cache[key] { return hit }
        request(item, size: size, key: key)
        return nil
    }

    /// Path plus the things that change a file's appearance. Without the
    /// modification date a re-saved image would keep its old thumbnail for
    /// the life of the process.
    private func key(_ item: MSLFileItem, size: CGFloat) -> String {
        let stamp = item.modified?.timeIntervalSince1970 ?? 0
        return "\(item.path)|\(item.size)|\(stamp)|\(Int(size))"
    }

    private func request(_ item: MSLFileItem, size: CGFloat, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path),
            size: CGSize(width: size, height: size),
            scale: scale,
            // `.thumbnail` alone returns nothing for types Quick Look has no
            // generator for; the composite representations fall back to the
            // icon, which we already draw ourselves. Asking for the low
            // quality variant too means a fast approximate result arrives
            // first for large images.
            representationTypes: [.thumbnail, .lowQualityThumbnail])

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else {
                Task { @MainActor in self?.inFlight.remove(key) }
                return
            }
            let image = rep.nsImage
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(key)
                if self.cache.count >= self.limit { self.cache.removeAll(keepingCapacity: true) }
                self.cache[key] = image
                self.generation &+= 1
            }
        }
    }
}

/// A file's thumbnail if Quick Look can make one, its real icon until then.
struct FileThumbnail: View {
    let item: MSLFileItem
    var size: CGFloat = 64
    @ObservedObject private var thumbnails = ThumbnailCache.shared

    var body: some View {
        // Reading `generation` is what subscribes this view to thumbnail
        // arrivals; without it the cache would fill and nothing would redraw.
        let _ = thumbnails.generation
        if let thumbnail = thumbnails.thumbnail(for: item, size: size) {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: size, maxHeight: size)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        } else {
            FileIcon(item: item, size: size)
        }
    }
}
