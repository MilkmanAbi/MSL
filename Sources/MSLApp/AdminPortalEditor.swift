import SwiftUI
import MSLCore

/// The unlocked admin view: toggle what is denied, then sign and install.
///
/// Editing happens here rather than in the JSON, and the JSON is shown
/// read-only beside it, because a signed policy that someone hand-edits
/// stops verifying - and the resulting "FAILED ITS SIGNATURE CHECK" looks
/// like an attack rather than a typo. Changing it through this view
/// re-signs every time, so that cannot happen by accident.
struct AdminPortalEditor: View {
    let existing: MSLAPPolicy?
    let onSaved: () -> Void

    @State private var issuer: String = ""
    @State private var message: String = ""
    @State private var scopeMatch: String = "*"
    @State private var reason: String = ""
    @State private var denied: Set<String> = []
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            Divider()
            capabilityList
            Divider()
            footer
        }
        .onAppear(perform: loadExisting)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                TextField("Issued by (shown to whoever uses this Mac)", text: $issuer)
                    .textFieldStyle(.roundedBorder)
                TextField("Applies to (* or an instance name, lab-* works)", text: $scopeMatch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            TextField("Message shown in the panel", text: $message)
                .textFieldStyle(.roundedBorder)
            TextField("Reason shown on each refusal", text: $reason)
                .textFieldStyle(.roundedBorder)
            // The reason is what the person actually reads when something
            // refuses them, so it is worth a nudge.
            Text("The reason appears in every refusal, including on the command line.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Design.Spacing.large)
    }

    private var capabilityList: some View {
        List {
            ForEach(MSLAPCapability.groups, id: \.self) { group in
                let entries = MSLAPCapability.catalogue
                    .filter { $0.capability.key.hasPrefix(group + ".") }
                Section {
                    ForEach(entries, id: \.capability) { entry in
                        Toggle(isOn: binding(for: entry.capability)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                Text(entry.capability.key)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                // Never let an administrator believe a
                                // switch does more than it does.
                                if entry.unavailable {
                                    Text("no such action in this version")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else if !entry.enforced {
                                    Text("listed, not yet enforced")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group)
                        Spacer()
                        Button("Deny all") { entries.forEach { denied.insert($0.capability.key) } }
                            .buttonStyle(.borderless).font(.caption)
                        Button("Allow all") { entries.forEach { denied.remove($0.capability.key) } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(failed ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("\(denied.count) denied")
                .font(.caption).foregroundStyle(.secondary)
            Button("Sign & Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(MSLAPKeyStore.localPrivateKey() == nil)
        }
        .padding(Design.Spacing.large)
    }

    private func binding(for capability: MSLAPCapability) -> Binding<Bool> {
        Binding(get: { denied.contains(capability.key) },
                set: { isOn in
                    if isOn { denied.insert(capability.key) } else { denied.remove(capability.key) }
                })
    }

    private func loadExisting() {
        guard let existing else { return }
        issuer = existing.issuer ?? ""
        message = existing.message ?? ""
        if let scope = existing.scopes.first {
            scopeMatch = scope.match
            reason = scope.reason ?? ""
        }
        denied = Set(existing.scopes.flatMap { $0.deny }.map(\.key))
    }

    private func apply() {
        guard let key = MSLAPKeyStore.localPrivateKey() else {
            status = "No signing key on this Mac. Run setup again."
            failed = true
            return
        }
        let policy = MSLAPPolicy(
            issued: Date(),
            issuer: issuer.isEmpty ? nil : issuer,
            scopes: denied.isEmpty ? [] : [
                .init(match: scopeMatch.isEmpty ? "*" : scopeMatch,
                      deny: denied.sorted().map(MSLAPCapability.init),
                      reason: reason.isEmpty ? nil : reason)
            ],
            message: message.isEmpty ? nil : message)
        do {
            let signed = try MSLAPSigning.sign(policy, with: key)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(signed)
            // The user-library path: writing to /Library needs sudo, which
            // belongs at a terminal rather than behind a button here. The
            // panel says which rung this leaves the deployment on.
            try FileManager.default.createDirectory(
                at: MSLAPPolicyStore.userURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: MSLAPPolicyStore.userURL, options: .atomic)
            failed = false
            status = "Signed and applied. For the enforceable rung, run: "
                   + "msl admin enrol \(MSLAPPolicyStore.userURL.path)"
            onSaved()
        } catch {
            failed = true
            status = "Could not apply: \(error.localizedDescription)"
        }
    }
}
