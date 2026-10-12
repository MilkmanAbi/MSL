import Foundation

/// MSL's own log files, for the panel that offers to look at them or clear
/// them out.
public enum MSLLogs {

    /// One log file, as the panel lists it.
    public struct File: Equatable, Sendable, Identifiable {
        public let name: String
        public let path: String
        public let bytes: Int64
        public let modified: Date?
        public var id: String { path }

        public init(name: String, path: String, bytes: Int64, modified: Date?) {
            self.name = name
            self.path = path
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// Every log MSL has written, largest first - which is the one somebody
    /// clearing them out actually cares about.
    public static func files(in directory: URL = MSLPaths.logsDirectory) -> [File] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".log") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                return File(name: name, path: url.path,
                            bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                            modified: attributes?[.modificationDate] as? Date)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    public static func totalBytes(in directory: URL = MSLPaths.logsDirectory) -> Int64 {
        files(in: directory).reduce(0) { $0 + $1.bytes }
    }

    /// Empties every log, and returns how many bytes that recovered.
    ///
    /// **Truncates rather than deletes, and the difference is the whole
    /// function.** `mslhd` holds its log open for the life of the process.
    /// Unlinking the file does not close that descriptor: the daemon goes on
    /// writing happily to an inode with no name, so the log appears to stay
    /// empty while the disk space is never returned, and nothing is recorded
    /// anywhere a person can read it until the daemon next restarts.
    /// Truncating leaves the descriptor pointing at the same file, which
    /// simply becomes empty.
    @discardableResult
    public static func clear(in directory: URL = MSLPaths.logsDirectory) -> Int64 {
        var recovered: Int64 = 0
        for file in files(in: directory) {
            // O_WRONLY|O_TRUNC rather than removeItem, for the reason above.
            let fd = open(file.path, O_WRONLY | O_TRUNC)
            guard fd >= 0 else { continue }
            close(fd)
            recovered += file.bytes
        }
        return recovered
    }

    /// The last `lines` lines of a log, for showing a tail in the panel
    /// without reading a file that may be very large.
    public static func tail(of path: String, lines: Int = 200) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // 64 KB is far more than 200 lines of anything MSL writes, and
        // bounds the read whatever the file has grown to.
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        // A window that started mid-file almost certainly started mid-line.
        let whole = start > 0 ? text.drop(while: { $0 != "\n" }).dropFirst() : Substring(text)
        return whole.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}
