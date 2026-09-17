import MSLCore
import SwiftUI

/// A live view of what MSL is actually doing.
///
/// Be clear about what this is and isn't. It shows **MSL's own traffic** —
/// the control commands, the file bridge, X11 connections, VM lifecycle —
/// all of which happen on the host and are therefore genuinely observable
/// from here. It is not a packet capture: the guest's own outbound
/// connections live inside the VM's network stack, and seeing those needs
/// `ss`/`netstat` running in the guest, which needs a rebuilt image.
///
/// The empty state says so, rather than showing an empty list that reads as
/// "nothing is happening."
struct TrafficMonitorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let instance: Instance

    /// Two genuinely different sources, so they are two views rather than
    /// one merged list: `.msl` is what crosses the host and is always
    /// observable; `.guest` is what the guest's own kernel reports and needs
    /// `trafficd` in the image.
    private enum Lane: String, CaseIterable, Identifiable {
        case msl = "MSL activity"
        case guest = "Guest connections"
        var id: String { rawValue }
    }

    @State private var lane: Lane = .msl
    @State private var showProcesses = true
    @State private var hideLoopback = true
    @State private var events: [ActivityEvent] = []
    @State private var categories: Set<ActivityEvent.Category> = Set(ActivityEvent.Category.allCases)
    @State private var thisInstanceOnly = true
    @State private var paused = false
    @State private var everSawAnything = false

    /// Poll rather than watch the file. A dispatch source on a file that is
    /// rewritten by `trim()` needs re-arming, and at one read a second of a
    /// file capped at half a megabyte, the simpler thing is also the
    /// cheaper thing to get right.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var visible: [ActivityEvent] {
        events.filter { event in
            guard categories.contains(event.category) else { return false }
            guard thisInstanceOnly else { return true }
            // Events with no instance (daemon-wide) always show: they are
            // things like "service started", which are context, not noise.
            return event.instance == nil || event.instance == instance.name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $lane) {
                ForEach(Lane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Spacing.medium)
            .padding(.top, Design.Spacing.small)
            Divider().padding(.top, Design.Spacing.small)
            if lane == .msl { filters } else { guestFilters }
            Divider()
            if lane == .msl { content } else { guestContent }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 520)
        .onAppear {
            ActivityLog.beginWatching()
            ActivityLog.shared.record(.sandbox, instance: instance.name, "Traffic monitor opened")
            reload()
        }
        .onDisappear { ActivityLog.endWatching() }
        .onReceive(tick) { _ in
            guard !paused else { return }
            if lane == .msl {
                reload()
            } else {
                // Process attribution walks every fd of every process in the
                // guest, so it is only requested when it is being displayed.
                model.refreshGuestTraffic(instance, attributeProcesses: showProcesses)
            }
        }
        .onChange(of: lane) { newLane in
            if newLane == .guest { model.refreshGuestTraffic(instance, attributeProcesses: showProcesses) }
        }
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Traffic Monitor").font(.headline)
                Text(instance.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(paused ? "Resume" : "Pause") { paused.toggle() }
            Button("Clear") { ActivityLog.clear(); events = [] }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(Design.Spacing.medium)
    }

    private var filters: some View {
        HStack(spacing: Design.Spacing.small) {
            ForEach(ActivityEvent.Category.allCases, id: \.self) { category in
                let on = categories.contains(category)
                Button {
                    if on { categories.remove(category) } else { categories.insert(category) }
                } label: {
                    Label(category.title, systemImage: category.symbol)
                        .font(.caption)
                        .padding(.horizontal, Design.Spacing.small)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(on ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.12)))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Toggle("This instance only", isOn: $thisInstanceOnly)
                .toggleStyle(.checkbox).font(.caption)
        }
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, Design.Spacing.small)
    }

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(visible.reversed()) { event in
                    EventRow(event: event)
                        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                }
                .listStyle(.inset)
                .onChange(of: visible.count) { _ in
                    if !paused, let newest = visible.last { proxy.scrollTo(newest.id, anchor: .top) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Design.Spacing.small) {
            Spacer()
            Image(systemName: "wave.3.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(everSawAnything ? "Nothing matches those filters" : "Listening…")
                .font(.headline)
            Text(everSawAnything
                 ? "Try turning a category back on."
                 : "Start the instance, open a file, or launch an app and it will show up here.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
            Text("This is MSL's own traffic — control commands, the file bridge, X11 and VM "
                 + "lifecycle. It is not a packet capture: the guest's outbound connections "
                 + "live inside the VM's own network stack, which needs tools in a rebuilt "
                 + "guest image to see.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("\(visible.count) shown")
                .font(.caption2).foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(Design.Spacing.medium)
    }

    // MARK: - Guest lane

    private var guestFilters: some View {
        HStack(spacing: Design.Spacing.medium) {
            Toggle("Show processes", isOn: $showProcesses)
                .toggleStyle(.checkbox).font(.caption)
                .help("Asks the guest to match each socket to the process that owns it. "
                      + "That means walking every open file of every process, so it is off "
                      + "the wire unless it is on screen.")
            Toggle("Hide loopback", isOn: $hideLoopback)
                .toggleStyle(.checkbox).font(.caption)
                .help("Connections that never leave the guest.")
            Spacer()
        }
        .padding(.horizontal, Design.Spacing.medium)
        .padding(.vertical, Design.Spacing.small)
    }

    @ViewBuilder
    private var guestContent: some View {
        switch model.guestTraffic(for: instance) {
        case .idle:
            centeredNote(symbol: "hourglass", title: "Asking the guest…", detail: nil)
        case .notRunning:
            centeredNote(symbol: "moon.zzz",
                         title: "\(instance.name) isn't running",
                         detail: "A guest that isn't up has no sockets to report. MSL "
                               + "deliberately won't start it just to look - that would change "
                               + "the thing you're trying to observe.")
        case .unavailable:
            centeredNote(symbol: "shippingbox",
                         title: "This image can't answer yet",
                         detail: "Seeing the guest's own connections needs `trafficd` running "
                               + "inside it, which every current image predates. It's installed "
                               + "by the provisioner in Linux-Side/ and arrives with the "
                               + "rebuilt images.")
        case .failed(let message):
            centeredNote(symbol: "exclamationmark.triangle", title: "Couldn't read the guest", detail: message)
        case .loaded(let connections):
            let shown = connections.filter { !hideLoopback || !$0.isLoopback }
            if shown.isEmpty {
                centeredNote(symbol: "checkmark.circle",
                             title: hideLoopback ? "No connections leaving the guest" : "No sockets",
                             detail: hideLoopback && !connections.isEmpty
                                 ? "\(connections.count) loopback socket(s) hidden."
                                 : nil)
            } else {
                List(shown) { ConnectionRow(connection: $0) }
                    .listStyle(.inset)
            }
        }
    }

    private func centeredNote(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: Design.Spacing.small) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        events = ActivityLog.read()
        if !events.isEmpty { everSawAnything = true }
    }
}

private struct EventRow: View {
    let event: ActivityEvent

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text(Self.clock.string(from: event.at))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: event.category.symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Design.Spacing.tight) {
                    Text(event.summary).font(.callout)
                    if event.repeatCount > 1 {
                        Text("×\(event.repeatCount)")
                            .font(.caption2).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                if let detail = event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let instance = event.instance {
                Text(instance).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }

    private var tint: Color {
        switch event.category {
        case .control:   return .blue
        case .file:      return .green
        case .display:   return .purple
        case .lifecycle: return .orange
        case .sandbox:   return .red
        }
    }
}

/// One guest socket.
///
/// A listening socket is shown differently from a connected one on purpose:
/// "listening on 0.0.0.0:22" and "connected to 0.0.0.0:0" are very
/// different facts and the raw fields make them look alike.
private struct ConnectionRow: View {
    let connection: TrafficProtocol.Connection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            Text(connection.proto == .tcp ? "TCP" : "UDP")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            if connection.isListening {
                Text("listening on")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(connection.localAddress):\(connection.localPort)")
                    .font(.system(.callout, design: .monospaced))
            } else {
                Text("\(connection.localAddress):\(connection.localPort)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text("\(connection.remoteAddress):\(connection.remotePort)")
                    .font(.system(.callout, design: .monospaced))
            }

            Spacer(minLength: Design.Spacing.small)

            if !connection.processName.isEmpty {
                Text(connection.processName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(connection.stateName)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(connection.isListening ? Color.green : .secondary)
        }
        .textSelection(.enabled)
    }
}
