import MSLCore
import SwiftUI

/// The switches for MSL's personality: the greeting line under the shell
/// banner, and the cat.
///
/// Shared with `msl greeter` and `msl kitty` through a file in Application
/// Support rather than `UserDefaults`, because the command line is a
/// different process with a different defaults domain, and the two must not
/// disagree about something the user just switched off.
struct PersonalitySection: View {
    @State private var settings = PersonalitySettingsStore.load()
    @State private var sample: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Greeters and kitty").font(.headline)
            Text("MSL says something silly at the top of every shell, and a cat can be the one saying it. Both are only there to be nice; turn them off whenever you like.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Greeting line in every shell", isOn: Binding(
                get: { settings.greeters },
                set: { settings.greeters = $0; save() }))
            Toggle("The cat in every shell", isOn: Binding(
                get: { settings.kitty },
                set: { settings.kitty = $0; save() }))

            preview
            if settings.greeters {
                Button("Show me another") { sample = Greeter.nextGreeting()?.text }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("Also: msl greeter on|off, msl kitty on|off, and msl kitty \"words\" to make her say something.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            settings = PersonalitySettingsStore.load()
            if sample == nil { sample = Greeter.nextGreeting()?.text }
        }
    }

    /// What a shell would open with, drawn rather than printed.
    ///
    /// The cat above, the greeting under her, in that order - the same
    /// arrangement `PersonalityBanner` prints, so what is shown here is what
    /// a shell opens with.
    ///
    /// The greeting is a plain `Text` rather than anything drawn in
    /// characters: a SwiftUI `Text` has no cell grid, and the kaomoji in a
    /// greeting fall back from the monospaced font to whatever has the
    /// glyph, with a different advance. Anything that relied on columns
    /// lining up would drift here however correct the string was. The cat
    /// herself is text art and stays monospaced - she is full-width
    /// throughout, so she lines up with herself.
    @ViewBuilder
    private var preview: some View {
        let line = settings.greeters ? sample : nil
        if settings.kitty || line != nil {
            VStack(alignment: .leading, spacing: 0) {
                if settings.kitty {
                    // Full-width characters throughout, so SwiftUI's default
                    // truncation cut her off mid-paw with an ellipsis. She is
                    // text art: she gets exactly the space she is drawn in.
                    Text(Kitty.art)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                        .accessibilityLabel("MSL's cat, drawn in text")
                }
                if let line {
                    Text(line)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, settings.kitty ? Design.Spacing.tight : 0)
                        .accessibilityLabel(settings.kitty
                            ? "The cat says: \(line)" : "MSL says: \(line)")
                }
            }
            .padding(.top, Design.Spacing.tight)
        } else {
            Text("Shells open with nothing extra.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.top, Design.Spacing.tight)
        }
    }

    private func save() {
        PersonalitySettingsStore.save(settings)
    }
}
