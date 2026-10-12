import MSLCore
import SwiftUI

/// "Ask for Touch ID before starting this instance."
///
/// Honest about its limits, because a security switch that overpromises is
/// worse than no switch: this gates *starting* the instance, and the disk
/// image is still a file anything running as you can read.
struct InstanceLockCard: View {
    let instance: Instance

    @State private var locked = false
    @State private var failed = false

    private var available: Bool { BiometricAuth.isAvailable() }
    private var biometric: Bool { BiometricAuth.hasBiometrics() }

    var body: some View {
        Card(title: "Locking", footnote: footnote) {
            if available {
                Toggle(biometric ? "Ask for Touch ID before starting \(instance.name)"
                                 : "Ask for my password before starting \(instance.name)",
                       isOn: Binding(get: { locked }, set: setLocked))
                if locked {
                    Label("MSL asks when \(instance.name) is off. While it's running or suspended, it won't ask again.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failed {
                    Label("Couldn't save that. Check MSL's permissions and try again.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("This Mac has no Touch ID or password set for authentication, so there's nothing to ask for.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { locked = InstanceLockStore.load().isLocked(instance.name) }
    }

    private var footnote: String {
        "MSL's background service asks, so the msl command and apps in your Dock are covered too, not just this window. It protects starting the instance, not the files inside it: the disk image is still readable by anything running as you."
    }

    private func setLocked(_ wanted: Bool) {
        locked = wanted
        failed = !InstanceLockStore.setLocked(wanted, for: instance.name)
        if failed { locked = InstanceLockStore.load().isLocked(instance.name) }
    }
}
