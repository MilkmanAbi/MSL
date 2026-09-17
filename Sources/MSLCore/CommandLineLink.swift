import Foundation

/// `/usr/local/bin/msl`: whether typing `msl` in Terminal.app works.
///
/// The installer package makes this link, but only the package can - the
/// directory needs root - so anyone who got MSL any other way (a copied
/// app, a build) has no `msl` on PATH, and a package that went wrong can
/// leave a link to nothing. On 2026-09-16 exactly that happened: the link
/// pointed into an /Applications/MSL.app that was never installed, and the
/// shell said "command not found". The Permissions & Startup window reads
/// this and offers to fix it.
public enum CommandLineLink {
    public static let defaultPath = "/usr/local/bin/msl"

    public enum Status: Equatable {
        /// `msl` runs from Terminal.
        case ready(target: String)
        /// A link is there but what it points at isn't - the worst case,
        /// because the shell finds `msl` and then can't run it.
        case broken(target: String)
        /// Something that isn't MSL's link is in the way. Left alone.
        case occupied
        case missing
    }

    public static func status(at path: String = defaultPath) -> Status {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: path)) != nil else { return .missing }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: path) else {
            // A real file. An executable one called msl is most likely a
            // copy someone made by hand - it runs, so count it as ready.
            return fm.isExecutableFile(atPath: path) ? .ready(target: path) : .occupied
        }
        let resolved = destination.hasPrefix("/")
            ? destination
            : (path as NSString).deletingLastPathComponent + "/" + destination
        return fm.isExecutableFile(atPath: resolved) ? .ready(target: resolved) : .broken(target: resolved)
    }

    /// What the link should point at when MSL.app makes it: the copy the
    /// app keeps current in `bin/` on every launch, so it survives the app
    /// being moved or replaced.
    public static var preferredTarget: String { MSLPaths.tool("msl").path }

    /// The shell command that makes the link. Run with administrator
    /// rights; `ln -sfn` replaces a broken link in place.
    public static func installCommand(target: String = preferredTarget, at path: String = defaultPath) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return "mkdir -p \(shellQuoted(directory)) && ln -sfn \(shellQuoted(target)) \(shellQuoted(path))"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
