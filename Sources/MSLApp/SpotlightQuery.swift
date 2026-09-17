import Foundation
import MSLCore

/// Runs the Spotlight searches behind the Tags and Recents sidebar items.
///
/// Those two are not directories - Finder's Tags entries and Recents are
/// saved searches over the whole home folder - so they cannot come from
/// `MSLFileProvider`, which lists a path. This wraps `NSMetadataQuery`
/// instead and hands back the same `MSLFileItem` the rest of the browser
/// speaks, so only the loading differs.
///
/// The predicates were checked with `mdfind` before being written here
/// rather than recalled: `kMDItemUserTags == 'Red'` and
/// `kMDItemLastUsedDate >= $time.now(-604800)` both return rows.
@MainActor
final class SpotlightQuery {
    /// `NSMetadataQuery` is notification-driven and does nothing useful if
    /// it is deallocated, so the live query is held here for its lifetime -
    /// a query that goes out of scope simply never fires, silently.
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    deinit {
        // Not @MainActor-isolated, so tear down what can be torn down
        // without hopping: the observers own the only strong reference back.
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    enum Scope {
        case tag(String)
        case recents

        var predicate: NSPredicate {
            switch self {
            case .tag(let name):
                // Two attributes, because a file can carry a colour either
                // way. `kMDItemUserTags` holds modern tags; a file labelled
                // the old way has no user tag at all and is found only by
                // `kMDItemFSLabel`, which Spotlight numbers identically to
                // the tag colour index (checked with `mdls`: a red legacy
                // label reports 6, the same as the red tag). Finder lists
                // both under the colour, so this does too.
                let index = FileTag.standardColorIndex(for: name)
                guard index > 0 else {
                    return NSPredicate(format: "kMDItemUserTags == %@", name)
                }
                return NSPredicate(format: "kMDItemUserTags == %@ || kMDItemFSLabel == %d",
                                   name, index)
            case .recents:
                // A week, which is roughly what Finder's Recents shows.
                return NSPredicate(format: "kMDItemLastUsedDate >= %@",
                                   Date().addingTimeInterval(-7 * 24 * 60 * 60) as NSDate)
            }
        }
    }

    /// Runs `scope` and calls `completion` once, when gathering finishes.
    ///
    /// Deliberately one-shot: live updates would mean rows appearing under
    /// the user mid-scroll, which Finder does not do for these either.
    func run(_ scope: Scope, limit: Int = 500,
             completion: @escaping ([MSLFileItem]) -> Void) {
        cancel()

        let query = NSMetadataQuery()
        query.predicate = scope.predicate
        // Unscoped, this walks every indexed volume - including, once an
        // instance is running, the guest mount.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey,
                                                  ascending: false)]

        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query, queue: .main
        ) { [weak self] _ in
            query.disableUpdates()
            let items = (0..<query.resultCount)
                .prefix(limit)
                .compactMap { query.result(at: $0) as? NSMetadataItem }
                .compactMap { Self.item(from: $0) }
            completion(items)
            self?.cancel()
        }
        observers.append(observer)
        self.query = query
        query.start()
    }

    func cancel() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Turns a Spotlight hit into the browser's own item type.
    ///
    /// Everything is read from the filesystem rather than from the metadata
    /// item: Spotlight's copies can lag, and a listing that disagrees with
    /// the file it points at is worse than a slightly slower one.
    private static func item(from metadata: NSMetadataItem) -> MSLFileItem? {
        guard let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String
        else { return nil }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey,
            .creationDateKey, .contentTypeKey, .isPackageKey, .isApplicationKey,
            .tagNamesKey, .labelNumberKey, .localizedLabelKey,
        ]
        // A hit whose file is gone - deleted since indexing - is skipped
        // rather than shown as a broken row.
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = values.isDirectory ?? false
        return MSLFileItem(
            path: path,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            size: UInt64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            created: values.creationDate,
            kind: LocalFileProvider.kindName(values.contentType, isDirectory: isDirectory),
            isBundle: (values.isPackage ?? false) || (values.isApplication ?? false),
            tags: FileTagStore.tags(at: path, names: values.tagNames ?? [],
                                    labelNumber: values.labelNumber,
                                    labelName: values.localizedLabel))
    }
}
