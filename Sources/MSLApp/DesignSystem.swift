import SwiftUI
import MSLCore

/// The small vocabulary the rest of the app is drawn from.
///
/// Kept in one place, and deliberately small: the look this is after
/// (calm, dense, monochrome with one accent) comes from using the *same*
/// six spacings and three text styles everywhere, far more than from any
/// individual flourish. Anything that starts inventing its own padding is
/// a sign something belongs here instead.
/// `VMManager.InstanceState` is what the daemon reports and what the whole
/// UI switches on; the nested spelling adds nothing at the call site.
typealias InstanceState = VMManager.InstanceState

enum Design {
    static let cornerRadius: CGFloat = 10
    static let tileCorner: CGFloat = 14

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 14
        static let large: CGFloat = 22
        static let section: CGFloat = 32
    }
}

/// The colour and symbol each distro is drawn with. A row that can be
/// identified at a glance, without reading it, is most of what makes a
/// list of a dozen distros feel like a product rather than a table.
extension GuestDistro {
    var displayName: String {
        switch self {
        case .alpine: return "Alpine"
        case .debian: return "Debian"
        case .ubuntu: return "Ubuntu"
        case .kali: return "Kali"
        case .arch: return "Arch"
        case .fedora: return "Fedora"
        case .rocky: return "Rocky"
        case .alma: return "AlmaLinux"
        case .centos: return "CentOS Stream"
        case .oracle: return "Oracle Linux"
        case .opensuse: return "openSUSE"
        case .nix: return "Nix"
        case .custom(let slug): return CustomImage.find(slug: slug)?.name ?? slug
        }
    }

    var tint: Color {
        switch self {
        case .alpine: return Color(red: 0.05, green: 0.45, blue: 0.75)
        case .debian: return Color(red: 0.79, green: 0.10, blue: 0.31)
        case .ubuntu: return Color(red: 0.90, green: 0.36, blue: 0.13)
        case .kali: return Color(red: 0.13, green: 0.36, blue: 0.80)
        case .arch: return Color(red: 0.09, green: 0.57, blue: 0.85)
        case .fedora: return Color(red: 0.20, green: 0.35, blue: 0.64)
        case .rocky: return Color(red: 0.06, green: 0.62, blue: 0.44)
        case .alma: return Color(red: 0.02, green: 0.49, blue: 0.56)
        case .centos: return Color(red: 0.55, green: 0.13, blue: 0.45)
        case .oracle: return Color(red: 0.78, green: 0.27, blue: 0.20)
        case .opensuse: return Color(red: 0.40, green: 0.66, blue: 0.13)
        case .nix: return Color(red: 0.32, green: 0.45, blue: 0.78)
        // The melon's own deep green: custom images are MSL's community
        // side, not any one distro's colour.
        case .custom: return Color(red: 0.36, green: 0.60, blue: 0.42)
        }
    }

    /// SF Symbols only - shipping real distro logos would mean vendoring a
    /// dozen differently-licensed trademarks into the repository.
    var symbol: String {
        switch self {
        case .alpine: return "mountain.2.fill"
        case .debian: return "circle.hexagongrid.fill"
        case .ubuntu: return "circle.circle.fill"
        case .kali: return "shield.lefthalf.filled"
        case .arch: return "triangle.fill"
        case .fedora: return "f.circle.fill"
        case .rocky: return "r.circle.fill"
        case .alma: return "a.circle.fill"
        case .centos: return "c.circle.fill"
        case .oracle: return "o.circle.fill"
        case .opensuse: return "lizard.fill"
        case .nix: return "snowflake"
        case .custom: return "shippingbox.fill"
        }
    }

    var blurb: String {
        switch self {
        case .alpine: return "Tiny and fast. The default."
        case .debian: return "Stable and familiar."
        case .ubuntu: return "Debian, with more batteries."
        case .kali: return "Debian, with security tooling."
        case .arch: return "Rolling release, current packages."
        case .fedora: return "Recent kernels and toolchains."
        case .rocky: return "Enterprise Linux, community-built."
        case .alma: return "Enterprise Linux, forever free."
        case .centos: return "Where Enterprise Linux is made."
        case .oracle: return "Enterprise Linux from Oracle."
        case .opensuse: return "SUSE's community release."
        case .nix: return "Nix packages on a Debian base."
        case .custom(let slug): return CustomImage.find(slug: slug)?.summary ?? "Your own image."
        }
    }
}

/// A small round badge with the distro's symbol - the thing that makes a
/// sidebar row scannable.
struct DistroBadge: View {
    let distro: GuestDistro
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(distro.tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: distro.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: distro.tint.opacity(0.25), radius: 2, y: 1)
    }
}

/// Running / paused / stopped, as a dot and a word. The dot alone carries
/// it in the sidebar; the word appears where there's room.
struct StateIndicator: View {
    let state: InstanceState
    var showsLabel = true

    var body: some View {
        HStack(spacing: Design.Spacing.tight + 2) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(color.opacity(0.28), lineWidth: 3).scaleEffect(1.9))
            if showsLabel {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .paused: return .orange
        case .transitioning: return .yellow
        case .stopped: return .secondary.opacity(0.6)
        }
    }
}

extension InstanceState {
    var label: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Suspended"
        case .transitioning: return "Starting…"
        case .stopped: return "Stopped"
        }
    }
}

/// A labelled row of the form "Memory       2 GB" - the whole Overview tab
/// is made of these.
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Design.Spacing.large)
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// A titled group of rows on a card. Used for every block in the detail
/// pane so they all share one shape and one inset.
struct Card<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            if let title {
                Text(title)
                    .font(.subheadline).bold()
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Design.Spacing.small + 2) {
                content
            }
            .padding(Design.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
