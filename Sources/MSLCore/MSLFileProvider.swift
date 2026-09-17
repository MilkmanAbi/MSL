import Foundation
import UniformTypeIdentifiers

/// One entry in a browsable directory, on either side of the boundary.
public struct MSLFileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Absolute path in whatever namespace the provider serves.
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modified: Date?
    public let created: Date?
    /// Localized type description - "ZIP archive", "Folder", "AV1 Image
    /// File Format". Resolved by the provider during `list`, in the same
    /// `resourceValues` call that fetches everything else, because deriving
    /// it in the UI would mean a `UTType` lookup per row per redraw.
    public let kind: String?
    /// An app, or another directory macOS presents as a single file. The UI
    /// needs this to decide whether double-click descends or launches, and
    /// whether an icon is worth a per-path lookup.
    public let isBundle: Bool
    /// Finder tags, with colours. Empty for the overwhelming majority of
    /// files, which is what makes fetching them affordable.
    public let tags: [FileTag]
    /// Whether the name begins with a dot. Kept as data so the UI can
    /// filter without re-deriving it per row.
    public var isHidden: Bool { name.hasPrefix(".") }
    /// Directories the user can descend into - a bundle is a directory that
    /// should not be browsed by default.
    public var isBrowsableDirectory: Bool { isDirectory && !isBundle }

    public init(path: String, name: String, isDirectory: Bool, size: UInt64,
                modified: Date?, created: Date? = nil, kind: String? = nil,
                isBundle: Bool = false, tags: [FileTag] = []) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.kind = kind
        self.isBundle = isBundle
        self.tags = tags
    }
}

/// A browsable filesystem.
///
/// The abstraction exists because the Linux side may end up reached two
/// different ways and the UI must not care which. Today the guest is
/// mounted on the host by `NetFSMountURLSync` (see
/// `VMManager.startFileSandbox`), so it is reachable through ordinary
/// `FileManager` calls like any other volume. But that mount is WebDAV, and
/// macOS's WebDAV client forces a share `rdonly` when the server advertises
/// no LOCK support - so writes may have to go back through `FileOpsClient`
/// in the daemon instead. `isWritable` is what the UI asks; swapping in a
/// daemon-backed provider later changes nothing above this line.
public protocol MSLFileProvider: Sendable {
    /// Human-readable name for the root, e.g. "Alpine — default".
    var displayName: String { get }
    /// Where browsing starts.
    var rootPath: String { get }
    /// Whether this provider can be written to at all.
    var isWritable: Bool { get }

    func list(_ path: String) async throws -> [MSLFileItem]
    func createDirectory(at path: String) async throws
    func remove(_ path: String) async throws
    func rename(_ path: String, to newName: String) async throws
    /// Copies a host file into `directory` on this provider.
    func importFile(from source: URL, into directory: String) async throws
    /// Copies a file from this provider out to a host location.
    func exportFile(_ path: String, to destination: URL) async throws
}

/// Whether a failed write means "this whole volume refuses writes" rather
/// than "this particular operation failed".
///
/// The distinction matters because the up-front guess is unreliable.
/// `isWritableFile(atPath:)` answers from POSIX permission bits, and a
/// WebDAV share that macOS has forced `rdonly` - which it does whenever
/// the server advertises no LOCK support - can still carry permissive
/// bits. Such a mount looks writable until the first write returns
/// `EROFS`, so a caller that wants to disable its write affordances has to
/// learn from the refusal instead of predicting it.
public func isReadOnlyVolumeError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteVolumeReadOnlyError {
        return true
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EROFS) { return true }
    // Cocoa wraps the errno it got from the syscall; the wrapper is
    // sometimes a generic write error with the real cause underneath.
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isReadOnlyVolumeError(underlying)
    }
    return false
}

public enum MSLFileError: LocalizedError {
    case notWritable(String)
    case alreadyExists(String)
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .notWritable(let name): return "\(name) is read-only."
        case .alreadyExists(let name): return "“\(name)” already exists here."
        case .invalidName(let name): return "“\(name)” isn't a usable name."
        }
    }
}

/// A provider over a path on the host's own filesystem.
///
/// Backs both sides today: the Mac home directory, and the guest, whose
/// filesystem is a mounted volume as far as `FileManager` is concerned.
public struct LocalFileProvider: MSLFileProvider {
    public let displayName: String
    public let rootPath: String
    private let forcedReadOnly: Bool

    public init(displayName: String, rootPath: String, readOnly: Bool = false) {
        self.displayName = displayName
        self.rootPath = rootPath
        self.forcedReadOnly = readOnly
    }

    public var isWritable: Bool {
        guard !forcedReadOnly else { return false }
        return FileManager.default.isWritableFile(atPath: rootPath)
    }

    public func list(_ path: String) async throws -> [MSLFileItem] {
        let url = URL(fileURLWithPath: path)
        // Everything the UI can display is fetched in this one call.
        // `contentsOfDirectory` prefetches these for the whole directory, so
        // asking for more here is far cheaper than deriving any of it
        // per-row later - which matters most on the guest, where each miss
        // would be a round trip over a network mount.
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey,
            .creationDateKey, .contentTypeKey, .isPackageKey, .isApplicationKey,
            .tagNamesKey, .labelNumberKey, .localizedLabelKey,
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])

        return contents.map { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isBundle = (values?.isPackage ?? false) || (values?.isApplication ?? false)
            return MSLFileItem(
                path: child.path,
                name: values?.name ?? child.lastPathComponent,
                isDirectory: isDirectory,
                size: UInt64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                created: values?.creationDate,
                // A folder has a content type too ("public.folder"), but
                // "Folder" reads better than the UTI's own description.
                kind: Self.kindName(values?.contentType, isDirectory: isDirectory),
                isBundle: isBundle,
                // `tagNames` comes free with the batched directory fetch and
                // says *whether* a file is tagged; the colours need a
                // per-file attribute read, so that only happens for the few
                // files that actually have tags.
                tags: FileTagStore.tags(at: child.path,
                                        names: values?.tagNames ?? [],
                                        labelNumber: values?.labelNumber,
                                        labelName: values?.localizedLabel))
        }
        .sorted {
            // Folders first, then natural-order by name. Note this is *not*
            // what Finder does by default: Finder sorts folders in with
            // files unless "Keep folders on top" is switched on. This is the
            // provider's own stable default for any consumer that doesn't
            // sort; the browser re-sorts to whatever the user picked, and
            // offers folders-on-top as the toggle Finder does.
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// A displayable type name. `UTType.localizedDescription` returns
    /// lower-case prose ("folder", "plain text document"); Finder shows it
    /// capitalized, and next to capitalized file names anything else looks
    /// like a bug.
    public static func kindName(_ type: UTType?, isDirectory: Bool) -> String? {
        guard let description = type?.localizedDescription else {
            return isDirectory ? "Folder" : nil
        }
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    public func createDirectory(at path: String) async throws {
        guard isWritable else { throw MSLFileError.notWritable(displayName) }
        guard !FileManager.default.fileExists(atPath: path) else {
            throw MSLFileError.alreadyExists((path as NSString).lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path), withIntermediateDirectories: false)
    }

    public func remove(_ path: String) async throws {
        guard isWritable else { throw MSLFileError.notWritable(displayName) }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }

    /// Moves to the Trash, reporting whether that was possible.
    ///
    /// Finder's Delete is recoverable and this browser's was not, which is a
    /// bad surprise to hand someone who is working from Finder muscle
    /// memory. `trashItem` only works on volumes with a Trash, though - a
    /// network mount generally has none, and the guest's certainly does not,
    /// so `false` here means "there is no Trash on this volume" and the
    /// caller must decide whether to delete outright. It is deliberately not
    /// an error: not having a Trash is a property of the volume, not a
    /// failure of the operation.
    public func trash(_ path: String) async throws -> Bool {
        guard isWritable else { throw MSLFileError.notWritable(displayName) }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                              resultingItemURL: nil)
            return true
        } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain
                    && (error.code == NSFeatureUnsupportedError
                        || error.code == NSFileWriteVolumeReadOnlyError) {
            return false
        } catch let error as NSError
                    where error.domain == NSPOSIXErrorDomain
                    && (error.code == Int(ENOTSUP) || error.code == Int(EPERM)
                        || error.code == Int(EXDEV)) {
            return false
        }
    }

    public func rename(_ path: String, to newName: String) async throws {
        guard isWritable else { throw MSLFileError.notWritable(displayName) }
        // A name containing a separator would move the file somewhere else
        // entirely, which is not what a rename field is for.
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw MSLFileError.invalidName(newName)
        }
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MSLFileError.alreadyExists(newName)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func importFile(from source: URL, into directory: String) async throws {
        guard isWritable else { throw MSLFileError.notWritable(displayName) }
        let destination = URL(fileURLWithPath: directory)
            .appendingPathComponent(source.lastPathComponent)
        try copy(source, to: destination)
    }

    public func exportFile(_ path: String, to destination: URL) async throws {
        try copy(URL(fileURLWithPath: path), to: destination)
    }

    /// Copies, refusing to clobber. Finder would offer to replace or keep
    /// both; refusing is the safe half of that, and an accidental
    /// drag-and-drop overwriting a file across the Mac/Linux boundary is
    /// exactly the kind of loss this should not make easy.
    private func copy(_ source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MSLFileError.alreadyExists(destination.lastPathComponent)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
