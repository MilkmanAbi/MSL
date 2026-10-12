import Foundation

/// Reads a Linux `st_mode` the way `ls -l` does - the file type and the nine
/// permission bits the WebDAV mount can't show, because it reports the
/// mounter's own identity and a made-up `rwx------` for every guest file.
///
/// Pure integer work over the `mode` `fileopsd` already sends (see
/// `FileOpsProtocol.Entry.mode`), so it lives in `MSLCore` and is tested
/// directly rather than through the UI.
public enum LinuxFileMode {
    // The `S_IF*` format constants. Spelled out rather than taken from
    // `Darwin`, because these are *Linux* file types read off a Linux inode:
    // they happen to match the BSD values today, but this code's contract is
    // with the guest's `<linux/stat.h>`, not the host's headers.
    public static let formatMask: UInt32 = 0o170000
    public static let fifo: UInt32       = 0o010000
    public static let charDevice: UInt32 = 0o020000
    public static let directory: UInt32  = 0o040000
    public static let blockDevice: UInt32 = 0o060000
    public static let regular: UInt32    = 0o100000
    public static let symlink: UInt32    = 0o120000
    public static let socket: UInt32     = 0o140000

    /// One entry's kind, from the format bits.
    public enum Kind: Equatable, Sendable {
        case regular, directory, symlink, fifo, socket, blockDevice, charDevice, unknown

        /// The leading character `ls -l` prints.
        public var lsChar: Character {
            switch self {
            case .regular: return "-"
            case .directory: return "d"
            case .symlink: return "l"
            case .fifo: return "p"
            case .socket: return "s"
            case .blockDevice: return "b"
            case .charDevice: return "c"
            case .unknown: return "?"
            }
        }

        /// A word for Get Info, or nil for an ordinary file/folder (which the
        /// existing "Kind" already names).
        public var label: String? {
            switch self {
            case .symlink: return "Symbolic link"
            case .fifo: return "Named pipe (FIFO)"
            case .socket: return "Socket"
            case .blockDevice: return "Block device"
            case .charDevice: return "Character device"
            case .regular, .directory, .unknown: return nil
            }
        }

        /// An SF Symbol that reads as this type at a glance, or nil to leave
        /// the normal file/folder icon alone.
        public var badgeSymbol: String? {
            switch self {
            case .symlink: return "arrow.up.forward"
            case .fifo: return "pipe.and.drop"
            case .socket: return "powerplug"
            case .blockDevice, .charDevice: return "cpu"
            case .regular, .directory, .unknown: return nil
            }
        }
    }

    public static func kind(_ mode: UInt32) -> Kind {
        switch mode & formatMask {
        case regular: return .regular
        case directory: return .directory
        case symlink: return .symlink
        case fifo: return .fifo
        case socket: return .socket
        case blockDevice: return .blockDevice
        case charDevice: return .charDevice
        default: return .unknown
        }
    }

    public static func isRegularFile(_ mode: UInt32) -> Bool { mode & formatMask == regular }
    public static func isSymlink(_ mode: UInt32) -> Bool { mode & formatMask == symlink }

    /// Any execute bit set (owner, group or other). What decides whether a
    /// file has the "runnable" badge and whether "Make Executable" is a no-op.
    public static func isExecutable(_ mode: UInt32) -> Bool { mode & 0o111 != 0 }

    /// The `rwxr-xr-x` string, type char included - exactly `ls -l`'s first
    /// field, setuid/setgid/sticky and all.
    public static func lsString(_ mode: UInt32) -> String {
        var s = String(kind(mode).lsChar)
        let bits = mode & 0o7777
        let rwx: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                          (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                          (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (bit, char) in rwx { s.append(mode & bit != 0 ? char : "-") }
        // setuid/setgid/sticky replace the matching execute slot, as `ls`
        // does: an uppercase letter when the execute bit is clear.
        func special(_ index: Int, set bit: UInt32, exec: UInt32, on: Character, off: Character) {
            guard bits & bit != 0 else { return }
            let i = s.index(s.startIndex, offsetBy: index)
            s.replaceSubrange(i...i, with: String(mode & exec != 0 ? on : off))
        }
        special(3, set: 0o4000, exec: 0o100, on: "s", off: "S") // setuid
        special(6, set: 0o2000, exec: 0o010, on: "s", off: "S") // setgid
        special(9, set: 0o1000, exec: 0o001, on: "t", off: "T") // sticky
        return s
    }

    /// The octal a person expects, e.g. "755" or "0644".
    public static func octalString(_ mode: UInt32) -> String {
        String(format: "%03o", mode & 0o777)
    }
}
