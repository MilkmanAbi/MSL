import AppKit
import SwiftUI

/// MSL Files' look is two layers, the way a good theme system is:
///
/// 1. **Appearance** (`FilesAppearance`) - the universal base: follow the
///    system, or force Light, Dark or Darker. It sets the window's own
///    `NSAppearance`, so every control, sheet and menu in the window agrees.
/// 2. **Highlight** (`FilesTheme`) - a colour layered on top of whichever base
///    is active: the accent for selection and controls, a companion for small
///    marks. Sakura is as at home on Light as on Darker.
///
/// Plus one switch, `tintFolderArea`, that carries a duller, quieter version of
/// the highlight into the folder area itself - a wash behind the files and
/// folders drawn in the theme's colour. Purely cosmetic; nothing here changes
/// behaviour.
enum FilesAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, darker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .darker: return "Darker"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .darker: return "moon.stars"
        }
    }

    /// The colour scheme SwiftUI should use, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .darker: return .dark
        }
    }

    /// The window appearance to force, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .darker: return NSAppearance(named: .darkAqua)
        }
    }

    static func load() -> FilesAppearance {
        FilesAppearance(rawValue: UserDefaults.standard.string(forKey: "files.appearance") ?? "") ?? .system
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: "files.appearance") }
}

/// The highlight layer. `finder` leaves the system accent alone.
enum FilesTheme: String, CaseIterable, Identifiable {
    case finder, mslNeon, sakura, cyan, ocean, lavender, mint, gruvbox, tango

    var id: String { rawValue }

    var label: String {
        switch self {
        case .finder: return "Finder"
        case .mslNeon: return "MSL Neon"
        case .sakura: return "Sakura"
        case .cyan: return "Cyan"
        case .ocean: return "Ocean Breeze"
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        case .gruvbox: return "Gruvbox"
        case .tango: return "Tango"
        }
    }

    var blurb: String {
        switch self {
        case .finder: return "System accent"
        case .mslNeon: return "Pink & cyan"
        case .sakura: return "Cherry blossom"
        case .cyan: return "Cool cyan"
        case .ocean: return "Teal & deep blue"
        case .lavender: return "Soft violet"
        case .mint: return "Fresh green"
        case .gruvbox: return "Warm retro"
        case .tango: return "Classic Linux"
        }
    }

    // Two colours per theme: the accent (the star) and a companion.
    private var accentHex: UInt32? {
        switch self {
        case .finder: return nil
        case .mslNeon: return 0xFF8FB8
        case .sakura: return 0xEC7FA9
        case .cyan: return 0x22B8CF
        case .ocean: return 0x2A9D8F
        case .lavender: return 0x9B8AFB
        case .mint: return 0x3CC795
        case .gruvbox: return 0xD79921
        case .tango: return 0x3465A4
        }
    }
    private var companionHex: UInt32? {
        switch self {
        case .finder: return nil
        case .mslNeon: return 0x6BD9DB
        case .sakura: return 0xB57EDC
        case .cyan: return 0x66D9E8
        case .ocean: return 0x5FA8D3
        case .lavender: return 0xE3A6F0
        case .mint: return 0x7FD1D8
        case .gruvbox: return 0x98971A
        case .tango: return 0x4E9A06
        }
    }

    /// The accent: selection, focused controls, sort arrows. nil = system.
    var accent: Color? { accentHex.map(Color.init(hex:)) }

    /// Secondary marks - usage bars, badges.
    var companion: Color { companionHex.map(Color.init(hex:)) ?? accent ?? .accentColor }

    /// The colour hand-drawn selection fills use, so the theme reaches the
    /// icon, column and gallery views and not only what `.tint()` covers.
    var selection: Color { accent ?? .accentColor }

    /// Group-header text: a dimmed companion under a theme, plain secondary
    /// under Finder.
    var headerText: Color { self == .finder ? .secondary : companion.opacity(0.85) }

    /// The duller version of the highlight, for the folder area: the accent
    /// pulled a third of the way to grey, so a whole window of it stays calm.
    var muted: Color {
        let base = NSColor(selection)
        return Color(nsColor: base.blended(withFraction: 0.35, of: .systemGray) ?? base)
    }

    var headerGradient: LinearGradient {
        LinearGradient(colors: [selection.opacity(0.6), companion.opacity(0.5)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func load() -> FilesTheme {
        FilesTheme(rawValue: UserDefaults.standard.string(forKey: "files.theme") ?? "") ?? .finder
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: "files.theme") }
}

extension Color {
    /// A Color from a 0xRRGGBB literal, sRGB.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Environment

/// When the folder area is tinted, the colour folders are drawn in. nil means
/// "draw the system folder icon" - the default.
private struct FolderTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

/// Whether the file views should drop their own opaque background so the
/// window's backdrop (Darker, or the tinted wash) shows through.
private struct CustomBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var filesFolderTint: Color? {
        get { self[FolderTintKey.self] }
        set { self[FolderTintKey.self] = newValue }
    }
    var filesCustomBackdrop: Bool {
        get { self[CustomBackdropKey.self] }
        set { self[CustomBackdropKey.self] = newValue }
    }
}

// MARK: - Folder-area backdrop

/// What sits behind the files when the look asks for more than the system
/// background: the deep surface Darker uses, and/or the quiet wash of the
/// highlight colour when the folder area is tinted. Draws nothing otherwise,
/// so the default look is untouched.
struct FolderBackdrop: View {
    @ObservedObject var files: FilesModel
    @Environment(\.colorScheme) private var scheme

    static let darkerSurface = Color(white: 0.075)
    static let darkerSidebar = Color(white: 0.105)

    var body: some View {
        if files.usesCustomBackdrop {
            ZStack {
                if files.appearance == .darker {
                    Self.darkerSurface
                } else {
                    // What a list normally paints, so tint-only still reads as
                    // the usual surface - just coloured.
                    Color(nsColor: .textBackgroundColor)
                }
                if files.tintFolderArea {
                    LinearGradient(
                        colors: [files.theme.muted.opacity(scheme == .dark ? 0.16 : 0.12),
                                 files.theme.muted.opacity(scheme == .dark ? 0.06 : 0.04)],
                        startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

// MARK: - Window appearance

/// Keeps the hosting window's `NSAppearance` in step with the chosen base.
///
/// Light and Dark are driven by `.preferredColorScheme`, because SwiftUI owns
/// the appearance of windows it manages and re-applies its own over anything
/// set directly (setting the window alone left "Light" dark). What SwiftUI
/// won't do is *return* to following the system once it has forced a scheme,
/// so this probe clears the window's appearance for System - after SwiftUI's
/// own update, hence the hop to the next run-loop turn.
struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.appearanceToApply = appearance
        view.apply()
    }

    final class Probe: NSView {
        var appearanceToApply: NSAppearance?
        override func viewDidMoveToWindow() { apply() }
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if window.appearance?.name != self.appearanceToApply?.name {
                    window.appearance = self.appearanceToApply
                }
            }
        }
    }
}

// MARK: - Pickers

/// The paintbrush menu in the toolbar: appearance, highlight, and the
/// folder-area tint, in one place.
struct ThemePicker: View {
    @ObservedObject var files: FilesModel

    var body: some View {
        Menu {
            Picker("Appearance", selection: $files.appearance) {
                ForEach(FilesAppearance.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Highlight", selection: $files.theme) {
                ForEach(FilesTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Tint the Folder Area", isOn: $files.tintFolderArea)
        } label: {
            Image(systemName: "paintbrush")
        }
        .help("Appearance & theme")
    }
}

/// The dashboard's fuller version: appearance as a segmented control, the
/// highlights as swatch cards, and the folder-tint switch.
struct ThemeGallery: View {
    @ObservedObject var files: FilesModel

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Appearance", selection: $files.appearance) {
                ForEach(FilesAppearance.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(FilesTheme.allCases) { option in
                    Button { files.theme = option } label: { card(option) }
                        .buttonStyle(.plain)
                }
            }

            Toggle(isOn: $files.tintFolderArea) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tint the folder area")
                    Text("A quieter version of the highlight behind your files, with folders in its colour.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func card(_ option: FilesTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                option.selection
                option.companion
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(option.label).font(.caption.weight(.medium)).lineLimit(1)
            Text(option.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(option == files.theme ? option.selection : .clear, lineWidth: 2))
    }
}
