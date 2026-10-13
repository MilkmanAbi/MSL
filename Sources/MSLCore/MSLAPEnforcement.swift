import Foundation

/// Maps a daemon control request to the MSLAP capability it needs.
///
/// **This is the chokepoint.** `mslhd` is the one place the app and the CLI
/// both pass through, so a denial applied here binds both by construction.
/// Enforcing in the app would leave `msl` able to do the thing anyway -
/// exactly the half-wired failure that per-app launch commands hit, where
/// MSL.app honoured an override and `msl gui-native` ignored it.
///
/// A request that maps to nil is unrestricted: queries, session plumbing,
/// and anything MSLAP has no business refusing.
public enum MSLAPEnforcement {

    /// What this request needs permission for, and against which instance.
    ///
    /// A LIST, because some requests need more than one: publishing is both
    /// `public.expose` and the capability for the backend it uses, and
    /// denying either must stop it. Returning only one meant adding the
    /// backend check silently removed the broader one.
    public static func requirements(for request: DaemonProtocol.ControlRequest)
        -> [(capability: MSLAPCapability, instance: String?)] {
        switch request {
        // MARK: lifecycle
        case .remove(let instance, _):
            return [(MSLAPCapability("instance.delete"), instance)]
        case .createInstance(let instance, let distro):
            // Creating is app-wide: the instance does not exist yet, so a
            // scope naming it cannot sensibly have an opinion.
            _ = instance
            var needs: [(MSLAPCapability, String?)] = [(MSLAPCapability("instance.create"), nil)]
            // A custom image is code the person brought themselves - its
            // own kernel and its own root filesystem, neither built nor
            // checksummed by MSL. That is the same class of thing as
            // importing a shipment, so it gets its own capability ON TOP
            // of `instance.create`: a deployment may well allow new
            // instances of the published distros while refusing images
            // from anywhere else.
            if distro.isCustom { needs.append((MSLAPCapability("distro.custom"), nil)) }
            return needs
        case .suspend(let instance):
            return [(MSLAPCapability("instance.suspend"), instance)]
        case .resume(let instance):
            return [(MSLAPCapability("instance.start"), instance)]
        case .hibernate(let instance):
            return [(MSLAPCapability("instance.hibernate"), instance)]
        case .shutdown(let instance):
            return [(MSLAPCapability("instance.stop"), instance)]

        // MARK: renaming and cloning
        //
        // **Both ask for the capability AND for the thing they resemble.**
        // A rename is not just a new label: MSLAP scopes match by instance
        // name, so moving `lab-3` to `mine` leaves every rule written about
        // `lab-*` behind. `InstanceRename.policyEscapes` refuses exactly
        // that, and this is the other half - whether the person may rename
        // at all.
        case .renameInstance(let instance, _):
            return [(MSLAPCapability("instance.rename"), instance)]
        case .cloneInstance(let instance, _):
            // A clone creates an instance, so it answers to
            // `instance.create` as well: a deployment that caps how many
            // instances exist means that cap however they are made, and a
            // clone that slipped past it would be the obvious way round.
            return [(MSLAPCapability("instance.clone"), instance),
                    (MSLAPCapability("instance.create"), nil)]

        // MARK: distros
        case .removeDistro:
            return [(MSLAPCapability("distro.remove"), nil)]

        // MARK: provenance
        //
        // Rewriting a marker says "this disk really is the one recorded",
        // which is a claim about provenance - so on a managed Mac it is
        // the administrator's to make, not the user's. Gated by
        // `instance.acceptUnidentified`, the capability that already means
        // "decide what counts as acceptable provenance here", rather than
        // inventing a second one for a single command.
        case .rewriteIdentityMarker(let instance):
            return [(MSLAPCapability("instance.acceptUnidentified"), instance)]

        // Protecting an instance is the safe direction - it makes the disk
        // unreadable - so it is never refused. **Taking it back OUT is the
        // one that needs permission**, because an administrator who denied
        // copying meant the bytes to stay sealed, and moving them back into
        // a plain file beside everything else would quietly undo that.
        //
        // The usual rule, applied the way round that this feature happens
        // to need: the operation that REDUCES exposure goes through.
        case .protectInstance(let instance, let enable):
            return enable ? [] : [(MSLAPCapability("instance.clone"), instance)]

        // Supplying a key the administrator holds, or forgetting it, is
        // never refused: `unlock` is somebody proving they are entitled to
        // open the image, and `lock` makes the Mac safer.
        //
        // **`adopt` is the one that needs permission**, because moving a
        // container to admin-held mode changes who can open it from then
        // on - and on a managed Mac that is the administrator's decision,
        // not the user's. Gated on `instance.clone`, the capability that
        // already means "this image's copies are my business".
        case .vaultKey(let instance, let action, _):
            return action == "adopt" ? [(MSLAPCapability("instance.clone"), instance)] : []

        // MARK: port forwarding
        case .forwardAdd(let instance, _, _, _):
            return [(MSLAPCapability("network.portForward"), instance)]

        // MARK: sandbox gates
        case .sandboxSet(let instance, _):
            return [(MSLAPCapability("network.cut"), instance)]

        // MARK: peripherals
        case .usbAttach(let instance, _, _), .usbRelay(let instance, _):
            return [(MSLAPCapability("peripherals.usb"), instance)]
        case .usbPlan:
            // Names a device, not an instance - app-wide.
            return [(MSLAPCapability("peripherals.usb"), nil)]

        // MARK: PublicMSL
        case .publicExpose(let instance, let backend):
            // Both: the act of publishing, AND the backend it uses - a
            // fleet may allow its own server while refusing a third-party
            // relay, or the reverse. Denying either stops it.
            let backendCapability = backend.lowercased().contains("relay")
                ? "public.relay" : "public.selfHosted"
            return [(MSLAPCapability("public.expose"), instance),
                    (MSLAPCapability(backendCapability), instance)]
        case .publicAuthorize(let instance, _, _), .publicMakeKey(let instance, _):
            return [(MSLAPCapability("public.authorize"), instance)]
        case .publicNotifyAdd(let instance, _, _), .publicNotifyRemove(let instance, _):
            return [(MSLAPCapability("public.notify"), instance)]
        case .publicNotifySetup, .publicNotifyTest:
            return [(MSLAPCapability("public.notify"), nil)]

        // MARK: the rest of the daemon surface
        case .trafficSnapshot(let instance, _):
            return [(MSLAPCapability("network.trafficMonitor"), instance)]

        // MARK: guest files
        //
        // Where `sharing.files` actually bites. MSL Files has no vsock of
        // its own, so every listing and every permission change it makes
        // comes through here - which is also why gating the VIEW would
        // have been the wrong place: the file picker is that same view,
        // and it is governed by `sharing.filePicker` instead.
        case .fileList(let instance, _), .fileChmod(let instance, _, _):
            return [(MSLAPCapability("sharing.files"), instance)]

        // Reading a repository is reading the instance's files, so it is the
        // same gate. Creating one also writes, but `sharing.files` is already
        // the permission to touch this instance's files at all - a second
        // capability for it would be a rule an administrator could set to
        // "no writing" while `sharing.files` still allowed every other write
        // MSL Files can do.
        case .gitQuery(let instance, _, _, _):
            return [(MSLAPCapability("sharing.files"), instance)]

        // MARK: everything else
        //
        // Listed rather than defaulted, so adding a control request is a
        // decision about whether MSLAP governs it. A `default` here would
        // silently leave every future request unrestricted.
        case
             // Asks macOS whether it will let the daemon onto the local
             // network. It reaches nothing of the person's and names no
             // instance - it exists so the prompt is raised against the
             // process that needs the permission - so there is nothing here
             // for an administrator to govern.
             .localNetworkProbe,
             .session, .attachSession, .sessionEnded,
             .snapshotSave, .snapshotRestore, .snapshotList,
             .status, .instanceList, .instanceDetails,
             .startGui, .startNativeGui,
             .startCageBridge, .startCageInputBridge, .sendCageKey, .startCageView,
             .filePickDetails, .filePickResult,
             .powerTest, .sandboxGet, .memoryStatus,
             .maintenance,
             .usbList,
             // **Operations that REDUCE exposure are never refused.**
             // Revoking a published instance, dropping an authorised key
             // or forgetting a notification address all make a managed Mac
             // safer, and a policy that blocked them would trap an
             // administrator's own mistake in place - deny `public.expose`
             // after someone published, and without this they could not
             // unpublish it.
             .publicRevoke, .publicDeauthorize, .publicNotifyForget, .usbDetach,
             // Closing a forward reduces what this Mac exposes. Refusing
             // it would trap one open: deny `network.portForward` after
             // somebody opened a port and, without this, they could not
             // close it again.
             .forwardRemove,
             // And listing is a question.
             .forwardList,
             // Queries.
             .publicStatus, .publicKeys, .publicNotifyList, .publicTailscaleStatus:
            return []
        }
    }

    /// Every capability some control request needs, for the catalogue's
    /// honesty check: a capability may only claim `enforced` if something
    /// here actually asks for it.
    ///
    /// Derived from the mapping rather than hand-listed, so it cannot
    /// drift away from what the daemon really refuses.
    public static var enforcedCapabilities: Set<MSLAPCapability> {
        Set(DaemonProtocol.ControlRequest.everyCaseForAudit
            .flatMap { requirements(for: $0).map(\.capability) })
    }

    /// The refusal a client sees. Names the capability and the issuer,
    /// because a managed machine that will not say why it refused is the
    /// thing people hate most about managed machines.
    public static func refusal(capability: MSLAPCapability,
                               decision: MSLAPPolicy.Decision,
                               issuer: String?) -> String {
        var text = "refused by MSL Admin Portal: \(capability.key) is not allowed"
        if let by = decision.deniedByCapability, by != capability {
            text += " (denied by \(by.key))"
        }
        if let reason = decision.deniedBy?.reason { text += " - \(reason)" }
        if let issuer { text += ". Set by \(issuer)." }
        return text
    }

    /// Whether a request may proceed, given the policy in force.
    ///
    /// Returns nil to allow, or the message to refuse with.
    ///
    /// **A policy that is present but unreadable refuses nothing here.**
    /// That looks wrong and is deliberate: `MSLAPPolicyStore.load` reports
    /// `.broken` so the daemon can log it loudly at startup, but having
    /// every request fail closed on a corrupt file would brick the machine
    /// for its owner, including their ability to fix the file. Loud and
    /// working beats silent and bricked. See README 30 section 4.
    public static func check(_ request: DaemonProtocol.ControlRequest,
                             policy: MSLAPPolicy?,
                             issuer: String?) -> String? {
        guard let policy else { return nil }
        for need in requirements(for: request) {
            let decision = policy.decision(for: need.capability, instance: need.instance)
            guard decision.allowed else {
                return refusal(capability: need.capability, decision: decision, issuer: issuer)
            }
        }
        return nil
    }
}
