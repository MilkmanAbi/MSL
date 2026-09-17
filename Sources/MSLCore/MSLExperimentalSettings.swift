import Foundation

/// Every experiment MSL ships, in one place.
///
/// An experiment is anything a future version might fold into MSL proper,
/// change, or remove - which is a statement about its future, not about
/// whether it starts on. Most start off; the integrations that make Linux
/// apps behave like Mac apps (links, folders) start on. MSL's Experimental
/// Features window is the only place that changes any of them.
public struct MSLExperimentalSettings: Codable, Equatable, Sendable {
    /// Command+letter reaches Linux apps as Control+letter: Cmd+C copies,
    /// Cmd+Z undoes, Cmd+S saves, as on a Mac. Command then stops being
    /// Super for those apps.
    public var linuxShortcuts = false
    /// Mac text navigation: Cmd+arrows go to the line or document edges,
    /// Option+arrows move by word, Cmd/Option+Delete delete to the line
    /// start or the previous word.
    public var macTextNavigation = false
    /// Cmd+Shift+3/4/5 send Print, Shift+Print and Alt+Print - the Linux
    /// screenshot keys. macOS takes these for its own screenshots unless
    /// they are turned off in System Settings > Keyboard > Keyboard Shortcuts.
    public var screenshotKeys = false
    /// What the two Option keys are to Linux apps. Not a toggle, but still
    /// experimental: the default suits PC-style apps.
    public var optionKeyMode: X11OptionKeyMode = .leftAltRightAltGr

    /// Web links and `mailto:` links clicked in a Linux app open in the
    /// Mac's default browser and mail app instead of a Linux one. Email
    /// attachments come across with them. On by default.
    public var openLinksOnMac = true
    /// Folders a Linux app asks to show ("Open containing folder", "Show in
    /// Files") open in MSL Files instead of a Linux file manager. The Linux
    /// file managers themselves still run when started directly. On by
    /// default.
    public var preferMSLFiles = true
    /// Linux app menus (File, Edit, ...) move into the Mac's menu bar, read
    /// over D-Bus. Takes effect for apps launched after it is turned on.
    public var globalMenuBar = false

    public init() {}

    /// Missing keys decode to their defaults, so a file written by an older
    /// build - or a newer one with flags this build doesn't know - still
    /// loads instead of silently resetting everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linuxShortcuts = try c.decodeIfPresent(Bool.self, forKey: .linuxShortcuts) ?? false
        macTextNavigation = try c.decodeIfPresent(Bool.self, forKey: .macTextNavigation) ?? false
        screenshotKeys = try c.decodeIfPresent(Bool.self, forKey: .screenshotKeys) ?? false
        optionKeyMode = (try? c.decodeIfPresent(X11OptionKeyMode.self, forKey: .optionKeyMode)) ?? .leftAltRightAltGr
        // A file from before these existed gets their shipped defaults -
        // including the two that start on.
        let defaults = MSLExperimentalSettings()
        openLinksOnMac = try c.decodeIfPresent(Bool.self, forKey: .openLinksOnMac) ?? defaults.openLinksOnMac
        preferMSLFiles = try c.decodeIfPresent(Bool.self, forKey: .preferMSLFiles) ?? defaults.preferMSLFiles
        globalMenuBar = try c.decodeIfPresent(Bool.self, forKey: .globalMenuBar) ?? defaults.globalMenuBar
    }
}

/// Reads and writes `experimental.json`.
///
/// A file rather than `UserDefaults`: the Linux app hosts (`mslgui`) are
/// unbundled executables copied per app, with no bundle identifier, so they
/// cannot see MSL.app's defaults domain. A toggle stored there would look
/// like it did nothing.
public enum MSLExperimentalSettingsStore {
    public static var fileURL: URL {
        MSLPaths.appSupport.appendingPathComponent("experimental.json")
    }

    public static func load(from url: URL = fileURL) -> MSLExperimentalSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(MSLExperimentalSettings.self, from: data)
        else { return MSLExperimentalSettings() }
        return settings
    }

    public static func save(_ settings: MSLExperimentalSettings, to url: URL = fileURL) throws {
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// The settings as this process currently sees them, kept current by
/// watching the file.
///
/// Same approach as `X11InputGate`: one `stat` per check, decoding only
/// when the modification date moves. Checked on a one-second timer rather
/// than per key event, because some changes (the Option key arrangement)
/// rebuild the keymap and must reach the app before the next keystroke,
/// not as a side effect of it.
public final class MSLExperimentalSettingsWatcher: @unchecked Sendable {
    public static let shared = MSLExperimentalSettingsWatcher()
    public static let didChangeNotification = Notification.Name("MSLExperimentalSettingsDidChange")

    private let lock = NSLock()
    private var cached = MSLExperimentalSettings()
    private var stamp: Date?
    private var loaded = false
    private var timer: DispatchSourceTimer?
    private let url: URL

    init(url: URL = MSLExperimentalSettingsStore.fileURL) {
        self.url = url
    }

    public var current: MSLExperimentalSettings {
        lock.lock()
        let needsLoad = !loaded
        lock.unlock()
        if needsLoad { refresh() }
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Idempotent.
    public func startWatching() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
    }

    /// Re-reads the file if it changed. Returns whether the settings did.
    @discardableResult
    public func refresh() -> Bool {
        let newStamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        if loaded, newStamp == stamp {
            lock.unlock()
            return false
        }
        lock.unlock()
        let settings = MSLExperimentalSettingsStore.load(from: url)
        lock.lock()
        let changed = loaded && settings != cached
        cached = settings
        stamp = newStamp
        loaded = true
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return changed
    }
}
