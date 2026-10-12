import SwiftUI
import MSLCore

/// The MSL Admin Portal panel.
///
/// Two audiences in one window. The person using a managed Mac needs to
/// know what is restricted, who did it and why - a locked-down tool that
/// will not say why it refused is the thing people hate most about managed
/// machines. An administrator needs the resolved view and the document
/// itself.
///
/// Everything here is read-only. Changing a policy means signing it, which
/// needs a key the panel deliberately does not handle: `msl admin sign`
/// and `msl admin enrol` are separate, explicit acts.
struct AdminPortalWindow: View {
    @State private var state: MSLAPPolicyStore.Result = .unmanaged
    @State private var instanceFilter: String = ""
    @State private var showingDocument = false
    @State private var documentText = ""
    /// Three modes rather than two: not set up, locked, unlocked. A Mac
    /// that has never been set up should offer setup, not a password box
    /// for a password that does not exist.
    @State private var unlocked = false
    @State private var settingUp = false
    @State private var showUnlock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch state {
            case .unmanaged:
                unmanaged
            case .broken(let failure, let fallback):
                broken(failure, fallback: fallback)
            case .managed(let loaded):
                managed(loaded)
            }
        }
        .frame(minWidth: 620, minHeight: 540)
        .onAppear(perform: reload)
        .sheet(isPresented: $settingUp) {
            AdminPortalSetup {
                settingUp = false
                unlocked = true
                reload()
            }
            .frame(width: 560, height: 620)
        }
        .sheet(isPresented: $showUnlock) {
            AdminPortalUnlock {
                showUnlock = false
                unlocked = true
            }
            .frame(width: 420)
        }
    }

    private func reload() {
        state = MSLAPPolicyStore.load()
        if case .managed(let loaded) = state,
           let data = try? Data(contentsOf: loaded.url),
           let text = String(data: data, encoding: .utf8) {
            documentText = text
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MSL Admin Portal").font(.title2).bold()
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            // A policy can withhold the editing view itself, for a
            // deployment where changes come from the fleet rather than
            // from whoever is at the keyboard. Reading stays open.
            if MSLAPAdminPassword.isSet, !unlocked,
               MSLAPGate.allows("admin.editPolicy", instance: nil) {
                Button("Administrator…") { unlocked = false; settingUp = false; showUnlock = true }
            }
            if !MSLAPAdminPassword.isSet,
               MSLAPGate.allows("admin.editPolicy", instance: nil) {
                Button("Set Up…") { settingUp = true }
            }
            Button("Reload", action: reload)
        }
        .padding(Design.Spacing.large)
    }

    private var subtitle: String {
        switch state {
        case .unmanaged: return "This Mac is not managed"
        case .broken: return "A policy is installed but is not in force"
        case .managed(let loaded): return "Managed · \(loaded.strength.title)"
        }
    }

    // MARK: - States

    private var unmanaged: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Label("Nothing is restricted", systemImage: "checkmark.seal")
                    .font(.headline)
                Text("No policy is installed, so every part of MSL works normally. "
                     + "An administrator can install one to restrict what this Mac "
                     + "is allowed to change.")
                    .foregroundStyle(.secondary)
                Text("\(MSLAPCapability.catalogue.count) capabilities could be restricted.")
                    .font(.caption).foregroundStyle(.secondary)
                commandHint("msl admin capabilities")
                if MSLAPAdminPassword.isSet {
                    Divider()
                    if unlocked {
                        Text("Choose what to restrict below, then Sign & Apply.")
                            .font(.callout)
                    } else {
                        Button("Administrator…") { showUnlock = true }
                    }
                } else {
                    Divider()
                    Button("Set Up the Admin Portal…") { settingUp = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Spacing.large)
            if unlocked {
                Divider()
                AdminPortalEditor(existing: nil) { reload() }
                    .frame(minHeight: 360)
            }
        }
    }

    private func broken(_ failure: MSLAPPolicyStore.Failure,
                        fallback: MSLAPPolicy?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Label("This policy is not in force", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(failureDetail(failure))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let fallback {
                    // Tampering must never read as "restrictions lifted".
                    let denied = MSLAPCapability.catalogue.filter { !fallback.allows($0.capability) }
                    Divider()
                    Text("Still enforcing the last policy that verified")
                        .font(.headline)
                    Text("\(denied.count) capabilit\(denied.count == 1 ? "y" : "ies") "
                         + "remain denied\(fallback.issuer.map { ", set by \($0)" } ?? "").")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Spacing.large)
        }
    }

    private func failureDetail(_ failure: MSLAPPolicyStore.Failure) -> String {
        switch failure {
        case .none: return ""
        case .unreadable(let path): return "Cannot read \(path)."
        case .malformed(let path, let detail): return "\(path) is not a valid policy.\n\n\(detail)"
        case .schemaTooNew(let path, let schema):
            return "\(path) uses schema \(schema); this version of MSL understands "
                 + "\(MSLAPPolicy.currentSchema)."
        case .needsNewerMSL(let path, let required):
            return "\(path) requires MSL \(required); this is \(MSLVersion.marketing)."
        case .signatureInvalid(let path, let detail):
            return "\(path) failed its signature check.\n\n\(detail)"
        }
    }

    private func managed(_ loaded: MSLAPPolicyStore.Loaded) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            provenance(loaded)
            Divider()
            Picker("", selection: $showingDocument) {
                Text("What is restricted").tag(false)
                Text("The policy").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Spacing.large)
            .padding(.vertical, Design.Spacing.small)
            Divider()
            if unlocked {
                AdminPortalEditor(existing: loaded.policy) { reload() }
            } else if showingDocument {
                document
            } else {
                resolved(loaded.policy)
            }
        }
    }

    private func provenance(_ loaded: MSLAPPolicyStore.Loaded) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            if let message = loaded.policy.message {
                Text(message).font(.callout)
            }
            HStack(spacing: Design.Spacing.medium) {
                if let issuer = loaded.policy.issuer {
                    labelled("Set by", issuer)
                }
                labelled("Strength", loaded.strength.title)
                labelled("Signature", signatureSummary(loaded))
            }
            // The blunt sentence, never softened: somebody deploys on it.
            Text(loaded.strength.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if unlocked { publicKeyRow }
            if loaded.signatureValid == true, MSLAPKeyStore.isLocalAdminMode {
                Text("The signing key is on this Mac, so anyone with administrator "
                     + "access here can re-sign a policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Spacing.large)
    }

    /// Copies the PUBLIC key, which is the half an administrator actually
    /// needs to move: pinning it on another Mac makes that Mac trust
    /// policies signed here. The private half stays in /Users/Shared/MSL
    /// and the app never offers it - a button that writes a signing key
    /// somewhere convenient is a button that eventually writes it
    /// somewhere shared.
    private var publicKeyRow: some View {
        let keys = MSLAPKeyStore.pinned().sorted { $0.key < $1.key }
        return Group {
            if let (id, key) = keys.first {
                HStack(spacing: Design.Spacing.small) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Signing key \(id)").font(.caption)
                        Text("Copy the public key to trust this signer on another Mac.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy Public Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            key.rawRepresentation.base64EncodedString(), forType: .string)
                    }
                    Button("Copy Pin Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "msl admin pin \(key.rawRepresentation.base64EncodedString())",
                            forType: .string)
                    }
                }
            }
        }
    }

    private func signatureSummary(_ loaded: MSLAPPolicyStore.Loaded) -> String {
        if let id = loaded.signedBy { return "valid · \(id)" }
        if loaded.signatureProblem != nil { return "unverified" }
        return "none"
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
        }
    }

    // MARK: - The resolved view

    private func resolved(_ policy: MSLAPPolicy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Instance name (blank for application-wide)", text: $instanceFilter)
                    .textFieldStyle(.roundedBorder)
                Text("rules can name one instance")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Design.Spacing.large)
            .padding(.vertical, Design.Spacing.small)

            List {
                let instance = instanceFilter.trimmingCharacters(in: .whitespaces)
                ForEach(MSLAPCapability.groups, id: \.self) { group in
                    let entries = MSLAPCapability.catalogue
                        .filter { $0.capability.key.hasPrefix(group + ".") }
                    Section(group) {
                        ForEach(entries, id: \.capability) { entry in
                            row(entry, policy: policy,
                                instance: instance.isEmpty ? nil : instance)
                        }
                    }
                }
                if !policy.unknownCapabilities.isEmpty {
                    Section("Ignored") {
                        // Named rather than hidden: a policy written for a
                        // newer MSL must not look like it is in force.
                        ForEach(policy.unknownCapabilities, id: \.self) { capability in
                            Text(capability.key)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("This version of MSL does not know these names, so they do nothing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ entry: MSLAPCapability.Entry,
                     policy: MSLAPPolicy, instance: String?) -> some View {
        let decision = policy.decision(for: entry.capability, instance: instance)
        return HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            Image(systemName: decision.allowed ? "checkmark.circle" : "nosign")
                .foregroundStyle(decision.allowed ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                Text(entry.capability.key)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if !decision.allowed {
                    // Why, and by which rule - the whole reason the panel
                    // exists for the managed user.
                    if let why = Self.explanation(for: decision, entry: entry) {
                        Text(why).font(.caption).foregroundStyle(.orange)
                    }
                    if entry.unavailable {
                        // Not a gap: MSL has no such action, so there is
                        // nothing a policy could refuse.
                        Text("no such action in this version")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if !entry.enforced {
                        Text("listed, not yet enforced")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(entry.tier.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// Why this was refused, in one line: the broader rule that actually
    /// did it, and the administrator's own reason if they gave one.
    static func explanation(for decision: MSLAPPolicy.Decision,
                            entry: MSLAPCapability.Entry) -> String? {
        var parts: [String] = []
        if let by = decision.deniedByCapability, by != entry.capability {
            parts.append("denied by \(by.key)")
        }
        if let reason = decision.deniedBy?.reason { parts.append(reason) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - The document

    private var document: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            ScrollView {
                Text(documentText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Spacing.medium)
            }
            // Read-only on purpose: editing a signed policy breaks its
            // signature, and re-signing needs a key this panel does not
            // hold. Changing a policy is a deliberate act at the command
            // line.
            Text("Read-only. Editing a signed policy breaks its signature - "
                 + "change it with `msl admin sign` and `msl admin enrol`.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Design.Spacing.large)
                .padding(.bottom, Design.Spacing.medium)
        }
    }

    private func commandHint(_ command: String) -> some View {
        HStack(spacing: Design.Spacing.small) {
            Text(command).font(.caption.monospaced())
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(Design.Spacing.small)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }
}
