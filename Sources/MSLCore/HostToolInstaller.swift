import Foundation

/// Copies the host-side executables out of wherever they were built and
/// into `MSLPaths.binDirectory`, so that things outside this repository -
/// generated `.app` bundles, the LaunchAgent - can depend on a stable path.
///
/// Nothing else could: the binaries currently live under
/// `.build/arm64-apple-macosx/release/`, a path that is wiped by a clean
/// build and that no user would ever have on `$PATH` (`which msl` finds
/// nothing on this machine today). A bundle generated in September must
/// still launch in December.
public enum HostToolInstaller {
    /// The tools a generated bundle or the LaunchAgent can reference.
    /// `mslgui` is included because `X11AppRouter` looks for it as a
    /// sibling of the running host binary - installing them together keeps
    /// that relationship true in the install directory too.
    ///
    /// `mslod`, MSL's observer, is installed the same way as the rest and
    /// deliberately nowhere special: it is an ordinary program that happens
    /// to watch the others, and an observer that only existed in a build
    /// directory would be an observer nobody ever had.
    public static let tools = ["msl", "mslhd", "mslgui", "msl-applauncher",
                               "msl-usbd", "mslod"]

    /// Tools that must carry `com.apple.security.virtualization` to work at
    /// all. `mslhd` is the only process that ever constructs a
    /// `VZVirtualMachine`; signed without it, it starts, accepts
    /// connections, and then fails the moment anything asks for a VM -
    /// a failure that looks nothing like a signing problem.
    /// `msl-usbd` is deliberately absent: it is the one tool that runs under
    /// `sudo`, and `com.apple.vm.device-access` is a *restricted*
    /// entitlement - ad-hoc signing it gets the process SIGKILLed at exec
    /// (measured, exit 137). It takes root instead, which is free.
    static let entitledTools: Set<String> = ["mslhd"]

    /// Written out next to the installed binaries rather than read from the
    /// source tree: installation has to keep working from a built product
    /// that was copied somewhere else entirely, with no repository around
    /// it. Content matches `Resources/MSLApp/MSLApp.entitlements`.
    private static let virtualizationEntitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.virtualization</key>
        <true/>
    </dict>
    </plist>
    """

    public struct Result {
        public var installed: [String] = []
        public var missing: [String] = []
        public var failed: [String: String] = [:]
        /// Tools left alone because the copy on offer is older than the one
        /// already installed - an old MSL.app trying to undo an update.
        public var skippedOlder: [String] = []
        public var isComplete: Bool { missing.isEmpty && failed.isEmpty }
    }

    /// Installs every tool found in `sourceDirectory` into
    /// `MSLPaths.binDirectory`, skipping any whose installed copy is
    /// already identical.
    ///
    /// Each copy is re-signed ad-hoc. This is not optional: macOS refuses
    /// to execute a copied Mach-O whose signature no longer matches its
    /// location, which is the same lesson `X11AppRouter.ensureShimBinary`
    /// learned when it started copying a binary per Linux app.
    @discardableResult
    /// Last-modified date, or nil when it cannot be read.
    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func install(from sourceDirectory: URL) -> Result {
        var result = Result()
        MSLPaths.ensureDirectory(MSLPaths.binDirectory)

        for tool in tools {
            let source = sourceDirectory.appendingPathComponent(tool)
            guard FileManager.default.isExecutableFile(atPath: source.path) else {
                result.missing.append(tool)
                continue
            }
            let destination = MSLPaths.tool(tool)
            if identical(source, destination) {
                result.installed.append(tool)
                continue
            }
            // Never go backwards. An older MSL.app left in /Applications
            // still installs its own tools on every launch, so opening it
            // once quietly replaced a working `mslhd` with a weeks-old one
            // - and nothing said so. A copy older than what is installed is
            // reported as skipped, not silently applied.
            // An hour of slack. Re-signing rewrites the installed copy, so
            // its timestamp is always a little newer than the build it came
            // from; without the tolerance every later install reported a
            // "downgrade" that was nothing of the sort. What this is for is
            // an MSL.app that is *days* behind.
            if let installedDate = modified(destination), let sourceDate = modified(source),
               installedDate.timeIntervalSince(sourceDate) > 3600 {
                result.skippedOlder.append(tool)
                continue
            }
            do {
                // Replace rather than overwrite: overwriting the bytes of a
                // Mach-O that is currently executing gives the running
                // process a corrupted text segment; unlinking first leaves
                // it running happily on the old inode.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                if let error = adhocSign(destination, entitlements: entitledTools.contains(tool) ? writeEntitlementsFile() : nil) {
                    result.failed[tool] = error
                } else {
                    result.installed.append(tool)
                }
            } catch {
                result.failed[tool] = "\(error)"
            }
        }
        return result
    }

    /// Where this process's own sibling binaries are - the natural source
    /// directory when MSL itself is what's doing the installing.
    ///
    /// From the executable's real path, never `argv[0]`: typed at a prompt,
    /// `msl` arrives as the bare word "msl", which resolved against the
    /// current directory - so the first `msl` after installing the package
    /// looked for mslhd in ~ and said it wasn't installed (2026-09-16).
    public static var runningBinaryDirectory: URL {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// Where the tools to install can be found: beside the running binary,
    /// or else in the installed app.
    public static var toolSourceDirectory: URL? {
        let candidates = [runningBinaryDirectory,
                          URL(fileURLWithPath: "/Applications/MSL.app/Contents/MacOS")]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("mslhd").path)
        }
    }

    /// The entitlements plist on disk, written once into the install
    /// directory. Returns `nil` if it couldn't be written, in which case
    /// the caller signs without entitlements - a broken `mslhd` is worse
    /// than an unsigned one, but an unwritable install directory has
    /// already failed for other reasons by this point.
    private static func writeEntitlementsFile() -> URL? {
        let url = MSLPaths.binDirectory.appendingPathComponent("virtualization.entitlements")
        guard let data = virtualizationEntitlements.data(using: .utf8) else { return nil }
        if let existing = try? Data(contentsOf: url), existing == data { return url }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let lhs = try? Data(contentsOf: a), let rhs = try? Data(contentsOf: b) else { return false }
        return lhs == rhs
    }

    /// Returns `nil` on success, or the failure output.
    @discardableResult
    public static func adhocSign(_ url: URL, entitlements: URL? = nil, deep: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // **A stable identity, not just a signature.**
        //
        // Ad-hoc signing defaults a binary's designated requirement to its
        // cdhash, which changes on every build. macOS keys privacy grants -
        // Local Network above all - on that requirement, so each update
        // looked like a brand new program and silently lost every
        // permission the user had given.
        //
        // That is how it presented: the Tailscale route worked, mslhd was
        // rebuilt, and afterwards every connection was refused with
        // EHOSTUNREACH while the same command from a shell still reached
        // the guest. The app bundle's copy already carried
        // `identifier "com.msl.app"`; the copy the LaunchAgent actually
        // runs, installed here, did not.
        //
        // `--identifier` makes each tool's identity its name rather than
        // its contents, and the designated requirement follows from it.
        var arguments = ["--force", "--sign", "-",
                         "--identifier", "com.msl." + url.lastPathComponent,
                         "-r=designated => identifier \"com.msl." + url.lastPathComponent + "\""]
        if deep { arguments.append("--deep") }
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        arguments.append(url.path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "couldn't run codesign" }
        let errorOutput = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
