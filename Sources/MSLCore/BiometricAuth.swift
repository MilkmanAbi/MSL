import Foundation
import LocalAuthentication

/// Touch ID, or the Mac's password if there is no Touch ID (or it fails).
///
/// `deviceOwnerAuthentication`, deliberately, rather than the biometrics-only
/// policy: a Mac without Touch ID, or a user whose finger is not being read
/// today, must still be able to start their own instance. Locking someone out
/// of their Linux because a sensor is damp is not security.
public enum BiometricAuth {
    public enum Outcome: Equatable, Sendable {
        case authenticated
        /// The person cancelled, or failed to authenticate.
        case denied(String)
        /// No authentication is possible here at all: no Touch ID, no
        /// password set, or no GUI session to show a prompt in.
        case unavailable(String)
    }

    /// Whether this Mac can authenticate at all, for deciding whether to
    /// offer the setting in the first place.
    public static func isAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Whether Touch ID specifically is there, for wording the UI honestly.
    public static func hasBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        return context.biometryType == .touchID || context.biometryType == .opticID
    }

    /// Asks. `reason` completes the sentence macOS shows: "MSL is trying to
    /// <reason>."
    public static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "this Mac can't authenticate")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .authenticated : .denied("authentication failed")
        } catch {
            let code = LAError.Code(rawValue: (error as NSError).code)
            switch code {
            case .userCancel, .systemCancel, .appCancel:
                return .denied("cancelled")
            case .userFallback, .authenticationFailed:
                return .denied("authentication failed")
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                return .unavailable(error.localizedDescription)
            default:
                return .denied(error.localizedDescription)
            }
        }
    }
}
