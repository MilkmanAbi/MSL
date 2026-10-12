import SwiftUI
import MSLCore
import CryptoKit

/// First-run setup for the MSL Admin Portal, and the unlocked admin view.
///
/// Three things get set up, and the wording keeps them apart because they
/// do different jobs: the **password** gates this panel, the **signing key**
/// stops the policy being forged, and **where the file lives** stops it
/// being written. Blurring them is how somebody ends up believing a
/// password protects a policy file that anyone can edit.
struct AdminPortalSetup: View {
    let onFinished: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false

    private var passwordsMatch: Bool {
        !password.isEmpty && password == confirmation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text("Set up the Admin Portal").font(.title3).bold()
                    Text("This creates an administrator password for this panel and a "
                         + "signing key for policies on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("1 · Administrator password",
                        "Unlocks this panel. It does not protect the policy file itself - "
                        + "the signing key does that.") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Confirm", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                    if !confirmation.isEmpty && !passwordsMatch {
                        Text("The two do not match.").font(.caption).foregroundStyle(.orange)
                    }
                }

                section("2 · Signing key",
                        "MSL generates a key here and pins it. A policy signed with it "
                        + "cannot be edited without the change being detected.") {
                    Label("Local admin mode", systemImage: "key")
                        .font(.callout)
                    // Said plainly up front, not buried in a status line
                    // later: it is the difference between "nobody can
                    // change this" and "nobody can change this by accident".
                    Text("The private key is stored on this Mac, so anyone with "
                         + "administrator access here could re-sign a policy. A fleet "
                         + "deployment keeps its key on another machine and uses "
                         + "`msl admin pin` instead.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("3 · Where the key is kept",
                        "MSL stores it itself. Nothing is written anywhere you have to "
                        + "look after.") {
                    Text(MSLAPKeyStore.directory.path)
                        .font(.caption.monospaced())
                    // The app must never hand out the private half. The
                    // PUBLIC key is the thing an administrator copies, to
                    // pin this signer on another Mac, and the panel offers
                    // exactly that once setup is done.
                    Text("Owner-only (0600). The private key never leaves this folder - "
                         + "to trust this signer on another Mac, copy the PUBLIC key from "
                         + "the panel afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Set Up") { setUp() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!passwordsMatch || busy)
                }
            }
            .padding(Design.Spacing.large)
        }
    }

    private func section<Content: View>(_ title: String, _ detail: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func setUp() {
        busy = true
        error = nil
        do {
            try MSLAPAdminPassword.set(password)
            _ = try MSLAPKeyStore.createLocalKey()
            busy = false
            onFinished()
        } catch {
            self.error = "Setup failed: \(error.localizedDescription)"
            busy = false
        }
    }

}

/// Asks for the administrator password before showing the admin view.
struct AdminPortalUnlock: View {
    let onUnlocked: () -> Void
    @State private var password = ""
    @State private var wrong = false
    @State private var waitMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Administrator password").font(.headline)
            Text("Unlocks the editing view. Everything above is readable without it.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attempt)
            if wrong {
                Text("That password did not match.").font(.caption).foregroundStyle(.orange)
            }
            if let waitMessage {
                Text(waitMessage).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Unlock", action: attempt).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.large)
    }

    private func attempt() {
        if let wait = MSLAPAdminPassword.throttleRemaining() {
            // Say so rather than just rejecting it, or a throttled attempt
            // looks like a wrong password and the person keeps trying.
            waitMessage = "Too many attempts. Try again in \(Int(wait.rounded(.up))) s."
            wrong = false
            return
        }
        waitMessage = nil
        if MSLAPAdminPassword.verify(password) {
            wrong = false
            onUnlocked()
        } else {
            wrong = true
        }
    }
}
