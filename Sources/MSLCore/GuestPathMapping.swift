import Foundation

/// Where a path on the Mac is visible from *inside* a guest - if anywhere.
///
/// Two different bridges cross the boundary, in opposite directions, and a
/// host path can sit on either one:
///
/// - **The guest's own filesystem**, which the daemon mounts on the host so
///   Finder can see it (`VMManager.sandboxMountPath`, WebDAV). A path under
///   that mount is already Linux-side; the guest reaches it at the same
///   place relative to its own `/`.
/// - **`mac_home`**, the host home directory shared into every guest over
///   virtiofs (`mslhd/main.swift` attaches it; `bootstrap-distro` writes the
///   fstab line). The guest sees it at `/mnt/mac`.
///
/// Everything else - `/Applications`, `/usr/local`, another volume, a
/// development tree outside the home directory - is genuinely invisible to
/// the guest. Saying so is the point of this type: the alternative is
/// opening a shell at a path that does not exist there, which looks like a
/// broken feature rather than an unsupported one.
public enum GuestPathMapping: Equatable, Sendable {
    /// Inside one specific instance's own filesystem. Only that instance
    /// can reach it, hence the name.
    case guestFilesystem(instance: String, guestPath: String)
    /// Under the Mac home share, reachable from *any* running instance at
    /// the same path - so the caller has to decide which one to use.
    case macHomeShare(guestPath: String)
    /// Not reachable from any guest.
    case unreachable
}

/// One running instance's host mount, as `GuestPathMapper` needs it.
public struct GuestMount: Equatable, Sendable {
    public let instance: String
    /// `VMManager.sandboxMountPath` - where the guest's `/` appears on the
    /// host.
    public let mountPath: String

    public init(instance: String, mountPath: String) {
        self.instance = instance
        self.mountPath = mountPath
    }
}

public enum GuestPathMapper {
    /// Where `mac_home` is mounted in every guest. Fixed, not discovered:
    /// `bootstrap-distro` and `provision-disk-image` both write
    /// `mac_home /mnt/mac virtiofs defaults 0 0` into the guest's fstab.
    public static let macHomeMountPoint = "/mnt/mac"

    /// Resolves a host path to its guest equivalent.
    ///
    /// Deliberately takes the host path rather than a `FileRoot`, and is
    /// deliberately pure. Deciding from the *root the user is browsing*
    /// would be wrong: the Tags and Recents roots are Spotlight queries
    /// over the home directory, so their rows are host-home paths no matter
    /// which root the user came from. Only the path itself knows where it
    /// lives.
    ///
    /// The guest's own filesystem is checked first. A guest mount lives
    /// under `/Volumes`, not under the home directory, so the two cannot
    /// normally both match - but if a mount ever did land inside the home
    /// directory, reaching it as itself is right and reaching it through
    /// the Mac share would be a coincidence.
    public static func map(hostPath: String,
                           guestMounts: [GuestMount],
                           homeDirectory: String = NSHomeDirectory()) -> GuestPathMapping {
        let path = normalize(hostPath)

        for mount in guestMounts {
            if let relative = relativePath(of: path, under: normalize(mount.mountPath)) {
                return .guestFilesystem(instance: mount.instance,
                                        guestPath: join("", relative))
            }
        }
        if let relative = relativePath(of: path, under: normalize(homeDirectory)) {
            return .macHomeShare(guestPath: join(macHomeMountPoint, relative))
        }
        return .unreachable
    }

    /// The path a component-wise `base` prefix leaves behind, or nil when
    /// `path` is not inside `base`.
    ///
    /// Component-wise is the whole job here. A plain `hasPrefix` says
    /// `/Users/abinaash-other/notes` is inside `/Users/abinaash`, which
    /// would hand the guest a path pointing at a different user's files.
    private static func relativePath(of path: String, under base: String) -> String? {
        guard !base.isEmpty else { return nil }
        if path == base { return "" }
        // "/" is its own terminator, so appending another would ask for
        // "//" and never match.
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func join(_ base: String, _ relative: String) -> String {
        relative.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + relative
    }

    /// Trailing separators removed, `..` and `~` resolved. Applied to both
    /// sides of every comparison so they cannot disagree over a formatting
    /// difference alone.
    private static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// The command handed to `msl <instance> …` to land an interactive
    /// shell in `guestPath`.
    ///
    /// `shellinit` runs this through `sh -c` on a pty (see
    /// `Guest/init/shellinit.c`), so it is a shell command line, and the
    /// path has to be quoted for that shell - not merely escaped for the
    /// AppleScript and Terminal layers it passes through on the way.
    ///
    /// `-i`, never `-l`. A login shell re-runs the profile, and a profile
    /// that ends with a `cd` - which is ordinary enough - would silently
    /// undo the one thing this command exists to do. `bash` is tried first
    /// and `sh` is the fallback because Alpine, the default distro, ships
    /// no bash unless someone installed it.
    public static func interactiveShellCommand(in guestPath: String) -> String {
        let quoted = DesktopEntry.shellQuote(guestPath)
        return "cd \(quoted) && { exec /bin/bash -i 2>/dev/null; exec /bin/sh -i; }"
    }
}
