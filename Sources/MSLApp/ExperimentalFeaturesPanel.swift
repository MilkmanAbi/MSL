import AppKit
import MSLCore
import SwiftUI

/// In the sidebar, under Permissions & Startup: opens Experimental Features.
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

struct ExperimentalFeaturesWindow: View {
    @StateObject private var model = ExperimentalFeaturesModel()

    var body: some View {
        ScrollView {
            ExperimentalFeaturesPanel(model: model)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, minHeight: 520)
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

    init() {
        settings = MSLExperimentalSettingsStore.load()
    }

    var enabledCount: Int {
        [settings.linuxShortcuts, settings.macTextNavigation, settings.screenshotKeys,
         settings.openLinksOnMac, settings.preferMSLFiles, settings.globalMenuBar].filter { $0 }.count
            + (settings.optionKeyMode == .leftAltRightAltGr ? 0 : 1)
    }

    var isAtDefaults: Bool { settings == MSLExperimentalSettings() }

    func reload() {
        let loaded = MSLExperimentalSettingsStore.load()
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
            try MSLExperimentalSettingsStore.save(settings)
            saveError = nil
            NotificationCenter.default.post(name: Self.didSave, object: nil)
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Panel

struct ExperimentalFeaturesPanel: View {
    @ObservedObject var model: ExperimentalFeaturesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            header
            Divider()
            integrationSection
            Divider()
            menuBarSection
            Divider()
            shortcutsSection
            Divider()
            optionKeysSection
            Divider()
            keyboardSection
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(Design.Spacing.large)
        .onAppear { model.refreshKeyboard() }
        .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in
            model.refreshKeyboard()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Label("Experimental Features", systemImage: "flask").font(.title2.weight(.semibold))
                Spacer()
                Button("Reset to Defaults") { model.reset() }
                    .disabled(model.isAtDefaults)
            }
            Text("Every experiment in MSL lives here. They all work, but they're still settling: most start off, and a few that make Linux apps feel at home on a Mac start on. Changes reach Linux apps that are already open within a second, unless a feature says otherwise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Experiments aren't promises. A future version of MSL may build one in properly, change how it works, or remove it altogether, depending on what the community prefers - so the list here is specific to \(MSLVersion.display).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Design.Spacing.small + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        }
    }

    // MARK: Integration

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Linux apps and your Mac").font(.headline)

            integration(
                isOn: $model.settings.openLinksOnMac,
                title: "Open links on the Mac",
                defaultOn: true,
                detail: "Web links clicked in a Linux app open in your Mac's default browser instead of a Linux one, and email links open a new message in your Mac's mail app - with any attachments the Linux app added. Linux browsers still open when you start them yourself."
            )

            integration(
                isOn: $model.settings.preferMSLFiles,
                title: "Show folders in MSL Files",
                defaultOn: true,
                detail: "When a Linux app shows a folder - \"Open containing folder\", \"Show in Files\" - it opens in MSL Files on the Mac instead of a Linux file manager. Nautilus, Dolphin and the rest still run when you start them yourself."
            )

            note("Both apply to Linux apps started from MSL. When one is off, or the instance is sandboxed, the Linux app's own choice is used.")
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Mac menu bar").font(.headline)

            integration(
                isOn: $model.settings.globalMenuBar,
                title: "Linux app menus in the menu bar",
                defaultOn: false,
                detail: "A Linux app's File, Edit and other menus move out of its window and into the Mac menu bar, read over D-Bus. Qt and KDE apps support this on their own; GTK apps need the appmenu-gtk3-module package installed in the instance. Menu shortcuts keep working in the window, but aren't shown in the menu bar yet."
            )
            if model.settings.globalMenuBar {
                note("Applies to Linux apps opened after turning it on - quit and reopen any that are already running.")
            }
        }
    }

    private func integration(isOn: Binding<Bool>, title: String, defaultOn: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    Text(defaultOn ? "On by default" : "Off by default")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Mac shortcuts in Linux apps").font(.headline)

            feature(
                isOn: $model.settings.linuxShortcuts,
                title: "Use ⌘ shortcuts",
                detail: "Command+key reaches Linux apps as Control+key, so copy, paste, undo and save work the way your hands expect. Command stops being the Super key in those apps. ⌘Q, ⌘H, ⌘M and ⌘` still belong to macOS.",
                examples: [("⌘C", "Ctrl+C"), ("⌘V", "Ctrl+V"), ("⌘⇧Z", "Ctrl+Shift+Z"), ("⌘W", "Ctrl+W")]
            )

            feature(
                isOn: $model.settings.macTextNavigation,
                title: "Mac text navigation",
                detail: "Moving and deleting through text with ⌘ and ⌥ as on a Mac.",
                examples: [("⌘←", "Home"), ("⌘↑", "Ctrl+Home"), ("⌥←", "Ctrl+←"), ("⌘⌫", "delete to line start")]
            )

            feature(
                isOn: $model.settings.screenshotKeys,
                title: "Screenshot keys",
                detail: "The Mac screenshot shortcuts send the Linux ones, for apps with their own screenshot tools.",
                examples: [("⌘⇧3", "Print"), ("⌘⇧4", "Shift+Print"), ("⌘⇧5", "Alt+Print")]
            )
            if model.settings.screenshotKeys {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("macOS keeps these for its own screenshots unless you turn them off under Keyboard Shortcuts > Screenshots.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Keyboard Settings…") { model.openKeyboardShortcutsSettings() }
                        .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
    }

    private func feature(isOn: Binding<Bool>, title: String, detail: String, examples: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                Text(title).fontWeight(.medium)
            }
            .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowingExamples(examples: examples, active: isOn.wrappedValue)
            }
            .padding(.leading, 2)
        }
    }

    // MARK: Option keys

    private var optionKeysSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Option keys").font(.headline)
            Text("A Mac's Option key does two jobs a PC keyboard gives to two keys: it's Alt for shortcuts, and it types special characters like é and ™. Choose what each one is in Linux apps.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Option keys", selection: $model.settings.optionKeyMode) {
                Text("Left is Alt, right types special characters (like a PC)").tag(X11OptionKeyMode.leftAltRightAltGr)
                Text("Both are Alt").tag(X11OptionKeyMode.bothAlt)
                Text("Both type special characters (like a Mac app)").tag(X11OptionKeyMode.bothAltGr)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    // MARK: This Mac's keyboard

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("This Mac's keyboard").font(.headline)
                Spacer()
                Button("Copy Keymap Report") { model.copyKeyboardReport() }
                    .controlSize(.small)
                    .help("The detected layout and every key's symbols as Linux apps see them - useful when a key types the wrong thing.")
            }
            Text("Linux apps follow your Mac's keyboard layout, and switch when you switch it.")
                .font(.caption).foregroundStyle(.secondary)
            if let info = model.keyboard {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    infoRow("Layout", info.localizedName)
                    infoRow("Language", info.systemLanguages.first ?? "—")
                    infoRow("Keyboard", info.physicalLayout)
                    if !info.isASCIICapable {
                        infoRow("Shortcuts use", info.latinFallbackID?.replacingOccurrences(of: "com.apple.keylayout.", with: "") ?? "—")
                    }
                    infoRow("Key repeat", "\(info.repeatDelayMs) ms, then every \(info.repeatIntervalMs) ms")
                }
                .font(.callout)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
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
