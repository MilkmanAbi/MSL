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
    ///
    /// On by default: a Mac keyboard that does nothing in Linux apps is the
    /// single most jarring thing about running them, and the two reasons to
    /// be careful are handled. `X11KeyboardRouter.isReservedForMac` keeps
    /// macOS's own window and session commands (⌘Q, ⌘H, ⌘M, ⌘`, anything
    /// with ⌃⌘), and `X11TerminalApps` sends ⌘C to a terminal as
    /// Ctrl+Shift+C so it copies instead of killing the running command.
    public var linuxShortcuts = true
    /// Mac text navigation: Cmd+arrows go to the line or document edges,
    /// Option+arrows move by word, Cmd/Option+Delete delete to the line
    /// start or the previous word. On by default, with the same reasoning.
    public var macTextNavigation = true
    /// Cmd+Shift+3/4/5 send Print, Shift+Print and Alt+Print - the Linux
    /// screenshot keys.
    ///
    /// On by default, and harmless there: macOS takes these for its own
    /// screenshots first, so this only does anything once someone has turned
    /// the macOS ones off in System Settings > Keyboard > Keyboard Shortcuts
    /// - at which point sending them on is exactly what they asked for.
    public var screenshotKeys = true
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

    /// Close Linux apps before a hibernate and open them again on resume.
    ///
    /// On by default because the alternative is worse, not because it is
    /// free: without it a hibernated instance comes back with its apps
    /// alive in restored RAM but blind - their X server died with the Mac
    /// side - so they sit there holding singleton locks and cannot be
    /// started again. See `AppSessionRestore`.
    public var reopenAppsAfterHibernate = true
    /// Linux app menus (File, Edit, ...) move into the Mac's menu bar, read
    /// over D-Bus. Takes effect for apps launched after it is turned on.
    ///
    /// On by default from v2. It is what makes a Linux application feel like
    /// a Mac application rather than a window with a menu bar drawn inside
    /// it, and the thing that used to make it risky - a dozen menus running
    /// into a MacBook's notch - is handled now by `MenuBarFitting`, which
    /// keeps what fits and puts the rest behind one final menu.
    public var globalMenuBar = true

    /// Copy and paste between Linux apps and the Mac, bridged through
    /// `NSPasteboard` (see `X11Clipboard`).
    ///
    /// On by default: copying in a Linux app and pasting in a Mac one is
    /// half of what "the shortcuts work" means, and the keyboard mapping
    /// above is what makes people try it.
    ///
    /// Experimental because of what it still does not cover: `PRIMARY`
    /// (X11's select-to-copy, so `xterm` and Motif apps do not reach the
    /// Mac's clipboard) and anything that is neither text, an image, nor
    /// files.
    public var guestClipboard = true

    /// Sign-in pages open in the *guest's* browser, not the Mac's.
    ///
    /// Everything else still opens on the Mac - this is only the handful of
    /// links that are the start of an OAuth flow, and it exists because
    /// those cannot work on the Mac at all. A sign-in ends by returning its
    /// answer to the machine that began it: either to `127.0.0.1:PORT`,
    /// where the Linux app is listening, or to a private scheme like
    /// `discord://` that only Linux knows how to route. Opened on the Mac,
    /// the answer arrives on the Mac and the Linux app waits forever.
    ///
    /// On by default, and narrow by construction: it needs a browser in the
    /// guest and a URL that really looks like an authorisation request, or
    /// the link goes to the Mac as before.
    public var signInInLinuxBrowser = true

    /// Linux apps get the Mac's camera and microphone the moment they open
    /// them, without MSL Peripherals asking first.
    ///
    /// For ROS2 and anything else that starts camera nodes over and over:
    /// being asked every time is right for Cheese and wrong for a robot.
    /// macOS's own permission is still asked for, once - no app can skip
    /// that - and the camera light and microphone indicator still show
    /// whenever something is actually capturing. Off by default: the
    /// normal answer to "a Linux app wants your camera" is to ask.
    public var omitPeripheralsPrompt = false

    /// Linux windows drawn closer to the Mac's own UI size - see
    /// `X11DisplayScale`. Off by default: one X pixel per point is what
    /// every app has been tested at.
    public var nativeScaling = false

    /// Linux windows rendered at the Mac's real pixel density instead of at
    /// one X pixel per point - see `X11DisplayScale`.
    ///
    /// **On by default since it was tried on real apps.** Chromium, Krita
    /// and the rest come back as sharp as the Mac's own, which is worth the
    /// cost: an app draws four times the pixels and every one of them
    /// crosses the X11 connection. Takes precedence over `nativeScaling`,
    /// which is the same question answered at lower detail and stays off.
    public var retinaRendering = true

    /// Linux OpenGL apps render on the Mac's GPU instead of the guest's
    /// CPU (see `GPUBridge` and `Guest/virtual-gpu/`).
    ///
    /// **CPU rendering (llvmpipe) is the default and always works** - this
    /// only moves OpenGL onto the GPU when it is worth it. Off by default,
    /// and not only because it is new: the host renderer goes through
    /// Apple's OpenGL, which stops at **GL 4.1**, while the guest's own
    /// llvmpipe offers 4.5. **Anything needing newer OpenGL than 4.1 will
    /// not run on the GPU** - Blender wants 4.3 and reports "Unsupported
    /// hardware" on the GPU while running fine on the CPU. So this helps
    /// apps that stay at 4.1 or below (many games, Chromium's GL, older
    /// CAD) and should be left off for anything that needs more. It also
    /// needs `virgl_test_server` installed; without it this does nothing.
    public var gpuAcceleration = false

    /// Which round of shipped defaults this file has been brought up to.
    ///
    /// **Why a version is needed at all.** `save` writes every key, so a
    /// file written before a flag's default changed holds an explicit
    /// `false` for it - and changing the default in this struct then reaches
    /// nobody who has ever opened the Experimental Features window. The
    /// symptom is the worst kind: the release notes say a feature is on, and
    /// on the machines that matter it is off.
    ///
    /// So each promotion gets a generation, and `migrate` applies **only the
    /// flags that round promoted**, leaving every other stored value exactly
    /// as it is. That distinction matters: this Mac's file has
    /// `globalMenuBar: false` and `gpuAcceleration: true`, both deliberate,
    /// and a blanket "reset to defaults" would silently undo them.
    public var defaultsGeneration = MSLExperimentalSettings.currentGeneration

    /// 1: the original shipped set.
    /// 2: the keyboard and clipboard integration turned on (2026-09-30).
    /// 3: the global menu bar turned on (2026-09-30).
    public static let currentGeneration = 3

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
        guestClipboard = try c.decodeIfPresent(Bool.self, forKey: .guestClipboard) ?? defaults.guestClipboard
        // A key the file has never held decodes to the shipped default, so a
        // flag that is new *and* on needs no generation of its own - only one
        // whose default changes after people already have it stored.
        signInInLinuxBrowser = try c.decodeIfPresent(Bool.self, forKey: .signInInLinuxBrowser)
            ?? defaults.signInInLinuxBrowser
        omitPeripheralsPrompt = try c.decodeIfPresent(Bool.self, forKey: .omitPeripheralsPrompt) ?? defaults.omitPeripheralsPrompt
        nativeScaling = try c.decodeIfPresent(Bool.self, forKey: .nativeScaling) ?? defaults.nativeScaling
        retinaRendering = try c.decodeIfPresent(Bool.self, forKey: .retinaRendering) ?? defaults.retinaRendering
        gpuAcceleration = try c.decodeIfPresent(Bool.self, forKey: .gpuAcceleration) ?? defaults.gpuAcceleration
        reopenAppsAfterHibernate = try c.decodeIfPresent(Bool.self, forKey: .reopenAppsAfterHibernate)
            ?? defaults.reopenAppsAfterHibernate
        // A file with no generation predates the idea, so it is generation 1.
        defaultsGeneration = try c.decodeIfPresent(Int.self, forKey: .defaultsGeneration) ?? 1
        migrate()
    }

    /// Brings an older file up to the current round of shipped defaults.
    ///
    /// Touches only the flags each generation promoted. Anything the person
    /// has set for themselves on any other flag survives untouched - see
    /// `defaultsGeneration`.
    private mutating func migrate() {
        if defaultsGeneration < 2 {
            // Generation 2: the Mac keyboard reaching Linux apps, and the
            // clipboard that makes it worth having. All four were off only
            // because they were new, not because they were risky - and the
            // two things that made them risky are handled now (macOS keeps
            // its own shortcuts, terminals get Ctrl+Shift).
            linuxShortcuts = true
            macTextNavigation = true
            screenshotKeys = true
            guestClipboard = true
        }
        if defaultsGeneration < 3 {
            // Generation 3: Linux app menus in the Mac menu bar. It is what
            // makes a Linux window a window rather than a window with a menu
            // bar drawn inside it, and `MenuBarFitting` handles the thing
            // that used to make it risky - more menus than fit before a
            // MacBook's notch.
            globalMenuBar = true
        }
        defaultsGeneration = Self.currentGeneration
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
        loadIfReadable(from: url) ?? MSLExperimentalSettings()
    }

    /// The settings, or `nil` when a file exists but could not be read.
    ///
    /// **The difference matters, and losing it cost real settings.** `load`
    /// answers "no file" and "I could not read the file" with the same
    /// shipped defaults. Anything that then *writes* what it loaded turns a
    /// transient read failure into permanent data loss - and
    /// `ExperimentalFeaturesModel.reload()` does exactly that, because
    /// assigning `settings` saves. It happened on 2026-09-30: the app was
    /// replaced on disk under a running copy, a read failed mid-swap, and
    /// the person's deliberate `globalMenuBar` and `gpuAcceleration` choices
    /// were overwritten with defaults.
    ///
    /// So a reader that might write back asks this instead, and does nothing
    /// on `nil`. A missing file still returns defaults - that is a real
    /// answer, not a failure.
    public static func loadIfReadable(from url: URL = fileURL) -> MSLExperimentalSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MSLExperimentalSettings()
        }
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(MSLExperimentalSettings.self, from: data)
        else { return nil }
        return settings
    }

    /// Which MSLAP capability governs each switch.
    ///
    /// Settings are app-wide, so none of these take an instance. A switch
    /// with no entry here is not something a policy can restrict - the
    /// catalogue has no capability for it, and inventing one would be a
    /// promise with nothing behind it.
    static let capabilityForSetting: [(String, (MSLExperimentalSettings) -> Bool)] = [
        ("integrations.shortcuts", { $0.linuxShortcuts }),
        ("integrations.shortcuts", { $0.macTextNavigation }),
        ("integrations.shortcuts", { $0.screenshotKeys }),
        ("integrations.linksToMac", { $0.openLinksOnMac }),
        ("sharing.filePicker", { $0.preferMSLFiles }),
        ("integrations.globalMenuBar", { $0.globalMenuBar }),
        ("sharing.clipboard", { $0.guestClipboard }),
        ("integrations.signInBrowser", { $0.signInInLinuxBrowser }),
        ("graphics.scaling", { $0.nativeScaling }),
        ("graphics.scaling", { $0.retinaRendering }),
        ("graphics.gpu", { $0.gpuAcceleration }),
    ]

    public static func save(_ settings: MSLExperimentalSettings, to url: URL = fileURL) throws {
        // MSLAP, per switch rather than per file. Refusing the whole save
        // because one restricted switch moved would silently discard every
        // other change the person made in the same panel; refusing only
        // the restricted ones keeps the rest working, which is what an
        // administrator denying `sharing.clipboard` actually means.
        //
        // Only CHANGES are checked - a policy arriving after a switch was
        // already on must not make saving anything else impossible.
        var settings = settings
        if MSLAPGate.policy != nil {
            let current = load(from: url)
            for (capability, read) in capabilityForSetting
            where read(settings) != read(current)
                && !MSLAPGate.allows(capability, instance: nil) {
                settings = Self.reverting(settings, toward: current, capability: capability)
            }
        }
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

extension MSLExperimentalSettingsStore {
    /// Puts back every switch governed by one capability, leaving the rest
    /// of the save alone.
    static func reverting(_ settings: MSLExperimentalSettings,
                          toward current: MSLExperimentalSettings,
                          capability: String) -> MSLExperimentalSettings {
        var result = settings
        switch capability {
        case "integrations.shortcuts":
            result.linuxShortcuts = current.linuxShortcuts
            result.macTextNavigation = current.macTextNavigation
            result.screenshotKeys = current.screenshotKeys
            result.optionKeyMode = current.optionKeyMode
        case "integrations.linksToMac": result.openLinksOnMac = current.openLinksOnMac
        case "sharing.filePicker": result.preferMSLFiles = current.preferMSLFiles
        case "integrations.globalMenuBar": result.globalMenuBar = current.globalMenuBar
        case "sharing.clipboard": result.guestClipboard = current.guestClipboard
        case "integrations.signInBrowser": result.signInInLinuxBrowser = current.signInInLinuxBrowser
        case "graphics.scaling":
            result.nativeScaling = current.nativeScaling
            result.retinaRendering = current.retinaRendering
        case "graphics.gpu": result.gpuAcceleration = current.gpuAcceleration
        default: break
        }
        return result
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
