import MSLCore
import SwiftUI

/// The first start of a distro, from the app: create the everyday Linux
/// account, the way a fresh Linux install - or WSL - asks for one.
///
/// Same account, same rules and same guest script as the `msl` CLI's prompt
/// (`LinuxUserSetup`), so it doesn't matter which one a person meets first.
struct LinuxUserSetupSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.UserSetupRequest

    @State private var username = LinuxUserSetupSheet.suggestedUsername()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    private var instance: Instance { request.instance }
    private var distro: GuestDistro { request.instance.distro }

    private var usernameProblem: LinuxUserSetup.UsernameProblem? { LinuxUserSetup.problem(with: username) }
    private var passwordProblem: String? { LinuxUserSetup.passwordProblem(password, confirmation: confirmation) }
    private var canCreate: Bool { usernameProblem == nil && passwordProblem == nil && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            HStack(spacing: Design.Spacing.medium) {
                DistroBadge(distro: distro, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your Linux account").font(.title2).bold()
                    Text("\(distro.displayName) · first start of \(instance.name)")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Like any new Linux machine, \(distro.displayName) needs an everyday account. It becomes the login for every \(distro.displayName) instance, and it's an administrator: sudo asks for its password. The username doesn't need to match your Mac's.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Username") {
                TextField("", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                hint(username.isEmpty || usernameProblem == nil
                     ? "Lowercase letters, digits, “_” and “-”, starting with a letter."
                     : usernameProblem!.message,
                     warning: !username.isEmpty && usernameProblem != nil)
            }

            field("Password") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Retype password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canCreate { create() } }
                // Only complain about a mismatch once there's something to
                // compare, not while the second field is still empty.
                if !confirmation.isEmpty, let passwordProblem {
                    hint(passwordProblem, warning: true)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if working {
                HStack(spacing: Design.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Starting \(instance.name) and creating “\(username)”…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Text("Root stays available from Terminal: `msl \(instance.name) -u root`")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Cancel") { model.userSetup = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Create Account") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(Design.Spacing.section - 4)
        .frame(width: 500)
        .interactiveDismissDisabled(working)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
            content()
        }
    }

    private func hint(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : .secondary)
    }

    private func create() {
        guard canCreate else { return }
        working = true
        error = nil
        let name = username
        let secret = password
        let target = instance
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                LinuxUserSetup.run(instance: target.name, distro: target.distro, username: name, password: secret)
            }.value
            working = false
            switch outcome {
            case .created(let warning):
                model.finishUserSetup(request, username: name, warning: warning)
            case .alreadyExists:
                error = "A user called “\(name)” already exists in \(target.distro.displayName). Pick another name."
            case .failed(let message):
                error = "Couldn't create the account: \(message)"
            }
        }
    }

    /// The Mac's short username, when it happens to be a valid Linux one -
    /// a starting point, not a requirement.
    private static func suggestedUsername() -> String {
        let mac = NSUserName().lowercased()
        return LinuxUserSetup.problem(with: mac) == nil ? mac : ""
    }
}
