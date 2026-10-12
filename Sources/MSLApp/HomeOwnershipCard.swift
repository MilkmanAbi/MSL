import MSLCore
import SwiftUI

/// Hands a Linux home directory back to the account that owns it.
///
/// Until MSL 2.0, every Linux app MSL launched ran as root, and those apps
/// wrote into the account's home anyway: `~/.config`, `~/.cache`, whole
/// project folders. Launching as the user (see `GuestUser`) stops it
/// happening again; this undoes what already happened.
///
/// It looks first and does nothing until asked, because "give every file in
/// your home to this account" deserves to be seen before it runs.
struct HomeOwnershipCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance

    @State private var report: HomeOwnership.Report?
    @State private var checking = false
    @State private var repairing = false
    @State private var repaired: Int?
    @State private var error: String?

    private var account: String? { GuestUser.forUserFacingWork(in: instance.name) }

    var body: some View {
        Card(title: "Home folder ownership", footnote: footnote) {
            if let account {
                content(account: account)
            } else {
                Text("\(instance.name) has no Linux account yet. Open it once and create your account first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func content(account: String) -> some View {
        if !instance.isLive {
            Label("Start \(instance.name) to check its home folder.", systemImage: "play.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let repaired {
            Label(repaired == 0 ? "Nothing needed changing." : "Handed \(repaired) file\(repaired == 1 ? "" : "s") back to \(account).",
                  systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        } else if let report, report.needsRepair {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("\(report.wrongCount) file\(report.wrongCount == 1 ? "" : "s") in \(report.home) don't belong to \(account). They were made by apps MSL used to run as root.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.samples.prefix(4), id: \.self) { sample in
                    Text(sample)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button(repairing ? "Handing them back…" : "Give them to \(account)") { repair() }
                    .buttonStyle(.borderedProminent)
                    .disabled(repairing)
            }
        } else if report != nil {
            Label("Everything in \(account)'s home belongs to \(account).", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: Design.Spacing.small) {
                Button(checking ? "Checking…" : "Check") { check() }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
        }

        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        "Older versions of MSL ran Linux apps as root, so files they made are owned by root and your account can't edit them. This gives them back. It only touches your account's home folder, and never the Mac files shared at /mnt/mac."
    }

    private func check() {
        checking = true
        error = nil
        let name = instance.name
        let distro = instance.distro
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HomeOwnership.Report?, Error> in
                do { return .success(try HomeOwnership.scan(instance: name, distro: distro)) }
                catch { return .failure(error) }
            }.value
            checking = false
            switch outcome {
            case .success(let found):
                report = found
                if found == nil { error = "Couldn't find that account's home folder in \(name)." }
            case .failure(let failure):
                error = "\(failure)"
            }
        }
    }

    private func repair() {
        repairing = true
        error = nil
        let name = instance.name
        let distro = instance.distro
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                do { return .success(try HomeOwnership.repair(instance: name, distro: distro)) }
                catch { return .failure(error) }
            }.value
            repairing = false
            switch outcome {
            case .success(let count): repaired = count
            case .failure(let failure): error = "\(failure)"
            }
        }
    }
}
