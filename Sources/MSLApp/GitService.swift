import Foundation
import MSLCore

/// Runs the git reading for whichever side of the Mac/Linux line a folder is
/// on, and hands both answers to the same parser.
///
/// A folder in MSL Files is either inside an instance - reached through a
/// WebDAV mount - or an ordinary Mac folder. The two need completely
/// different machinery and must not be allowed to produce subtly different
/// answers, so `Git` does all the interpreting and this only decides where
/// the script runs.
enum GitService {

    /// Reads a folder, wherever it is. Blocking: callers hop off the main
    /// actor first.
    static func inspect(hostPath: String, guestPath: String?, instance: String?) -> Git.Outcome {
        if let guestPath, let instance {
            switch DaemonClient.guestGit(instance: instance, guestPath: guestPath,
                                         operation: .inspect) {
            case .success(let output): return Git.parse(output)
            case .failure(let absence): return .absent(absence)
            }
        }
        if let refusal = refusalForAnInstanceFolder(hostPath) { return .absent(refusal) }
        return runOnTheMac(script: Git.inspectScript(path: hostPath))
    }

    /// Stops a folder inside an instance from being read by Mac-side git when
    /// MSL could not work out which instance it belongs to.
    ///
    /// Without this the code falls through to the Mac branch and does the one
    /// thing the whole design says never to do: run git over the WebDAV
    /// mount, where faked modes make every file look changed and a stat per
    /// file is slow enough to hang the panel. Saying the instance is not
    /// running is both true - that is why the mount has no owner - and
    /// actionable.
    static func refusalForAnInstanceFolder(_ hostPath: String) -> Git.Absence? {
        hostPath.hasPrefix("/Volumes/127.0.0.1") ? .instanceNotRunning : nil
    }

    /// Creates a repository. Returns nil on success, or why not.
    static func initialise(hostPath: String, guestPath: String?,
                           instance: String?) -> Git.Absence? {
        if let guestPath, let instance {
            switch DaemonClient.guestGit(instance: instance, guestPath: guestPath,
                                         operation: .initialise) {
            case .success(let output):
                if output.contains("MSL:ok") { return nil }
                if output.contains("MSL:nogit") { return .gitNotInstalled }
                if output.contains("MSL:nodir") { return .noSuchFolder }
                return .failed("git could not create a repository there.")
            case .failure(let absence):
                return absence
            }
        }
        if let refusal = refusalForAnInstanceFolder(hostPath) { return refusal }
        guard macGitIsUsable() else { return .commandLineToolsMissing }
        let output = runScriptOnTheMac(Git.initialiseScript(path: hostPath))
        if output.contains("MSL:ok") { return nil }
        if output.contains("MSL:nodir") { return .noSuchFolder }
        return .failed("git could not create a repository there.")
    }

    /// Reads the git state of a Mac directory's subfolders.
    ///
    /// **Spawns nothing unless there is something to read.** A listing pass
    /// runs on every directory opened, and on a Mac with no Command Line
    /// Tools `/usr/bin/git` does not fail - it opens a system dialog offering
    /// to install them. A dialog appearing because somebody opened a folder
    /// would be unforgivable, so the cheap `.git` test comes first and git is
    /// only consulted if some subfolder is actually a repository.
    static func badges(inDirectory directory: String) -> [String: Git.Badge] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [:] }
        let hasAnyRepository = names.contains { name in
            // `.git` is a file in a submodule or a linked worktree.
            fm.fileExists(atPath: (directory as NSString)
                .appendingPathComponent("\(name)/.git"))
        }
        guard hasAnyRepository, macGitIsUsable() else { return [:] }
        return Git.parseBadges(runScriptOnTheMac(Git.badgesScript(directory: directory)))
    }

    /// Points `origin` at a URL, or removes it when the URL is empty.
    /// Returns nil on success, or why not.
    static func setOrigin(hostPath: String, guestPath: String?, instance: String?,
                          url: String) -> Git.Absence? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Git.isUsableRemote(trimmed) else {
            return .failed("That is not a usable remote URL.")
        }
        if let guestPath, let instance {
            switch DaemonClient.guestGit(instance: instance, guestPath: guestPath,
                                         operation: .setOrigin, argument: trimmed) {
            case .success(let output):
                if output.contains("MSL:ok") { return nil }
                if output.contains("MSL:norepo") { return .notARepository }
                if output.contains("MSL:nogit") { return .gitNotInstalled }
                return .failed("git would not set that remote.")
            case .failure(let absence):
                return absence
            }
        }
        if let refusal = refusalForAnInstanceFolder(hostPath) { return refusal }
        guard macGitIsUsable() else { return .commandLineToolsMissing }
        let output = runScriptOnTheMac(Git.setOriginScript(path: hostPath, url: trimmed))
        if output.contains("MSL:ok") { return nil }
        if output.contains("MSL:norepo") { return .notARepository }
        return .failed("git would not set that remote.")
    }

    // MARK: - The Mac side

    /// Whether running git on the Mac will actually run git.
    ///
    /// **`/usr/bin/git` is a shim.** With no Command Line Tools installed it
    /// does not fail - it pops up a system dialog offering to install them,
    /// which for a file browser that reads git as you browse would mean a
    /// dialog appearing because somebody opened a folder. So the tools are
    /// checked for first, and when they are missing the panel says so
    /// instead of provoking one.
    static func macGitIsUsable() -> Bool {
        // Cached for the life of the process. Installing the Command Line
        // Tools is not something that happens mid-session, and this is now on
        // the path of every directory opened.
        if let known = cachedMacGitIsUsable { return known }
        let answer = probeMacGit()
        cachedMacGitIsUsable = answer
        return answer
    }

    nonisolated(unsafe) private static var cachedMacGitIsUsable: Bool?

    private static func probeMacGit() -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runOnTheMac(script: String) -> Git.Outcome {
        guard macGitIsUsable() else { return .absent(.commandLineToolsMissing) }
        return Git.parse(runScriptOnTheMac(script))
    }

    private static func runScriptOnTheMac(_ script: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // On standard input rather than as an argument, so nothing in the
        // script - a folder name with a quote in it - has to survive being
        // quoted into a command line.
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return "" }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()

        // Nothing here should take twenty seconds, and a few things can take
        // forever: a repository on a network share, an iCloud folder that
        // has to be materialised, a stale mount. Without this the panel
        // spins with no way out.
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        defer { killer.cancel() }

        // Read before waiting. A repository with a lot of history fills the
        // pipe buffer, and a child blocked on a full pipe never exits, so
        // waiting first deadlocks on exactly the repositories worth looking
        // at.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
