import Foundation

/// One stamped line in `~/Library/Logs/MSL/mslhd.log`.
///
/// MSL's own log lines carried **no timestamps at all**, which is fine until
/// someone asks *when* something happened - and that is the only question
/// that matters after an incident. On 2026-09-29 a report of "MSL Files
/// crashed, then Firefox crashed" could not be pinned to a cause, because the
/// log showed a VM restore, then an unclean stop, then a cold boot, with
/// nothing to say whether any of it lined up with the moment the person saw
/// it. Guest console output (which is most of the file) carries the kernel's
/// own `[ 0.1234]` stamps and is left alone; these are MSL's lines.
///
/// Local time, seconds resolution: this is read by a person comparing it
/// against when they saw something, not by a machine.
public enum MSLLog {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// Where every MSL process writes, whoever it is.
    ///
    /// **stderr alone was not enough.** Only `mslhd` has its output
    /// redirected to a file, by `StandardErrorPath` in its LaunchAgent - and
    /// only when that plist exists. Everything else writes into the void:
    /// the per-app `mslgui` hosts, which is where the X11 server actually
    /// runs, so the one subsystem whose failures look like an app crashing
    /// was also the one that could never be read afterwards.
    ///
    /// That is most of why "I never see crash logs" was true.
    nonisolated(unsafe) private static let fileHandle: FileHandle? = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MSL")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("msl.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // **O_APPEND, not seek-to-end.** A handle that merely seeks once
        // keeps writing at the offset it remembers, so the moment anything
        // truncates the file - which "Clear" in the MSL panel does, and must,
        // because unlinking a log the daemon holds open would send its
        // output to an inode with no name - the next write lands at the old
        // offset and the kernel fills everything before it with NULs. The
        // log springs back to its previous size, full of zeroes, having
        // apparently been cleared. Measured: truncate to 0, write 11 bytes,
        // get a 4011-byte file beginning with NULs.
        //
        // With O_APPEND the kernel seeks to the end as part of each write,
        // so a truncation underneath is simply the new end.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }()

    /// Which process this line came from. Several write to the same file,
    /// and "which one said this" is the first question afterwards.
    nonisolated(unsafe) private static let processName =
        ProcessInfo.processInfo.processName

    /// `05-29 14:12:08 mslhd[power]: ...`
    public static func line(_ subsystem: String, _ message: String) {
        let stamped = "\(formatter.string(from: Date())) \(processName) \(subsystem): \(message)\n"
        let data = Data(stamped.utf8)
        FileHandle.standardError.write(data)
        // Appended, never truncated: two processes may be writing at once,
        // and a line lost to a race is a line nobody can act on.
        try? fileHandle?.write(contentsOf: data)
    }
}
