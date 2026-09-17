import Foundation
import SystemExtensions

/*
 * MSLUSBDriverHost
 *
 * Minimal host app whose only job is to submit an activation request for
 * MSLUSBDriver.dext (embedded at Contents/Library/SystemExtensions/ - see
 * build.sh) via OSSystemExtensionRequest, per Apple's required flow:
 * system extensions cannot be loaded directly (no `kextload`-style CLI
 * path), only activated by a containing app calling this API.
 *
 * Built and run entirely from the command line (see build.sh) - no Xcode
 * project needed for this either, same approach as the dext itself.
 */

final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing existing extension \(existing.bundleVersion) with \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("needs user approval - check System Settings > Privacy & Security")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            print("activation completed")
        case .willCompleteAfterReboot:
            print("activation will complete after reboot")
        @unknown default:
            print("activation finished with unknown result: \(result)")
        }
        exit(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        FileHandle.standardError.write("activation failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let extensionIdentifier = "com.msl.MSLUSBDriver"
let delegate = ActivationDelegate()
let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
request.delegate = delegate

print("submitting activation request for \(extensionIdentifier) ...")
OSSystemExtensionManager.shared.submitRequest(request)

RunLoop.main.run()
