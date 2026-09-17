import Foundation

/// One thing MSL did, for the traffic monitor.
public struct ActivityEvent: Codable, Identifiable, Sendable, Equatable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case control    // daemon commands: start, suspend, snapshot
        case file       // the Finder bridge: WebDAV methods, file-op opcodes
        case display    // X11 connections, app hosts, mslgd
        case lifecycle  // the VM itself: booted, paused, restored, stopped
        case sandbox    // gates opening and closing

        public var title: String {
            switch self {
            case .control:   return "Control"
            case .file:      return "Files"
            case .display:   return "Display"
            case .lifecycle: return "Lifecycle"
            case .sandbox:   return "Sandbox"
            }
        }

        public var symbol: String {
            switch self {
            case .control:   return "terminal"
            case .file:      return "folder"
            case .display:   return "display"
            case .lifecycle: return "power"
            case .sandbox:   return "lock.shield"
            }
        }
    }

    public var id: String { "\(at.timeIntervalSince1970)-\(summary)-\(repeatCount)" }
    public let at: Date
    public let instance: String?
    public let category: Category
    public let summary: String
    public let detail: String?
    /// How many identical events this line stands for. Coalescing happens
    /// at write time: a chatty caller must not be able to turn this into
    /// the snapshot-dumping incident (see `MSL_X11_SNAPSHOT_DIR`, which
    /// PNG-encoded a window per draw request and took mslhd to 38 GB).
    public var repeatCount: Int

    public init(at: Date = Date(), instance: String?, category: Category,
                summary: String, detail: String? = nil, repeatCount: Int = 1) {
        self.at = at
        self.instance = instance
        self.category = category
        self.summary = summary
        self.detail = detail
        self.repeatCount = repeatCount
    }
}

/// A bounded, file-backed record of what MSL is doing.
///
/// File-backed because the writer and the reader are different processes:
/// `mslhd` owns every VM and every vsock connection, `MSLApp` draws the
/// monitor, and each `mslgui` app host is a third. A JSONL file that
/// everyone appends to and the UI tails is far less machinery than a
/// streaming daemon command, and it survives the reader not being there.
///
/// **Off unless something is watching.** Recording is gated on a flag file
/// that the monitor window creates while it is open, so the steady-state
/// cost of all this is one cached `stat` per second in the writer. That is
/// deliberate and not merely tidy: this project has already taken a host
/// process to 100% CPU and 38 GB by logging one entry per X11 draw request.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    /// Hard ceiling on the file. Once past it the oldest half is dropped -
    /// a ring buffer, just one written in lines rather than slots.
    private static let maxBytes = 512 * 1024
    private static let trimTo = 256 * 1024

    /// How long a repeat of the same summary is folded into the previous
    /// line rather than appended.
    private static let coalesceWindow: TimeInterval = 2.0

    private let lock = NSLock()
    private var lastSummary: String?
    private var lastAt = Date.distantPast
    private var lastCount = 0
    private var enabledCache: (value: Bool, checked: Date) = (false, .distantPast)

    private init() {}

    public static var directory: URL {
        MSLPaths.appSupport.appendingPathComponent("activity", isDirectory: true)
    }
    public static var file: URL { directory.appendingPathComponent("activity.jsonl") }
    /// Present only while a monitor window is open.
    public static var watchFlag: URL { directory.appendingPathComponent("watching") }

    // MARK: - Watching

    /// Called by the monitor when it opens. Recording is a no-op until this
    /// has happened at least once.
    public static func beginWatching() {
        _ = MSLPaths.ensureDirectory(directory)
        FileManager.default.createFile(atPath: watchFlag.path, contents: Data())
    }

    /// Called when the last monitor closes. Leaves the log in place - it is
    /// bounded, and a user who closes the window still wants to see what
    /// happened when they open it again.
    public static func endWatching() {
        try? FileManager.default.removeItem(at: watchFlag)
    }

    private func isWatched() -> Bool {
        let now = Date()
        if now.timeIntervalSince(enabledCache.checked) < 1.0 { return enabledCache.value }
        let watched = FileManager.default.fileExists(atPath: Self.watchFlag.path)
        enabledCache = (watched, now)
        return watched
    }

    // MARK: - Writing

    /// Records one event. Cheap and safe to call from anywhere, including
    /// hot paths - it returns immediately when nothing is watching.
    ///
    /// Never call this from inside a Virtualization.framework delegate
    /// callback: it takes a lock and touches the filesystem, and blocking
    /// work in those callbacks hangs the whole process (this project has
    /// done it twice, once for 20+ minutes).
    public func record(_ category: ActivityEvent.Category,
                       instance: String?,
                       _ summary: String,
                       detail: String? = nil) {
        guard isWatched() else { return }

        lock.lock()
        let now = Date()
        // Fold a burst of identical lines into one. Without this, a retry
        // loop or a polling client writes thousands of indistinguishable
        // rows and the interesting one scrolls away.
        if summary == lastSummary, now.timeIntervalSince(lastAt) < Self.coalesceWindow {
            lastCount += 1
            lastAt = now
            lock.unlock()
            return
        }
        let pendingRepeat = lastCount
        let pendingSummary = lastSummary
        lastSummary = summary
        lastAt = now
        lastCount = 1
        lock.unlock()

        // A folded burst is only written out once the *next* distinct event
        // arrives, so its final count is known.
        if let pendingSummary, pendingRepeat > 1 {
            append(ActivityEvent(at: now, instance: instance, category: category,
                                 summary: pendingSummary,
                                 detail: "repeated \(pendingRepeat) times",
                                 repeatCount: pendingRepeat))
        }
        append(ActivityEvent(at: now, instance: instance, category: category,
                             summary: summary, detail: detail))
    }

    private func append(_ event: ActivityEvent) {
        guard MSLPaths.ensureDirectory(Self.directory) else { return }
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)

        let path = Self.file.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: Self.file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)

        if let size = try? handle.offset(), size > Self.maxBytes { trim() }
    }

    /// Drops the oldest lines. Reads the whole file, which is fine because
    /// `maxBytes` keeps it small by construction.
    private func trim() {
        guard let data = try? Data(contentsOf: Self.file), data.count > Self.trimTo else { return }
        let keep = data.suffix(Self.trimTo)
        // Start at the first whole line, or the head of the file is half an
        // event and the reader drops it as malformed.
        guard let newline = keep.firstIndex(of: 0x0A) else { return }
        let trimmed = keep[keep.index(after: newline)...]
        try? Data(trimmed).write(to: Self.file, options: .atomic)
    }

    // MARK: - Reading

    /// Everything currently in the log, oldest first.
    ///
    /// A line that will not decode is skipped rather than aborting the
    /// read: the writer may be appending as this runs, so the last line can
    /// legitimately be half-written. (The same shape of bug as the guest
    /// listing that used to hide a whole directory over one bad name.)
    public static func read(limit: Int = 500) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        var events: [ActivityEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(ActivityEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        return events.suffix(limit)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
