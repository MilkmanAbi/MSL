import MSLCore
import SwiftUI

/// What the Applications list is currently showing.
///
/// Pulled out of the view so the toolbar can say, in one line, whether any
/// filtering is on - a filter you cannot see is a filter that makes an app
/// look missing.
struct AppFilter: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name"
        case source = "Where it came from"
        var id: String { rawValue }
    }

    var source: AppSource?
    /// Only apps that already have a macOS app in ~/Applications.
    var installedOnly = false
    /// Only apps pinned to the Dock.
    var pinnedOnly = false
    var sort: Sort = .name

    static let none = AppFilter()
    var isActive: Bool { self != .none }

    /// How many choices differ from the default, for the toolbar badge.
    var activeCount: Int {
        var count = 0
        if source != nil { count += 1 }
        if installedOnly { count += 1 }
        if pinnedOnly { count += 1 }
        if sort != .name { count += 1 }
        return count
    }

    /// A short phrase for the toolbar, so the state is legible without
    /// opening the popover.
    var summary: String? {
        guard isActive else { return nil }
        var parts: [String] = []
        if let source { parts.append(source.label) }
        if installedOnly { parts.append("In Applications") }
        if pinnedOnly { parts.append("Pinned") }
        if sort != .name { parts.append("by \(sort.rawValue.lowercased())") }
        return parts.joined(separator: " · ")
    }
}

/// The Filter popover.
///
/// Replaces a row of segmented chips that grew with every packaging system
/// MSL learned about, pushing the search field into a corner. Everything
/// that narrows the list now lives behind one button, and the button says
/// when something is on.
struct AppFilterPopover: View {
    @Binding var filter: AppFilter
    /// Only the packaging systems this instance actually has.
    let availableSources: [AppSource]
    /// How many apps each source has, so the choice is informative rather
    /// than a guess.
    let counts: [AppSource: Int]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            header

            section("Where it came from") {
                sourceRow(nil, label: "All", count: total)
                ForEach(availableSources, id: \.self) { source in
                    sourceRow(source, label: source.label, count: counts[source] ?? 0)
                }
            }

            if !availableSources.isEmpty { Divider() }

            section("Show only") {
                Toggle("Apps in your Applications folder", isOn: $filter.installedOnly)
                Toggle("Apps pinned to the Dock", isOn: $filter.pinnedOnly)
            }

            Divider()

            section("Sort by") {
                Picker("", selection: $filter.sort) {
                    ForEach(AppFilter.Sort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 260)
    }

    private var header: some View {
        HStack {
            Text("Filter").font(.headline)
            Spacer()
            Button("Reset") { filter = .none }
                .buttonStyle(.link)
                .disabled(!filter.isActive)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// A row rather than a `Picker`: the count belongs next to each choice,
    /// and "Flatpak 2" answers the question people actually have when the
    /// same app is listed twice.
    private func sourceRow(_ source: AppSource?, label: String, count: Int) -> some View {
        Button {
            filter.source = source
        } label: {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: filter.source == source ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(filter.source == source ? Color.accentColor : .secondary)
                    .imageScale(.small)
                Text(label)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
