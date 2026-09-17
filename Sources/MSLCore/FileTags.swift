import Foundation

/// A macOS Finder tag: a name, and the colour swatch Finder draws for it.
///
/// These are the real thing, not a private store - the same
/// `com.apple.metadata:_kMDItemUserTags` extended attribute Finder reads and
/// writes, so a tag applied here appears in Finder and vice versa.
public struct FileTag: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Finder's colour index. Verified by observation rather than assumed:
    /// tag a file, then read the raw attribute back.
    ///
    ///     0 none (a custom tag with no colour assigned)
    ///     1 grey     2 green    3 purple   4 blue
    ///     5 yellow   6 red      7 orange
    ///
    /// Note this is *not* the same numbering as AppleScript's legacy
    /// `label index`, which writes `com.apple.FinderInfo` instead and orders
    /// the colours differently. Anything reading modern tags wants this one.
    public let colorIndex: Int

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }

    /// The seven tags every Mac ships with, in Finder's own sidebar order.
    public static let standardNames = ["Red", "Orange", "Yellow", "Green",
                                       "Blue", "Purple", "Gray"]

    public static func standardColorIndex(for name: String) -> Int {
        switch name {
        case "Red": return 6
        case "Orange": return 7
        case "Yellow": return 5
        case "Green": return 2
        case "Blue": return 4
        case "Purple": return 3
        case "Gray": return 1
        default: return 0
        }
    }
}

/// Reads and writes Finder tags.
public enum FileTagStore {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// The tags on a file, with colours.
    ///
    /// Colours require reading the raw extended attribute, because
    /// `URLResourceValues.tagNames` returns names only - the colour lives
    /// after a newline inside each stored entry ("Red\n6"). That read is a
    /// per-file syscall, which is why callers should ask only for files a
    /// batched `tagNames` fetch already said are tagged: most files have no
    /// tags at all, and on the guest every avoided syscall is an avoided
    /// network round trip.
    public static func tags(at path: String) -> [FileTag] {
        guard let data = rawAttribute(at: path),
              let entries = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String]
        else { return [] }

        return entries.map { entry in
            // "Red\n6" - name, newline, colour index. A tag with no colour
            // is stored as the bare name, so a missing index means 0.
            let parts = entry.components(separatedBy: "\n")
            let name = parts.first ?? entry
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return FileTag(name: name, colorIndex: index)
        }
    }

    /// Replaces the tags on a file.
    ///
    /// The attribute is composed by hand rather than written through
    /// `URLResourceValues.tagNames`, whose *setter* is macOS 26 and later
    /// only - this app targets 14. The getter is available on 14, which is
    /// why reading can use the resource key and writing cannot.
    ///
    /// Safe to hand-roll because the format was read back off files Finder
    /// itself had tagged: a binary plist array of strings, each entry the
    /// tag name, a newline, and the colour index. macOS does not normalise
    /// this on write, so the colour has to be supplied here - a bare "Red"
    /// with no index would store a *custom* tag that happens to be called
    /// Red and draws no swatch.
    public static func setTags(_ names: [String], at path: String) throws {
        guard !names.isEmpty else {
            if removexattr(path, attribute, 0) != 0, errno != ENOATTR {
                throw tagError(path)
            }
            return
        }
        let entries = names.map { "\($0)\n\(FileTag.standardColorIndex(for: $0))" }
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries, format: .binary, options: 0)
        let written = data.withUnsafeBytes {
            setxattr(path, attribute, $0.baseAddress, data.count, 0, 0)
        }
        if written != 0 { throw tagError(path) }
    }

    private static func tagError(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey:
                "Couldn't change tags on “\((path as NSString).lastPathComponent)”.",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                          code: Int(errno), userInfo: nil),
        ])
    }

    /// Tags for a file whose `tagNames` were already fetched in a batched
    /// directory listing, resolving each name to its colour.
    ///
    /// Three sources, in order, because no single one covers every file:
    ///
    /// 1. The modern attribute, which carries explicit colour indices.
    /// 2. The **legacy Finder label**, for files tagged before macOS 10.9
    ///    or by an app still using the old API. Foundation surfaces these
    ///    through `tagNames` too, but stores them in `com.apple.FinderInfo`
    ///    with no modern attribute to read - so a file showing a colour in
    ///    Finder would show none here. `labelNumber` happens to use exactly
    ///    the same numbering as the tag colour index (7 orange, 6 red, 5
    ///    yellow, 4 blue, 3 purple, 2 green, 1 grey), confirmed by reading
    ///    both off the same files.
    /// 3. The name, for a standard tag whose attribute is somehow absent.
    public static func tags(at path: String, names: [String],
                            labelNumber: Int?, labelName: String?) -> [FileTag] {
        guard !names.isEmpty else { return [] }
        let stored = Dictionary(
            tags(at: path).map { ($0.name, $0.colorIndex) },
            uniquingKeysWith: { first, _ in first })

        return names.map { name in
            if let index = stored[name] { return FileTag(name: name, colorIndex: index) }
            if let labelName, labelName == name, let labelNumber, labelNumber > 0 {
                return FileTag(name: name, colorIndex: labelNumber)
            }
            return FileTag(name: name, colorIndex: FileTag.standardColorIndex(for: name))
        }
    }

    public static func toggle(_ name: String, at path: String) throws {
        let current = tags(at: path).map(\.name)
        let updated = current.contains(name)
            ? current.filter { $0 != name }
            : current + [name]
        try setTags(updated, at: path)
    }

    private static func rawAttribute(at path: String) -> Data? {
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attribute, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }
}
