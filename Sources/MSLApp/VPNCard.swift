import AppKit
import MSLCore
import SwiftUI

/// The hide.me VPN client, inside one instance.
///
/// MSL installs the official client and says what it finds. It never asks
/// for an account, holds a token, or puts a Connect button on someone
/// else's service: logging in happens in the instance, with the user's own
/// credentials, and this card hands over the exact command rather than
/// pretending to be the client's UI.
///
/// The other half of being honest here is scope. This is a WireGuard tunnel
/// *inside that Linux*. The Mac's traffic does not go through it, and
/// neither does any other instance's, which a VPN switch sitting in a Mac
/// app otherwise implies.
struct VPNCard: View {
    let instance: Instance

    @State private var status: GuestVPN.Status?
    @State private var working = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Card(title: "VPN", footnote: footnote) {
            if !instance.isLive {
                Label("Start \(instance.name) to set this up.", systemImage: "play.circle")
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
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(status?.connected == true ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tint))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.body)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.Spacing.medium)
                if working { ProgressView().controlSize(.small) }
            }

            if let step = status?.nextStep(), let status, status.installed, status.wireGuard {
                // The command belongs to the client, not to MSL, so it is
                // shown as something to run rather than wrapped in a button
                // that would hide where the credentials go.
                HStack(spacing: Design.Spacing.small) {
                    Text(commandOnly(step))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    Button("Copy") { copy(commandOnly(step)) }
                        .buttonStyle(.link)
                }
            }

            HStack(spacing: Design.Spacing.small) {
                if status?.installed == true {
                    Button("Check again") { Task { await load() } }.disabled(working)
                    Button("Remove client") { remove() }.disabled(working)
                } else {
                    Button(working ? "Installing…" : "Install hide.me client") { install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || status?.wireGuard == false)
                }
            }

            if let message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        guard let status, status.installed else { return "lock.shield" }
        return status.connected ? "lock.shield.fill" : "lock.shield"
    }

    private var headline: String {
        guard let status else { return "Checking \(instance.name)…" }
        if status.connected { return "\(instance.name) is connected through a VPN tunnel" }
        if !status.installed { return "hide.me isn't installed in \(instance.name)" }
        if !status.hasToken { return "Installed, and waiting for you to log in" }
        return "Installed and logged in, not connected"
    }

    private var detail: String {
        guard let status else { return "" }
        if !status.wireGuard {
            return "This instance's kernel has no WireGuard support, so the client can't connect here."
        }
        return status.nextStep() ?? "Only this instance's traffic goes through the tunnel."
    }

    private var footnote: String {
        "Installs the official hide.me client (version \(GuestVPN.version), checked against a pinned checksum) into this instance. You log in with your own hide.me account, inside the instance. MSL never sees your credentials, and the tunnel covers this instance only, not your Mac."
    }

    /// The instruction text carries a sentence in front of the command;
    /// only the command is worth copying.
    private func commandOnly(_ step: String) -> String {
        guard let range = step.range(of: "sudo hide.me") else { return step }
        return String(step[range.lowerBound...])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func load() async {
        guard instance.isLive else { return }
        let name = instance.name, distro = instance.distro
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<GuestVPN.Status, Error> in
            do { return .success(try GuestVPN.status(instance: name, distro: distro)) }
            catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let value): status = value; error = nil
        case .failure(let failure): error = "Couldn't ask \(name): \(failure)"
        }
    }

    private func install() {
        working = true
        message = nil
        error = nil
        let name = instance.name, distro = instance.distro
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<GuestVPN.InstallResult, Error> in
                do { return .success(try GuestVPN.install(instance: name, distro: distro)) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let result):
                if result == .installed { message = result.message } else { error = result.message }
            case .failure(let failure):
                error = "Install failed: \(failure)"
            }
            await load()
            working = false
        }
    }

    private func remove() {
        working = true
        message = nil
        error = nil
        let name = instance.name, distro = instance.distro
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
                do { try GuestVPN.remove(instance: name, distro: distro); return nil }
                catch { return error }
            }.value
            if let failure { error = "Couldn't remove it: \(failure)" } else { message = "Removed from \(name)." }
            await load()
            working = false
        }
    }
}
