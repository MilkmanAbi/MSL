import MSLCore
import SwiftUI

// MARK: - Sidebar button

struct ExperimentalFeaturesButton: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = ExperimentalFeaturesModel()

    var body: some View {
        Button {
            openWindow(id: "experimental")
        } label: {
            HStack {
                Label("Experimental Features", systemImage: "flask")
                Spacer()
                if model.enabledCount > 0 {
                    Text("\(model.enabledCount) on")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, Design.Spacing.small + 2)
        // The window writes the file; the badge re-reads it when the app
        // comes back to the front rather than sharing a model across scenes.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: ExperimentalFeaturesModel.didSave)) { _ in
            model.reload()
        }
    }
}

// MARK: - Window

struct ExperimentalFeaturesWindow: View {
    @StateObject private var model = ExperimentalFeaturesModel()

    var body: some View {
        ExperimentalFeaturesPanel(model: model)
            .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 720)
    }
}

// MARK: - Model

@MainActor
final class ExperimentalFeaturesModel: ObservableObject {
    static let didSave = Notification.Name("MSLExperimentalFeaturesDidSave")

    @Published var settings: MSLExperimentalSettings {
        didSet { if settings != oldValue { save() } }
    }
    @Published private(set) var saveError: String?
    @Published private(set) var keyboard: X11MacKeyboardInfo?

    /// Where this model reads and writes. Injectable for one reason: a test
    /// that builds this model **writes the real settings file**, because
    /// assigning `settings` saves.
    ///
    /// `CardRenderingTests` did exactly that - it flipped two flags to make
    /// the snapshot show its change-badges, and every `swift test` run
    /// quietly rewrote the settings of whoever ran it. Two values that looked
    /// like deliberate choices on a real machine turned out to be this
    /// (found 2026-09-30). A test must point this somewhere disposable.
    private let storeURL: URL

    init(storeURL: URL = MSLExperimentalSettingsStore.fileURL) {
        self.storeURL = storeURL
        settings = MSLExperimentalSettingsStore.load(from: storeURL)
    }

    var enabledCount: Int {
        [settings.linuxShortcuts, settings.macTextNavigation, settings.screenshotKeys,
         settings.openLinksOnMac, settings.preferMSLFiles, settings.globalMenuBar,
         settings.guestClipboard, settings.signInInLinuxBrowser,
         settings.omitPeripheralsPrompt, settings.nativeScaling,
         settings.retinaRendering, settings.gpuAcceleration].filter { $0 }.count
            + (settings.optionKeyMode == .leftAltRightAltGr ? 0 : 1)
    }

    var isAtDefaults: Bool { settings == MSLExperimentalSettings() }

    func reload() {
        // `loadIfReadable`, not `load`: assigning `settings` saves, so a
        // failed read would write the shipped defaults over whatever the
        // person had chosen. That is not hypothetical - it happened while
        // the app bundle was being replaced under a running copy, and took
        // two deliberate settings with it.
        guard let loaded = MSLExperimentalSettingsStore.loadIfReadable(from: storeURL) else { return }
        if loaded != settings { settings = loaded }
    }

    func refreshKeyboard() {
        keyboard = X11MacKeyboard.currentInfo()
    }

    func reset() {
        settings = MSLExperimentalSettings()
    }

    func copyKeyboardReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(X11MacKeyboard.report(optionMode: settings.optionKeyMode, keysyms: true), forType: .string)
    }

    func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func save() {
        do {
            try MSLExperimentalSettingsStore.save(settings, to: storeURL)
            saveError = nil
            NotificationCenter.default.post(name: Self.didSave, object: nil)
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Flag metadata

/// Which part of MSL a flag belongs to. The grouping people scan by.
enum FlagSubsystem: String, CaseIterable {
    case mslgd = "mslgd"        // the display server: how Linux windows look and take input
    case mslps = "mslps"        // peripherals: the Mac's hardware for Linux apps
    case msl = "MSL"            // the app itself: how Linux and the Mac meet

    var title: String {
        switch self {
        case .mslgd: return "Graphics & input (mslgd)"
        case .mslps: return "Peripherals (mslps)"
        case .msl: return "Mac integration (MSL)"
        }
    }

    var caption: String {
        switch self {
        case .mslgd: return "The display server behind every Linux window - how they're drawn, scaled, and how your keyboard and pointer reach them."
        case .mslps: return "The Mac's own hardware - camera, microphone, sound - offered to Linux apps."
        case .msl: return "Where Linux and macOS meet: links, files, the clipboard, the menu bar."
        }
    }

    var symbol: String {
        switch self {
        case .mslgd: return "display"
        case .mslps: return "camera"
        case .msl: return "macwindow.on.rectangle"
        }
    }
}

/// When a change takes effect. The mini-tag chrome://flags-style badge.
enum FlagApplies {
    case live          // reaches apps already open, within about a second
    case newApps       // applies to Linux apps launched after the change
    case restart       // needs the Linux instance restarted

    var label: String {
        switch self {
        case .live: return "Live"
        case .newApps: return "New apps"
        case .restart: return "Restart"
        }
    }

    var help: String {
        switch self {
        case .live: return "Takes effect on Linux apps that are already open, within about a second."
        case .newApps: return "Takes effect on Linux apps you open after changing it. Apps already open keep their old setting until relaunched."
        case .restart: return "Needs the Linux instance restarted before it takes effect."
        }
    }

    var color: Color {
        switch self {
        case .live: return .green
        case .newApps: return .blue
        case .restart: return .orange
        }
    }
}

/// One switchable feature, described declaratively so the window can render,
/// search and group them uniformly - the chrome://flags model.
struct FlagDescriptor: Identifiable {
    let id: String
    let title: String
    let detail: String
    let subsystem: FlagSubsystem
    let applies: FlagApplies
    let defaultOn: Bool
    /// Extra words to match in search beyond the title and detail.
    let keywords: [String]
    /// Small before/after chips, when a feature reads well as examples.
    let examples: [(String, String)]
    /// A warning shown under the description, for a feature that is on by
    /// default but reaches far enough into other software that it can go
    /// wrong in ways MSL cannot fix from its side. Says what to do about it,
    /// not just that a risk exists.
    let caution: String?
    /// The flag this row drives. A key path (Sendable) rather than a captured
    /// closure, so the catalog stays a plain `static let` without dragging
    /// main-actor state into it; the `Binding` is built at the view layer.
    let keyPath: WritableKeyPath<MSLExperimentalSettings, Bool>

    init(id: String, title: String, detail: String, subsystem: FlagSubsystem,
         applies: FlagApplies, defaultOn: Bool = false, keywords: [String] = [],
         examples: [(String, String)] = [], caution: String? = nil,
         keyPath: WritableKeyPath<MSLExperimentalSettings, Bool>) {
        self.id = id
        self.title = title
        self.detail = detail
        self.subsystem = subsystem
        self.applies = applies
        self.defaultOn = defaultOn
        self.keywords = keywords
        self.examples = examples
        self.caution = caution
        self.keyPath = keyPath
    }

    func matches(_ query: String) -> Bool {
        FlagSearch.matches(query, in: [id, title, detail, subsystem.rawValue, subsystem.title, applies.label] + keywords)
    }
}

/// Shared "does this row match the search box" rule, so the two things that
/// aren't `FlagDescriptor`s - the Option-key picker and the keyboard readout -
/// search the same way the flags do.
enum FlagSearch {
    static func matches(_ query: String, in terms: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = terms.joined(separator: " ").lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

/// The whole catalog, in the order people read it within each group.
enum FlagCatalog {
    static let all: [FlagDescriptor] = [
        // --- mslgd -------------------------------------------------------
        FlagDescriptor(
            id: "gpuAcceleration",
            title: "GPU acceleration for OpenGL",
            detail: "Render Linux OpenGL on the Mac's real GPU through Metal, instead of on the CPU. Helps apps that stay at OpenGL 4.1 or below - Chromium's GL, many games, older CAD. \u{26A0} Anything needing newer OpenGL will NOT run on the GPU: it caps at 4.1, while the CPU path (the default) offers 4.5, so Blender and similar are better left on the CPU. Needs the host renderer installed; without it, apps quietly stay on the CPU.",
            subsystem: .mslgd, applies: .restart,
            keywords: ["opengl", "gl", "gpu", "metal", "virgl", "blender", "chromium", "3d", "graphics", "accelerat"],
            keyPath: \.gpuAcceleration),
        FlagDescriptor(
            id: "nativeScaling",
            title: "Native scaling",
            detail: "Draw Linux windows closer to the Mac's own UI size, rather than one X pixel per point. Off by default because one-to-one is what every app has been tested at; some apps lay out better than others when scaled.",
            subsystem: .mslgd, applies: .newApps,
            keywords: ["scale", "hidpi", "retina", "size", "dpi", "resolution"],
            keyPath: \.nativeScaling),
        FlagDescriptor(
            id: "retinaRendering",
            title: "Retina rendering",
            detail: "Draw Linux windows at your Mac's real pixel density, so text and icons are as sharp as the Mac's own. Each X pixel becomes one physical pixel on a Retina screen, instead of being stretched across four. \u{26A0} An app draws four times the pixels and every one crosses the X11 connection, so expect it to cost speed - most on big windows and software rendering. Wins over Native scaling when both are on.",
            subsystem: .mslgd, applies: .newApps, defaultOn: true,
            keywords: ["scale", "hidpi", "retina", "sharp", "crisp", "dpi", "192", "density", "resolution", "blurry"],
            keyPath: \.retinaRendering),
        FlagDescriptor(
            id: "linuxShortcuts",
            title: "Mac shortcuts in Linux apps",
            detail: "Press \u{2318}C, \u{2318}V, \u{2318}Z and the rest and have Linux apps see the Ctrl-key shortcuts they expect. Without this, a Mac's \u{2318} does nothing in most Linux apps. macOS keeps its own: \u{2318}Q, \u{2318}H, \u{2318}M, \u{2318}\u{0060} and anything with \u{2303}\u{2318} still do what they do everywhere else. In a terminal these arrive as Ctrl+Shift instead, so \u{2318}C copies rather than interrupting whatever is running. On by default.",
            subsystem: .mslgd, applies: .live, defaultOn: true,
            keywords: ["cmd", "command", "copy", "paste", "ctrl", "keyboard", "hotkey",
                       "shortcut", "keymap", "native", "terminal"],
            examples: [("\u{2318}C", "Ctrl+C"), ("\u{2318}Z", "Ctrl+Z"), ("\u{2318}C in a terminal", "Ctrl+Shift+C")],
            keyPath: \.linuxShortcuts),
        FlagDescriptor(
            id: "macTextNavigation",
            title: "Mac text navigation",
            detail: "\u{2318}\u{2190} to the start of a line, \u{2325}\u{2190} a word at a time, and the other Mac text moves, translated to what Linux text fields understand.",
            subsystem: .mslgd, applies: .live, defaultOn: true,
            keywords: ["text", "cursor", "home", "end", "word", "editing", "navigation", "keymap"],
            examples: [("\u{2318}\u{2190}", "Home"), ("\u{2325}\u{2192}", "Ctrl+\u{2192}")],
            keyPath: \.macTextNavigation),
        FlagDescriptor(
            id: "screenshotKeys",
            title: "Let Linux apps see screenshot keys",
            detail: "Send \u{21E7}\u{2318}3 and \u{21E7}\u{2318}4 through to Linux apps instead of macOS taking them. macOS keeps these for its own screenshots unless you also turn them off under Keyboard Shortcuts \u{203A} Screenshots.",
            subsystem: .mslgd, applies: .live, defaultOn: true,
            keywords: ["screenshot", "screen", "capture", "grab", "print"],
            keyPath: \.screenshotKeys),
        // --- mslps -------------------------------------------------------
        FlagDescriptor(
            id: "omitPeripheralsPrompt",
            title: "Skip the camera & mic prompt",
            detail: "Linux apps get the Mac's camera and microphone the moment they open them, without MSL Peripherals asking first. Right for ROS2 and anything that starts camera nodes over and over; wrong if you'd rather be asked. macOS's own permission is still asked once, and the camera light and mic indicator still show whenever something is capturing.",
            subsystem: .mslps, applies: .live,
            keywords: ["camera", "microphone", "mic", "permission", "prompt", "ros2", "webcam", "privacy"],
            keyPath: \.omitPeripheralsPrompt),
        // --- MSL ---------------------------------------------------------
        FlagDescriptor(
            id: "openLinksOnMac",
            title: "Open links & email on the Mac",
            detail: "A web link or mailto in a Linux app opens in your Mac's browser and mail app, not a Linux one. On by default - it's almost always what you want.",
            subsystem: .msl, applies: .newApps, defaultOn: true,
            keywords: ["link", "url", "browser", "mail", "email", "http", "open"],
            keyPath: \.openLinksOnMac),
        FlagDescriptor(
            id: "preferMSLFiles",
            title: "Set MSL Files as the default file browser for Linux",
            detail: "Linux apps use MSL Files instead of a Linux file manager: opening a folder or \"show in folder\" opens MSL Files, and an app's Open/Save dialog becomes MSL Files too - which can see your Mac's disk as well as the guest's. Off sends both back to Linux (Nautilus, Dolphin, or the app's own dialog). On by default.",
            subsystem: .msl, applies: .newApps, defaultOn: true,
            keywords: ["files", "folder", "finder", "file manager", "reveal", "nautilus",
                       "save as", "open", "dialog", "picker", "chooser", "portal",
                       "default", "browser"],
            caution: "Reaches into how each toolkit finds its file dialog, so it can misbehave in apps MSL hasn't met. If an app's Open or Save starts acting strangely, turn this off - everything goes back to that app's own dialog.",
            keyPath: \.preferMSLFiles),
        FlagDescriptor(
            id: "signInInLinuxBrowser",
            title: "Sign-in pages open in Linux",
            detail: "When a Linux app sends you to sign in - Zoom, Discord, Slack, anything using a \u{201C}sign in with\u{201D} button - that one page opens in the guest's own browser instead of your Mac's. Everything else still opens on your Mac. It has to work this way: a sign-in hands its answer back to the machine that started it, so done on your Mac the answer arrives on your Mac and the Linux app waits forever. Needs a browser installed in the instance; without one the link goes to your Mac as before.",
            subsystem: .msl, applies: .newApps, defaultOn: true,
            keywords: ["sign in", "signin", "login", "oauth", "account", "browser", "zoom", "discord",
                       "slack", "authorise", "authorize", "redirect", "callback"],
            examples: [("An ordinary link", "your Mac"), ("A sign-in page", "Linux")],
            caution: "New, and it decides by reading the link. A page that looks like a sign-in but isn't will open in the guest's browser instead of yours - turn this off if that happens and tell us which link it was.",
            keyPath: \.signInInLinuxBrowser),
        FlagDescriptor(
            id: "guestClipboard",
            title: "Shared clipboard",
            detail: "Copy in a Linux app and paste on the Mac, and the other way around - text and images, and files through MSL Files. On by default. X11's select-to-copy (PRIMARY) is not bridged, so xterm and old Motif apps still keep their selection to themselves.",
            subsystem: .msl, applies: .live, defaultOn: true,
            keywords: ["clipboard", "copy", "paste", "pasteboard", "cut"],
            keyPath: \.guestClipboard),
        FlagDescriptor(
            id: "globalMenuBar",
            title: "Linux menus in the Mac menu bar",
            detail: "A Linux app's menus (File, Edit, \u{2026}) appear in the Mac's menu bar at the top of the screen, the way a Mac app's do, read over D-Bus - so the window is just the window, not a window with a menu bar drawn inside it. On by default. When there are more menus than fit before the notch, MenuBarFitting keeps what fits and tucks the rest behind one final menu. Not every toolkit exports its menus.",
            subsystem: .msl, applies: .newApps, defaultOn: true,
            keywords: ["menu", "menubar", "global", "dbus", "appmenu", "gtk", "qt"],
            keyPath: \.globalMenuBar),
    ]

    static func grouped(matching query: String) -> [(FlagSubsystem, [FlagDescriptor])] {
        FlagSubsystem.allCases.compactMap { subsystem in
            let flags = all.filter { $0.subsystem == subsystem && $0.matches(query) }
            return flags.isEmpty ? nil : (subsystem, flags)
        }
    }
}

// MARK: - Panel

struct ExperimentalFeaturesPanel: View {
    @ObservedObject var model: ExperimentalFeaturesModel
    @State private var query = ""

    private var groups: [(FlagSubsystem, [FlagDescriptor])] { FlagCatalog.grouped(matching: query) }
    private var optionKeyMatches: Bool {
        FlagSearch.matches(query, in: ["option keys", "mslgd", "graphics input",
            "alt", "altgr", "special characters", "accent", "compose", "left", "right", "\u{00E9}"])
    }
    private var keyboardMatches: Bool {
        FlagSearch.matches(query, in: ["this mac's keyboard", "layout", "diagnostics", "source id"])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                scrollContent
                    .padding(Design.Spacing.large)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.refreshKeyboard() }
        .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in
            model.refreshKeyboard()
        }
    }

    /// The scrollable body, one call so it can be drawn on its own offscreen
    /// (`ImageRenderer` collapses a `ScrollView` to nothing - see
    /// `CardRenderingTests`).
    @ViewBuilder var scrollContent: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            ForEach(groups, id: \.0) { subsystem, flags in
                FlagGroup(subsystem: subsystem, flags: flags, model: model)
            }
            if optionKeyMatches { optionKeysCard }
            if keyboardMatches { keyboardCard }
            if groups.isEmpty, !optionKeyMatches, !keyboardMatches {
                emptyResults
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }

    // MARK: header + search

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Label("MSL Flags", systemImage: "flask").font(.title2.weight(.semibold))
                Spacer()
                if model.enabledCount > 0 {
                    Text("\(model.enabledCount) on")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Button("Reset all") { model.reset() }
                    .disabled(model.isAtDefaults)
            }
            Text("Experimental features, grouped by the part of MSL they change. They all work, but they're still settling - most start off. \u{201C}Experiments aren't promises\u{201D}: a future version of \(MSLVersion.display) may build one in, change it, or drop it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(Design.Spacing.large)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search flags", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private var emptyResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
            Text("No flags match \u{201C}\(query)\u{201D}").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: option keys (a picker, not a toggle)

    private var optionKeysCard: some View {
        FlagCard(subsystem: .mslgd, applies: .newApps, defaultOn: false,
                 isOn: model.settings.optionKeyMode != .leftAltRightAltGr) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Option keys").fontWeight(.medium)
                    Spacer()
                }
                Text("A Mac's Option key does two jobs a PC keyboard splits across two keys: it's Alt for shortcuts, and it types special characters like \u{00E9} and \u{2122}. Choose what each one does in Linux apps.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: Binding(
                    get: { model.settings.optionKeyMode },
                    set: { model.settings.optionKeyMode = $0 })) {
                    Text("Left is Alt, right types special characters (like a PC)").tag(X11OptionKeyMode.leftAltRightAltGr)
                    Text("Both are Alt").tag(X11OptionKeyMode.bothAlt)
                    Text("Both type special characters (like a Mac app)").tag(X11OptionKeyMode.bothAltGr)
                }
                .labelsHidden().pickerStyle(.radioGroup)
            }
        }
    }

    // MARK: keyboard diagnostics (info, not a flag)

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("This Mac's keyboard", systemImage: "keyboard").font(.headline)
                Spacer()
                Button("Copy report") { model.copyKeyboardReport() }.font(.caption)
                Button("Keyboard Settings\u{2026}") { model.openKeyboardShortcutsSettings() }.font(.caption)
            }
            Text("Linux apps follow your Mac's keyboard layout, and switch when you switch it.")
                .font(.callout).foregroundStyle(.secondary)
            if let keyboard = model.keyboard {
                VStack(alignment: .leading, spacing: 3) {
                    infoRow("Layout", keyboard.localizedName)
                    infoRow("Source ID", keyboard.inputSourceID)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(Design.Spacing.medium)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Group + card

private struct FlagGroup: View {
    let subsystem: FlagSubsystem
    let flags: [FlagDescriptor]
    @ObservedObject var model: ExperimentalFeaturesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: subsystem.symbol).foregroundStyle(.secondary)
                Text(subsystem.title).font(.headline)
            }
            Text(subsystem.caption)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(flags) { flag in
                let isOn = Binding(get: { model.settings[keyPath: flag.keyPath] },
                                   set: { model.settings[keyPath: flag.keyPath] = $0 })
                FlagCard(subsystem: flag.subsystem, applies: flag.applies, defaultOn: flag.defaultOn, isOn: isOn.wrappedValue) {
                    HStack(alignment: .top, spacing: Design.Spacing.medium) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(flag.title).fontWeight(.medium)
                            Text(flag.detail)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !flag.examples.isEmpty {
                                FlowingExamples(examples: flag.examples, active: isOn.wrappedValue)
                            }
                            // Only while the feature is on: a warning about
                            // something that is switched off is just noise.
                            if let caution = flag.caution, isOn.wrappedValue {
                                Label(caution, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }
}

/// The chrome://flags row: content plus the default/applies badges underneath.
private struct FlagCard<Content: View>: View {
    let subsystem: FlagSubsystem
    let applies: FlagApplies
    let defaultOn: Bool
    let isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            HStack(spacing: 6) {
                Badge(text: defaultOn ? "Default on" : "Default off",
                      color: defaultOn ? .green : .secondary, filled: false)
                Badge(text: applies.label, color: applies.color, filled: false, help: applies.help)
                if isOn != defaultOn {
                    Badge(text: isOn ? "On" : "Off", color: .orange, filled: true)
                }
            }
        }
        .padding(Design.Spacing.medium)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isOn != defaultOn ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1))
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var filled: Bool = false
    var help: String? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(filled ? 0.22 : 0.12)))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .help(help ?? "")
    }
}

/// Before-and-after chips for a feature, dimmed while it's off.
private struct FlowingExamples: View {
    let examples: [(String, String)]
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                HStack(spacing: 4) {
                    Text(example.0).font(.system(.caption, design: .rounded).weight(.semibold))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(example.1).font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
            }
        }
        .opacity(active ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}
