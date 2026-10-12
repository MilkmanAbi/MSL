import MSLCore
import SwiftUI

/// Who answers this instance's name lookups.
///
/// The honest framing is the whole design of this card. Changing DNS hides
/// what the guest looks up from whoever runs the local network, and from the
/// default resolver handed out by DHCP. It hides nothing from this Mac:
/// every packet still leaves through it. A privacy control that lets someone
/// believe otherwise is worse than no control, so the claim is written on the
/// card rather than left to be inferred.
///
/// What it reports is what the guest says, read back after every change (see
/// `GuestDNS.Reading`), and never what was last asked for: on Debian and
/// Ubuntu those differ, because systemd-resolved keeps `/etc/resolv.conf`
/// pointing at its own stub.
struct PrivacyCard: View {
    let instance: Instance

    @State private var reading: GuestDNS.Reading?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Card(title: "Name lookups", footnote: footnote) {
            if !instance.isLive {
                Label("Start \(instance.name) to see or change this.", systemImage: "play.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                content
            }
        }
        .task(id: instance.name) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(spacing: Design.Spacing.medium) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentLine).font(.body)
                    Text(sourceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.Spacing.medium)
                if working { ProgressView().controlSize(.small) }
            }

            Picker("Resolver", selection: selection) {
                ForEach(GuestDNS.Choice.offered, id: \.name) { choice in
                    Text(label(for: choice)).tag(choice.name)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(working)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The picker shows what the guest reports, so a change made from `msl
    /// dns` or inside the guest shows up here rather than being overwritten
    /// by whatever this view last set.
    private var selection: Binding<String> {
        Binding(get: { matchedChoice.name },
                set: { name in
                    guard let choice = GuestDNS.Choice.offered.first(where: { $0.name == name }),
                          choice != matchedChoice
                    else { return }
                    apply(choice)
                })
    }

    private var matchedChoice: GuestDNS.Choice {
        guard let reading, !reading.servers.isEmpty else { return .automatic }
        // A known set only counts when the guest is really using it: the
        // first address matching is enough, since these providers' pairs
        // always travel together.
        for choice in GuestDNS.Choice.offered where !choice.servers.isEmpty {
            if choice.servers.contains(where: { reading.servers.contains($0) }) { return choice }
        }
        return .automatic
    }

    private func label(for choice: GuestDNS.Choice) -> String {
        choice.servers.isEmpty ? "Automatic" : choice.name
    }

    private var currentLine: String {
        guard let reading, !reading.servers.isEmpty else {
            return "\(instance.name) uses whatever DNS it is handed"
        }
        return "Resolving with \(reading.servers.joined(separator: ", "))"
    }

    private var sourceLine: String {
        switch reading?.source {
        case .resolved:
            return "Read back from systemd-resolved in the guest."
        case .configured:
            return "Set by MSL. The guest has not confirmed it yet, so it may still be starting up."
        case .resolvConf:
            return "Read back from /etc/resolv.conf in the guest."
        case .stubOnly:
            return "A local stub answers first and forwards somewhere this can't see, which is the distro's own default."
        case .unknown, .none:
            return "Nothing in the guest says which resolver it uses."
        }
    }

    private var footnote: String {
        "Hides what this instance looks up from your local network and its default resolver. It does not hide anything from this Mac: traffic still leaves through it, and the Mac's own DNS is untouched."
    }

    private func load() async {
        guard instance.isLive else { return }
        let name = instance.name, distro = instance.distro
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<GuestDNS.Reading, Error> in
            do { return .success(try GuestDNS.read(instance: name, distro: distro)) }
            catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let value): reading = value; error = nil
        case .failure(let failure): error = "Couldn't ask \(name): \(failure)"
        }
    }

    private func apply(_ choice: GuestDNS.Choice) {
        working = true
        error = nil
        let name = instance.name, distro = instance.distro
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Bool, Error> in
                do { return .success(try GuestDNS.apply(choice, instance: name, distro: distro)) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let ok):
                if !ok { error = "\(name) didn't take the change." }
            case .failure(let failure):
                error = "Couldn't change it: \(failure)"
            }
            // Always read back, even after a failure: the card must show
            // what the guest has, not what this view hoped for.
            await load()
            working = false
        }
    }
}
