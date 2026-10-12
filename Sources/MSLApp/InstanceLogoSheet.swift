import AppKit
import MSLCore
import SwiftUI

/// Picking the badge one instance wears.
///
/// MSL drew every instance as its distro's symbol in its distro's colour,
/// which is right until you have four Debians: the sidebar reads as four
/// identical rows and the name is the only thing telling them apart. A logo
/// you chose is faster to find than a name you read.
///
/// Opened by clicking the badge itself - in the sidebar or in the Instance
/// view's header - because that is the thing being changed, and the Mac has
/// taught everybody that clicking an icon is how you change an icon.
///
/// **Reset to Default** and **Open…** sit at the top, above the choices, so
/// the two things with consequences are not buried under sixty symbols.
struct InstanceLogoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let instance: Instance

    private var appearance: InstanceAppearance { model.appearance(of: instance.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Scrolls because a short display shouldn't cut the colours off.
            // The cost is that `ImageRenderer` draws a ScrollView's content
            // as nothing, so `CardRenderingTests` renders `LogoChoices`
            // directly as well as the whole sheet - otherwise the only
            // offscreen proof of this panel is an empty rectangle.
            ScrollView {
                LogoChoices(instance: instance)
                    .padding(Design.Spacing.large)
            }
            Divider()
            footer
        }
        .frame(width: 468, height: 540)
    }

    // MARK: - Top

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(spacing: Design.Spacing.medium) {
                InstanceBadge(instance: instance, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name).font(.title2).bold()
                    Text(appearance.isDefault
                         ? "\(instance.distro.displayName) · its distro's badge"
                         : "\(instance.distro.displayName) · your badge")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: Design.Spacing.small) {
                Button("Open…") { chooseImage() }
                Button("Reset to Default") { model.setAppearance(InstanceAppearance(), for: instance.name) }
                    .disabled(appearance.isDefault)
                Spacer()
                if appearance.image != nil {
                    Button("Remove Picture") {
                        var next = appearance
                        next.image = nil
                        model.setAppearance(next, for: instance.name)
                    }
                }
            }
            Text(appearance.image == nil
                 ? "Open… uses a picture of your own. Or pick a faction and a colour below."
                 : "Your picture is showing. Remove it to go back to a faction symbol.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Design.Spacing.large)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Design.Spacing.medium)
    }

    // MARK: - A picture of your own

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Logo"
        panel.message = "A picture for \(instance.name). MSL copies it in and squares it off."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseLogoImage(url, for: instance.name)
    }
}

/// The faction and colour grids, on their own.
///
/// Separated from `InstanceLogoSheet` so they can be rendered - and so
/// looked at - without the `ScrollView` that `ImageRenderer` draws as an
/// empty rectangle. Seventy-two cells that nobody has ever seen laid out is
/// exactly the shape of bug `CardRenderingTests` was written for.
struct LogoChoices: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    private var appearance: InstanceAppearance { model.appearance(of: instance.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            factions
            colours
        }
    }


    private var factions: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Faction").font(.headline)
            // A picture covers the symbol entirely, so the grid is dimmed
            // rather than hidden - the choice underneath is still there when
            // the picture is removed.
            ForEach(InstanceAppearance.factions, id: \.name) { faction in
                VStack(alignment: .leading, spacing: Design.Spacing.tight + 2) {
                    Text(faction.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    grid(faction.symbols) { symbolButton($0) }
                }
            }
        }
        .opacity(appearance.image == nil ? 1 : 0.4)
        .disabled(appearance.image != nil)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let chosen = appearance.symbol == symbol
        return Button {
            var next = appearance
            // Clicking the one already chosen clears it, so there is a way
            // back to the distro's own symbol without resetting the colour.
            next.symbol = chosen ? nil : symbol
            model.setAppearance(next, for: instance.name)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(chosen ? currentTint.opacity(0.22) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(chosen ? currentTint : .clear, lineWidth: 2)
                )
                .foregroundStyle(chosen ? currentTint : .primary)
        }
        .buttonStyle(.plain)
        // No `.help(symbol)`: it showed the raw SF Symbol name, so hovering a
        // triangle said "triangle.fill". The picture is the label here, and
        // developer jargon in a tooltip is worse than no tooltip.
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Colour").font(.headline)
            grid(InstanceAppearance.palette) { colourButton($0) }
            Text("No colour chosen means \(instance.distro.displayName)'s own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func colourButton(_ hex: String) -> some View {
        let chosen = appearance.tint == hex
        return Button {
            var next = appearance
            next.tint = chosen ? nil : hex
            model.setAppearance(next, for: instance.name)
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(chosen ? 0.9 : 0.12),
                                lineWidth: chosen ? 2.5 : 1)
                )
                .overlay {
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Rows of twelve, built eagerly.
    ///
    /// Not a `LazyVGrid`: there are seventy-two cells in the whole sheet, so
    /// laziness buys nothing, and a lazy container draws *nothing at all*
    /// under `ImageRenderer` - which is how the offscreen render in
    /// `CardRenderingTests` showed this sheet as a header above an empty
    /// panel. A view that can't be rendered offscreen can't be checked
    /// without launching the app.
    private func grid<Item: Hashable>(_ items: [Item],
                                      @ViewBuilder cell: @escaping (Item) -> some View) -> some View {
        let rows = stride(from: 0, to: items.count, by: 12).map {
            Array(items[$0..<min($0 + 12, items.count)])
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { cell($0) }
                }
            }
        }
    }

    /// What the badge is actually tinted with right now - used to show the
    /// selection in the symbol grid, so the two choices read as one badge.
    private var currentTint: Color {
        appearance.tint.flatMap(Color.init(hex:)) ?? instance.distro.tint
    }

}
