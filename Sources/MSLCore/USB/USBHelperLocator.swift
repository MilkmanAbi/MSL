import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Finds a copy of `msl-usbd` that is safe to run as root.
///
/// This matters more than it looks. `msl usb attach` runs the helper under
/// `sudo`, so whoever can write that file gets root on the Mac - and the
/// obvious copy, the one in `~/Library/Application Support/MSL/bin`, is
/// **writable by a Linux guest**: MSL mounts the Mac's home at `/mnt/mac`
/// read-write, so a guest process can replace the binary and wait for
/// somebody to attach a claimed device. Measured from inside a guest:
///
/// ```
/// whoami: abinaash (1001)
/// RESULT: the guest CAN write the bin directory
/// RESULT: msl-usbd itself is WRITABLE from the guest
/// ```
///
/// The copy inside the installed `MSL.app` is `root:admin`, as are all of
/// its parents, so that is the one to run - and it is verified rather than
/// assumed, because an app bundle that was never installed through the pkg
/// (a `dist/` build, say) is owned by the user like anything else.
public enum USBHelperLocator {
    public enum Refusal: Error, CustomStringConvertible {
        case notInstalled
        case unsafeOwner(path: String)

        public var description: String {
            switch self {
            case .notInstalled:
                return """
                msl: can't find an installed MSL.app to run the USB helper from.
                  The copy in Application Support is writable by your Linux guests, so MSL
                  will not run it as root. Install MSL.app in /Applications and try again.
                """
            case .unsafeOwner(let path):
                return """
                msl: refusing to run the USB helper as root - \(path) is not owned by root,
                  or is writable by more than root. Reinstall MSL from its installer package.
                """
            }
        }
    }

    /// The helper inside the installed application bundle, if it passes the
    /// ownership check.
    public static func trustedHelper() -> Result<String, Refusal> {
        guard let bundle = installedAppBundle() else { return .failure(.notInstalled) }
        let helper = bundle.appendingPathComponent("Contents/MacOS/msl-usbd").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            return .failure(.notInstalled)
        }
        // Every component, not only the file: a user-writable directory
        // anywhere above it is enough to swap the whole bundle out.
        if let bad = firstUnsafeComponent(of: helper) {
            return .failure(.unsafeOwner(path: bad))
        }
        return .success(helper)
    }

    /// Groups macOS itself writes with. `/Applications` ships as
    /// `drwxrwxr-x root:admin` on every Mac, so refusing group-writable
    /// outright would refuse the only trustworthy copy there is.
    private static let systemGroups: Set<gid_t> = [0 /* wheel */, 80 /* admin */]

    /// Walks a path from the root down and returns the first component that
    /// is not owned by root, is world-writable, or is group-writable by a
    /// group that is not macOS's own.
    ///
    /// ## What this does and does not defend against
    ///
    /// It defends against the threat MSL itself introduces, which is
    /// measured and specific: **a Linux guest writing the binary**. Guests
    /// get the Mac's home directory at `/mnt/mac` read-write, so the copy
    /// in `~/Library/Application Support/MSL/bin` is writable from inside a
    /// VM. Nothing mounts `/Applications`, so moving the helper there
    /// closes that completely.
    ///
    /// It does **not** defend against a local process already running as an
    /// administrator, because `/Applications` is group-writable by `admin`
    /// and such a process could replace the whole bundle. That is the trust
    /// model of every `sudo` of anything under `/Applications` on macOS and
    /// MSL is not in a position to improve on it - ad-hoc signing leaves no
    /// Team ID to pin. It is worth knowing rather than worth pretending
    /// about.
    ///
    /// Split out and `internal` so it can be tested against real paths
    /// without an installed app.
    static func firstUnsafeComponent(of path: String) -> String? {
        var walked = ""
        for component in path.split(separator: "/") {
            walked += "/" + component
            var info = stat()
            guard stat(walked, &info) == 0 else { return walked }
            guard info.st_uid == 0 else { return walked }
            guard info.st_mode & UInt16(S_IWOTH) == 0 else { return walked }
            if info.st_mode & UInt16(S_IWGRP) != 0, !systemGroups.contains(info.st_gid) {
                return walked
            }
        }
        return nil
    }

    private static func installedAppBundle() -> URL? {
        var candidates: [URL] = []
        #if canImport(AppKit)
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.msl.app") {
            candidates.append(found)
        }
        #endif
        candidates.append(URL(fileURLWithPath: "/Applications/MSL.app"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
