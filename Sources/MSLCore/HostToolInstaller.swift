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
    public static let tools = ["msl", "mslhd", "mslgui", "msl-applauncher"]

    /// Tools that must carry `com.apple.security.virtualization` to work at
    /// all. `mslhd` is the only process that ever constructs a
    /// `VZVirtualMachine`; signed without it, it starts, accepts
    /// connections, and then fails the moment anything asks for a VM -
    /// a failure that looks nothing like a signing problem.
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
        var arguments = ["--force", "--sign", "-"]
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
