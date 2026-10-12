import SwiftUI
import MSLCore
import PublicMSL

/// Reaching an instance from outside this Mac.
///
/// A sibling of the SSH card rather than a tab of its own, because it is
/// the same question one step further out: that card answers "how do I get
/// in from here", this one answers "how does someone get in from
/// somewhere else". Sharing the shape means the second is read with what
/// the first already taught.
///
/// Two things this card refuses to do, both learned the hard way elsewhere
/// in MSL:
///
/// - **It never says "published" without an address that works.** A free
///   relay rotates its hostname about once an hour, so there is a real
///   window where the instance is published and momentarily unreachable.
///   That gets its own state and its own sentence, because showing the old
///   address would send somebody to a host that no longer resolves.
/// - **It does not offer a Copy button for a key that is not there.** The
///   private key sits in the Mac's temporary directory, out of reach of
///   every guest, and that directory is cleared on restart - so the command
///   can be exactly right while the key is gone.
struct PublicAccessCard: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var publicModel = PublicAccessModel()
    let instance: Instance

    @State private var copied: String?
    @State private var showingConfirm = false
    @State private var showingKeys = false
    @State private var pastedKey = ""
    @State private var pastedLabel = ""
    @State private var keyMessage: (ok: Bool, text: String)?
    @State private var showingNotify = false
    @State private var editingSetup = false
    @State private var apiKey = ""
    @State private var fromAddress = ""
    @State private var replyTo = ""
    @State private var testAddress = ""
    @State private var newEmail = ""
    @State private var newLabel = ""
    @State private var notifyMessage: (ok: Bool, text: String)?
    @State private var shareName = ""
    @State private var showingTips = false
    @State private var tipsPlatform: ConnectionTips.Platform = .windows

    private var isBusy: Bool { publicModel.busy.contains(instance.name) }

    var body: some View {
        Card(title: "Reach this from anywhere", footnote: footnote) {
            switch publicModel.state(for: instance.name) {
            case .off:                     offered
            case .working(let what):       working(what)
            case .live(let endpoint):      live(endpoint)
            case .pending(let reason):     pending(reason)
            case .failed(let message):     failure(message)
            }
        }
        .task(id: instance.name) {
            publicModel.loadKeys(instance.name)
            // **Polled, not fetched once.** A free relay rotates the
            // address about once an hour, so a card that asked once would
            // go on showing a dead host - and the `.pending` state written
            // for exactly that handover could never appear. Cancelled
            // automatically when the card goes away, so a window left on
            // another tab costs nothing.
            while !Task.isCancelled {
                publicModel.refresh(instance.name)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .confirmationDialog("Publish \(instance.name) to the internet?",
                            isPresented: $showingConfirm, titleVisibility: .visible) {
            Button("Publish \(instance.name)") {
                let token = publicModel.backendToken(for: instance.name)
                if token.isEmpty {
                    // Only possible for "your own server" with nothing
                    // filled in. Better to say so than to publish through
                    // a relay they did not pick.
                    publicModel.reportSetupNeeded(
                        instance.name,
                        "Fill in your server as you@host:port first - "
                        + "open the settings under \"Email the address to someone\".")
                } else {
                    publicModel.publish(instance.name, backend: token)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Its SSH port becomes reachable from anywhere. Anyone with the address can \
            try to log in, so MSL turns password logins off first - only keys will work.

            Worth knowing: your Mac's home folder is inside every instance at /mnt/mac, \
            with write access. Anyone you let in has that too, so this shares those files \
            and not only the Linux machine.

            You can stop it at any time, and MSL puts the SSH server back as it was.
            """)
        }
        .sheet(isPresented: $showingKeys) {
            keysSheet.task { publicModel.refreshTailnet() }
        }
        .sheet(isPresented: $showingNotify) { notifySheet }
        .sheet(isPresented: $showingTips) { tipsSheet }
    }

    private var footnote: String? {
        switch publicModel.state(for: instance.name) {
        case .live(let endpoint) where endpoint.expires != nil:
            return "A free relay carries this, so the address is temporary. For one that "
                + "stays put, publish through a server you own - see msl public expose --via."
        case .off:
            return "MSL turns password logins off before publishing anything, and only keys "
                + "you allow can log in."
        default:
            return nil
        }
    }

    // MARK: - Not published

    private var offered: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Only reachable from this Mac")
                Text("Publish it and you get an address that works from another computer, "
                     + "another network, anywhere - useful for a small always-on server.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Spacing.small)
            Button("Publish…") { showingConfirm = true }
                .disabled(instance.state != .running || isBusy)
                .help(instance.state == .running
                      ? "Opens a tunnel so this instance can be reached from the internet."
                      : "Start \(instance.name) first - there is nothing to publish while it is off.")
        }
    }

    private func working(_ what: String) -> some View {
        HStack(spacing: Design.Spacing.medium) {
            ProgressView().controlSize(.small)
            Text(what).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Published

    @ViewBuilder
    private func live(_ endpoint: PublicAccessModel.Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "globe.badge.chevron.backward")
                    .foregroundStyle(.green)
                Text(endpoint.address)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Design.Spacing.small)
                Button(copied == "address" ? "Copied" : "Copy") {
                    copy(endpoint.shareableSummary, as: "address")
                }
                Button("Stop") { publicModel.unpublish(instance.name) }
                    .disabled(isBusy)
            }

            Text("Reachable from anywhere. Password logins are off; only keys work.")
                .font(.caption).foregroundStyle(.secondary)

            if let expiry = endpoint.expiryNote {
                Text(expiry)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            DetailRow(label: "Host", value: endpoint.host, monospaced: true)
            Divider()
            DetailRow(label: "Port", value: String(endpoint.port), monospaced: true)
            Divider()
            DetailRow(label: "User", value: endpoint.user, monospaced: true)

            Divider()
            // Shown whether or not this Mac still has its own key: this is
            // the line that gets sent to people, and it is true regardless.
            DetailRow(label: "From another computer", value: endpoint.remoteCommand, monospaced: true)

            if endpoint.keyExists {
                Divider()
                DetailRow(label: "From this Mac", value: endpoint.command, monospaced: true)
                HStack(spacing: Design.Spacing.medium) {
                    // Selects the file rather than just opening the folder:
                    // the folder holds a key per instance, and "which one
                    // is mine" is the whole question being answered.
                    Button("Show key in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: endpoint.identityFile)])
                    }
                    .buttonStyle(.link).font(.caption)
                    Button(copied == "key" ? "Copied" : "Copy key") {
                        if let text = try? String(contentsOfFile: endpoint.identityFile,
                                                  encoding: .utf8) {
                            copy(text, as: "key")
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                    Spacer()
                }
                .padding(.top, 1)
            } else {
                Divider()
                // Said plainly rather than offering a command that cannot
                // work: the key lives outside the home directory so no guest
                // can read it, and that directory is cleared on restart.
                Label("The key MSL made for this Mac is gone (it does not survive a restart). "
                      + "Publish again for a new one, or connect with a key you authorized below.",
                      systemImage: "key.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keysRow
            HStack(spacing: Design.Spacing.medium) {
                Button("How to connect from another computer…") { showingTips = true }
                    .buttonStyle(.link).font(.caption)
                Spacer()
            }
            notifyRow
        }
    }

    private func pending(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                Text("Published, but not reachable this moment")
                Spacer()
                Button("Stop") { publicModel.unpublish(instance.name) }.disabled(isBusy)
            }
            Text(reason + " MSL is opening it again; the address will be a new one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check again") { publicModel.refresh(instance.name) }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try again") { showingConfirm = true }
                Button("Not now") { publicModel.refresh(instance.name) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: - Who can log in

    private var keysRow: some View {
        let keys = publicModel.authorizedKeys(for: instance.name)
        return HStack(spacing: Design.Spacing.medium) {
            Button(keys.isEmpty ? "Let another computer in…"
                                : "\(keys.count) computer\(keys.count == 1 ? "" : "s") allowed…") {
                showingKeys = true
            }
            .buttonStyle(.link).font(.caption)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var keysSheet: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Computers allowed into \(instance.name)")
                .font(.headline)
            Text("""
            Each computer keeps its own key. You paste its *public* half here - the \
            contents of its .pub file - and nothing secret ever travels. On that computer: \
            cat ~/.ssh/id_ed25519.pub (or ssh-keygen -t ed25519 if it has no key yet).
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let keys = publicModel.authorizedKeys(for: instance.name)
            if keys.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                // A List, not a Table: Table never delivers the row
                // interactions this needs - see MSL Files.
                List(keys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.label)
                            Text(key.fingerprint)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            publicModel.deauthorize(instance.name, fingerprintOrLabel: key.label)
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(minHeight: 90, maxHeight: 160)
            }

            Divider()
            tailnetKeysSection
            Divider()
            shareByHandSection
            Divider()

            Text("Or paste a key they already have").font(.subheadline).bold()
            TextEditor(text: $pastedKey)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            TextField("What to call it (optional)", text: $pastedLabel)
                .textFieldStyle(.roundedBorder)

            if let message = keyMessage {
                Label(message.text, systemImage: message.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(message.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Done") { showingKeys = false; keyMessage = nil }
                Spacer()
                Button("Allow this computer") {
                    publicModel.authorize(instance.name, key: pastedKey, label: pastedLabel) { ok, text in
                        keyMessage = (ok, text)
                        if ok { pastedKey = ""; pastedLabel = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 460)
    }

    // MARK: - Emailing the address out

    private var notifyRow: some View {
        let people = publicModel.people(for: instance.name)
        return HStack(spacing: Design.Spacing.medium) {
            Button(people.isEmpty
                   ? "Email the address to someone…"
                   : "Emailing \(people.count) \(people.count == 1 ? "person" : "people")…") {
                showingNotify = true
            }
            .buttonStyle(.link).font(.caption)
            Spacer()
        }
    }

    /// Setting up email, and who gets it.
    ///
    /// The awkward truth is stated at the top rather than discovered later:
    /// Resend's free sender only reaches your own address, so emailing a
    /// colleague needs a domain. Finding that out from a 403 after adding
    /// three people would be worse.
    private var notifySheet: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("\(instance.name): reaching it, and telling people")
                .font(.headline)

            routeSection
            Divider()
            Text("Email the address out").font(.subheadline).bold()
            Text("""
            The address changes every so often. MSL can email it out, so nobody has to \
            ask you for it again — each person gets their own key the first time, then \
            just the new address when it moves.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if publicModel.notifySetup.configured {
                HStack {
                    Label("Sending as \(publicModel.notifySetup.from)", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Change") { editingSetup = true }.buttonStyle(.link).font(.caption)
                }
            }

            if !publicModel.notifySetup.configured || editingSetup {
                setupFields
            } else {
                peopleSection
            }

            if let message = notifyMessage {
                Label(message.text, systemImage: message.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(message.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Done") { showingNotify = false; notifyMessage = nil; editingSetup = false }
                Spacer()
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 480)
        .task {
            publicModel.loadNotify(instance.name)
            publicModel.refreshTailnet()
        }
    }

    private var setupFields: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Divider()
            Text("Connect Resend").font(.subheadline).bold()
            Text("""
            Free at resend.com. Their test sender can only email your own address — to \
            reach anyone else you verify a domain you own (the free plan includes one) and \
            send from something like msl@your-company.com.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Secure, so it is not left on screen over somebody's
            // shoulder, and it goes through the daemon so there is exactly
            // one writer - see ResendCredentials for where it lands and
            // why it is not in Application Support.
            SecureField("API key (starts with re_)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            TextField("Send from — msl@your-domain.com", text: $fromAddress)
                .textFieldStyle(.roundedBorder)
            TextField("Reply-To, so people can answer you (optional)", text: $replyTo)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") {
                    publicModel.saveNotifySetup(apiKey: apiKey, from: fromAddress,
                                                replyTo: replyTo, instance: instance.name) { ok, text in
                        notifyMessage = (ok, text)
                        if ok { apiKey = ""; editingSetup = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!apiKey.hasPrefix("re_") || !fromAddress.contains("@"))
                if publicModel.notifySetup.configured {
                    Button("Send myself a test") {
                        publicModel.sendTestEmail(to: testAddress.isEmpty
                                                  ? publicModel.notifySetup.from : testAddress) { ok, text in
                            notifyMessage = (ok, text)
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Spacer()
            }
            TextField("Test email goes to (optional)", text: $testAddress)
                .textFieldStyle(.roundedBorder).font(.caption)
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Divider()
            let people = publicModel.people(for: instance.name)
            if people.isEmpty {
                Text("Nobody yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                List(people) { person in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.label)
                            Text(person.hasKey ? person.email
                                               : "\(person.email) — gets their key when you publish")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { publicModel.removePerson(instance.name, email: person.email) }
                            .buttonStyle(.link)
                    }
                }
                .frame(minHeight: 70, maxHeight: 140)
            }

            Text("Add someone").font(.subheadline).bold()
            HStack {
                TextField("their@email.com", text: $newEmail).textFieldStyle(.roundedBorder)
                TextField("Name (optional)", text: $newLabel).textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            Button("Add") {
                publicModel.addPerson(instance.name, email: newEmail, label: newLabel) { ok, text in
                    notifyMessage = (ok, text)
                    if ok { newEmail = ""; newLabel = "" }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!newEmail.contains("@") || isBusy)
        }
    }

    /// How people reach it, and who gets told — one sheet, because they are
    /// the same decision made twice.
    private var routeSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("How people reach it").font(.subheadline).bold()
            Picker("", selection: Binding(
                get: { publicModel.route(for: instance.name) },
                set: { publicModel.setRoute($0, for: instance.name) })) {
                    ForEach(PublicAccessModel.Route.allCases) { route in
                        Text(route.title).tag(route)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

            Text(publicModel.route(for: instance.name).explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if publicModel.route(for: instance.name) == .ownServer {
                TextField("you@your-server.com:2222", text: Binding(
                    get: { publicModel.serverTarget(for: instance.name) },
                    set: { publicModel.setServerTarget($0, for: instance.name) }))
                    .textFieldStyle(.roundedBorder)
                Text("The port is the one people will connect to there. It needs "
                     + "GatewayPorts yes in that server's sshd_config, and a port above 1024.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if publicModel.route(for: instance.name) == .tailscale {
                Divider()
                tailscaleSection
            }

            if case .live = publicModel.state(for: instance.name) {
                Text("Already published — press Stop, then Publish again to switch route.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The Tailscale route, once it is chosen.
    ///
    /// **There is nothing to configure**, which is the thing worth saying
    /// out loud: people expect to exchange a key between the two machines,
    /// because that is how most private networks work. Tailscale does all
    /// of that itself the moment both are signed in. So this panel reports
    /// rather than asks - what state Tailscale is in, what this Mac is
    /// called, and which of your machines could reach the instance.
    ///
    /// The one thing it does ask for is the port, because two published
    /// instances would otherwise collide on it.
    @ViewBuilder
    private var tailscaleSection: some View {
        let status = publicModel.tailnet
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            switch status.state {
            case "running":
                Label("Tailscale is on. This Mac is \(status.selfShortName).",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Design.Spacing.small) {
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField("2222", value: Binding(
                        get: { publicModel.tailscalePort(for: instance.name) },
                        set: { publicModel.setTailscalePort($0, for: instance.name) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("Only needs changing if you publish two instances at once.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if status.machines.isEmpty {
                    Text("No other machines on your tailnet yet. Install Tailscale on the "
                         + "computer you want to connect from and sign in with the same account.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("These can reach it once published:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(status.machines) { machine in
                        HStack(spacing: Design.Spacing.small) {
                            Circle()
                                .fill(machine.online ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(machine.shortName).font(.caption)
                            Text(machine.system).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(machine.online ? "on" : "off")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                // Said here because it is the one thing Tailscale does not
                // do for you, and the one people assume it does.
                Text("Tailscale gets them to this Mac. Each one still needs an SSH key for the "
                     + "instance - use \u{201C}Let another computer in\u{201D} to make one.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case "signedOut":
                Label("Tailscale is installed but not signed in.", systemImage: "person.crop.circle.badge.xmark")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Tailscale") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                }
                .buttonStyle(.link).font(.caption)

            default:
                Label("Tailscale isn't installed on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Text("Install it on this Mac and on whatever you want to connect from, sign in "
                     + "with the same account on both, and they find each other. There is no key "
                     + "to copy across.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get Tailscale") {
                    if let url = URL(string: "https://tailscale.com/download") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link).font(.caption)
            }

            Button("Check again") { publicModel.refreshTailnet() }
                .buttonStyle(.link).font(.caption2)
        }
        .padding(.leading, 2)
    }

    /// Your own machines, one click each.
    ///
    /// The rest of this sheet asks you to type who a key is for, which is
    /// right for a colleague and silly for your own laptop - MSL can
    /// already see it by name. So the machines on your tailnet are listed
    /// with a button each: press it and that machine has a key, named
    /// after itself, on the clipboard with the command.
    ///
    /// Greyed out rather than hidden when Tailscale is not there. A section
    /// that vanishes leaves somebody wondering whether they imagined it;
    /// one that is visible and explains itself can be acted on.
    @ViewBuilder
    private var tailnetKeysSection: some View {
        let status = publicModel.tailnet
        let ready = status.isReady
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("Your Tailscale machines").font(.subheadline).bold()
                Spacer()
                Button {
                    publicModel.refreshTailnet()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look again - a machine that has just come online will appear")
            }

            if !ready {
                Text(status.state == "signedOut"
                     ? "Tailscale is installed but not signed in, so MSL can't see your machines yet."
                     : "With Tailscale on this Mac and on your other computers, they would be listed "
                       + "here and you could give each one a key with a single press.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.machines.isEmpty {
                Text("Nothing else on your tailnet yet. Install Tailscale on the computer you "
                     + "want to connect from and sign in with the same account, then press refresh.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(status.machines) { machine in
                    HStack(spacing: Design.Spacing.small) {
                        Circle()
                            .fill(machine.online ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(machine.shortName)
                            if alreadyAllowed(machine.shortName) {
                                Text("already has a key").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(alreadyAllowed(machine.shortName) ? "New key" : "Make key & copy") {
                            publicModel.makeShareableKey(instance.name, label: machine.shortName) { ok, text in
                                keyMessage = (ok, text)
                                if ok { copied = "share" }
                            }
                        }
                        .disabled(isBusy)
                    }
                }
            }
        }
        // Greyed as a whole when there is nothing to act on, so the section
        // reads as "not available" rather than "broken".
        .opacity(ready ? 1 : 0.55)
        .disabled(!ready)
    }

    /// Whether a machine of that name is already on the instance's roster.
    private func alreadyAllowed(_ name: String) -> Bool {
        publicModel.authorizedKeys(for: instance.name).contains { $0.label == name }
    }

    /// Making somebody a key to send by hand, for when email is not set up
    /// - which is most of the time, since emailing needs a domain.
    private var shareByHandSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Send someone a key yourself").font(.subheadline).bold()
            Text("Makes them their own key and copies it, with the command, ready to paste "
                 + "into a message. Revoke them on their own later.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Who is it for?", text: $shareName)
                    .textFieldStyle(.roundedBorder)
                Button(copied == "share" ? "Copied" : "Make key & copy") {
                    publicModel.makeShareableKey(instance.name,
                                                 label: shareName.isEmpty ? "shared" : shareName) { ok, text in
                        keyMessage = (ok, text)
                        if ok { copied = "share"; shareName = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }

    /// Step-by-step instructions for whichever machine somebody is on.
    ///
    /// Worth its own button because the steps genuinely differ, and the
    /// Windows ones in particular are not guessable: a key saved to
    /// Downloads is usually readable by another account, ssh refuses it,
    /// and the command that fixes it has a quoting trap in it.
    private var tipsSheet: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Connecting to \(instance.name)")
                .font(.headline)

            Picker("", selection: $tipsPlatform) {
                ForEach(ConnectionTips.Platform.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if case .live(let endpoint) = publicModel.state(for: instance.name) {
                ScrollView {
                    Text(ConnectionTips.instructions(for: tipsPlatform,
                                                     instance: instance.name,
                                                     endpoint: endpoint.asPublicEndpoint))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)

                Text(ConnectionTips.identitiesOnlyNote)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Done") { showingTips = false }
                    Spacer()
                    Button(copied == "tips" ? "Copied" : "Copy these steps") {
                        copy(ConnectionTips.instructions(for: tipsPlatform,
                                                         instance: instance.name,
                                                         endpoint: endpoint.asPublicEndpoint), as: "tips")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Publish \(instance.name) first - the steps include its address, "
                     + "and it does not have one yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { showingTips = false }
            }
        }
        .padding(Design.Spacing.large)
        .frame(width: 520)
    }

    private func copy(_ text: String, as tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = nil }
    }
}
