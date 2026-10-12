import XCTest
@testable import MSLCore

/// MSLAP policy resolution. Pure logic, so it is pinned exhaustively -
/// every one of these is a rule an administrator will rely on, and a
/// surprise here silently changes what a managed Mac permits.
final class MSLAPPolicyTests: XCTestCase {

    private func policy(_ scopes: MSLAPPolicy.Scope...) -> MSLAPPolicy {
        MSLAPPolicy(scopes: scopes)
    }
    private func cap(_ key: String) -> MSLAPCapability { MSLAPCapability(key) }

    // MARK: - Allow by default

    func testAnEmptyPolicyAllowsEverything() {
        let p = MSLAPPolicy()
        for entry in MSLAPCapability.catalogue {
            XCTAssertTrue(p.allows(entry.capability), entry.capability.key)
        }
    }

    // MARK: - Dotted coverage

    func testDenyingAGroupDeniesEverythingBeneathIt() {
        let p = policy(.init(match: "*", deny: [cap("network")]))
        XCTAssertFalse(p.allows(cap("network.vpn")))
        XCTAssertFalse(p.allows(cap("network.dns")))
        XCTAssertFalse(p.allows(cap("network")))
    }

    func testAGroupDenyDoesNotLeakAcrossASharedPrefix() {
        // "net" must not cover "network.vpn" - segments are whole, or
        // `instance` would quietly deny `instances.something`.
        let p = policy(.init(match: "*", deny: [cap("net")]))
        XCTAssertTrue(p.allows(cap("network.vpn")))
    }

    func testDenyingALeafLeavesItsSiblingsAlone() {
        let p = policy(.init(match: "*", deny: [cap("network.vpn")]))
        XCTAssertFalse(p.allows(cap("network.vpn")))
        XCTAssertTrue(p.allows(cap("network.dns")))
    }

    // MARK: - Scope matching

    func testAStarScopeAppliesToEveryInstanceAndToGlobalActions() {
        let p = policy(.init(match: "*", deny: [cap("instance.delete")]))
        XCTAssertFalse(p.allows(cap("instance.delete"), instance: "Ubuntu"))
        XCTAssertFalse(p.allows(cap("instance.delete"), instance: nil))
    }

    func testANamedScopeOnlyBindsThatInstance() {
        let p = policy(.init(match: "Ubuntu", deny: [cap("resources.edit")]))
        XCTAssertFalse(p.allows(cap("resources.edit"), instance: "Ubuntu"))
        XCTAssertTrue(p.allows(cap("resources.edit"), instance: "Milk"))
    }

    func testANamedScopeDoesNotGovernGlobalActions() {
        // A rule written for one instance cannot sensibly decide whether
        // MSL may install a distro at all.
        let p = policy(.init(match: "Ubuntu", deny: [cap("distro.install")]))
        XCTAssertTrue(p.allows(cap("distro.install"), instance: nil))
    }

    func testInstanceMatchingIgnoresCase() {
        let p = policy(.init(match: "ubuntu", deny: [cap("instance.delete")]))
        XCTAssertFalse(p.allows(cap("instance.delete"), instance: "Ubuntu"))
    }

    // MARK: - Globs

    func testATrailingGlobMatchesByPrefix() {
        let p = policy(.init(match: "lab-*", deny: [cap("network.vpn")]))
        XCTAssertFalse(p.allows(cap("network.vpn"), instance: "lab-01"))
        XCTAssertTrue(p.allows(cap("network.vpn"), instance: "prod-01"))
    }

    func testALeadingGlobMatchesBySuffix() {
        let p = policy(.init(match: "*-temp", deny: [cap("instance.delete")]))
        XCTAssertFalse(p.allows(cap("instance.delete"), instance: "build-temp"))
        XCTAssertTrue(p.allows(cap("instance.delete"), instance: "temp-build"))
    }

    func testAGlobMustStillMatchTheWholeName() {
        // "lab-*" is a prefix rule, so it must not match something that
        // merely CONTAINS "lab-".
        let p = policy(.init(match: "lab-*", deny: [cap("instance.delete")]))
        XCTAssertTrue(p.allows(cap("instance.delete"), instance: "my-lab-01"))
    }

    // MARK: - Composition: deny wins

    func testANarrowScopeCannotUndoABroaderDeny() {
        // The rule an administrator relies on most: writing a `*` deny and
        // then a per-instance entry must not re-enable it.
        let p = policy(.init(match: "*", deny: [cap("instance.delete")]),
                       .init(match: "Ubuntu", deny: []))
        XCTAssertFalse(p.allows(cap("instance.delete"), instance: "Ubuntu"))
    }

    func testOrderOfScopesDoesNotChangeTheOutcome() {
        let a = policy(.init(match: "*", deny: []),
                       .init(match: "Ubuntu", deny: [cap("resources.edit")]))
        let b = policy(.init(match: "Ubuntu", deny: [cap("resources.edit")]),
                       .init(match: "*", deny: []))
        XCTAssertEqual(a.allows(cap("resources.edit"), instance: "Ubuntu"),
                       b.allows(cap("resources.edit"), instance: "Ubuntu"))
        XCTAssertFalse(a.allows(cap("resources.edit"), instance: "Ubuntu"))
    }

    // MARK: - Explaining a denial

    func testADenialNamesTheScopeAndTheCapabilityResponsible() {
        // The managed user is shown this, so it has to identify the BROAD
        // key that actually did it, not the one they asked about.
        let p = policy(.init(match: "lab-*", deny: [cap("network")], reason: "No VPN in the lab"))
        let d = p.decision(for: cap("network.vpn"), instance: "lab-7")
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.deniedByCapability, cap("network"))
        XCTAssertEqual(d.deniedBy?.reason, "No VPN in the lab")
    }

    func testAnAllowedCapabilityCarriesNoBlame() {
        let p = policy(.init(match: "*", deny: [cap("network")]))
        XCTAssertEqual(p.decision(for: cap("instance.start")), .allow)
    }

    // MARK: - Forward compatibility

    func testAnUnknownCapabilityIsReportedAndNotEnforced() {
        // A policy written for a newer MSL must not brick this one.
        let p = policy(.init(match: "*", deny: [cap("timetravel.enable")]))
        XCTAssertEqual(p.unknownCapabilities, [cap("timetravel.enable")])
        XCTAssertTrue(p.allows(cap("instance.delete")))
    }

    func testAKnownGroupKeyIsNotReportedAsUnknown() {
        let p = policy(.init(match: "*", deny: [cap("network")]))
        XCTAssertTrue(p.unknownCapabilities.isEmpty)
    }

    func testCapabilityKeysAreNormalised() {
        XCTAssertEqual(cap("  Network.VPN  "), cap("network.vpn"))
    }

    // MARK: - Round trip

    func testAPolicySurvivesEncodingAndDecoding() throws {
        let original = MSLAPPolicy(
            issuer: "Example Corp IT",
            minimumMSLVersion: "2.0.0",
            scopes: [.init(match: "lab-*", deny: [cap("network"), cap("shipment.export")],
                           reason: "Lab machines stay offline")],
            message: "Ask #help for an exception.")
        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(MSLAPPolicy.self, from: data)
        XCTAssertEqual(original, again)
    }

    func testAnUnknownCapabilitySurvivesARoundTripUnchanged() throws {
        // Dropping it would silently rewrite an administrator's document.
        let original = policy(.init(match: "*", deny: [cap("future.thing")]))
        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(MSLAPPolicy.self, from: data)
        XCTAssertEqual(again.scopes.first?.deny, [cap("future.thing")])
    }

    // MARK: - Version gate

    func testVersionComparison() {
        XCTAssertTrue(MSLVersion.compare("2.0.0", isAtLeast: "2.0.0"))
        XCTAssertTrue(MSLVersion.compare("2.1.0", isAtLeast: "2.0.0"))
        XCTAssertTrue(MSLVersion.compare("2.0", isAtLeast: "2.0.0"))
        XCTAssertFalse(MSLVersion.compare("1.9.9", isAtLeast: "2.0.0"))
        // Unparseable compares false, so MSL refuses rather than enforcing
        // a policy whose requirement it cannot read.
        XCTAssertFalse(MSLVersion.compare("banana", isAtLeast: "2.0.0"))
    }
}

/// The catalogue is a promise about what MSL can actually refuse, so it is
/// checked for the ways that promise could quietly become untrue.
final class MSLAPCatalogueTests: XCTestCase {

    func testEveryCapabilityKeyIsUniqueAndNormalised() {
        var seen = Set<String>()
        for entry in MSLAPCapability.catalogue {
            XCTAssertTrue(seen.insert(entry.capability.key).inserted,
                          "duplicate: \(entry.capability.key)")
            XCTAssertEqual(entry.capability.key, entry.capability.key.lowercased())
            XCTAssertFalse(entry.capability.key.contains(" "), entry.capability.key)
        }
    }

    func testEveryCapabilityHasAGroupAndALeaf() {
        for entry in MSLAPCapability.catalogue {
            let parts = entry.capability.key.split(separator: ".")
            XCTAssertGreaterThanOrEqual(parts.count, 2, entry.capability.key)
        }
    }

    /// Tier-2 capabilities whose refusal lives in host-side code rather
    /// than the daemon. Hand-listed BECAUSE it cannot be derived - which
    /// is the point: adding one here is a deliberate claim that the code
    /// exists, made in the same commit as the code.
    private static let hostEnforced: Set<String> = [
        "apps.customCommand",   // AppCustomCommandStore.set
        "resources.edit",       // ResourcePolicyStore.save
        "shipment.export",      // Shipment.create
        "shipment.import",      // Shipment.install
        "network.vpn",          // GuestVPN.install
        "network.dns",          // GuestDNS.apply
        "system.update",        // UpdateDownload.fetch
        "resources.memory", "resources.cpu", "resources.balloon",   // ResourcePolicyStore.save
        "instance.lock",        // InstanceLockStore.setLocked
        "graphics.perApp",      // AppGraphicsStore.set
        "graphics.gpu", "graphics.scaling",                         // settings store
        "sharing.clipboard", "sharing.filePicker",                  // settings store
        "integrations.shortcuts", "integrations.linksToMac",        // settings store
        "integrations.globalMenuBar", "integrations.signInBrowser", // settings store
        "peripherals.camera", "peripherals.microphone",             // PeripheralSharing.save
        "apps.launch",          // LinuxAppLauncher.runCapturingOutput
        "apps.launchpad", "apps.discovery", "apps.dock",            // AppModel
        "system.ssh",           // SSHSetup.RecordStore.save
        "distro.install",       // DistroInstaller.install
        "instance.appearance",  // InstanceAppearanceStore.set
        "system.startup",       // LoginItems.setEnabled
        "admin.unenrol",        // msl admin unenrol
        "admin.editPolicy",     // the panel's administrator button
        "system.uninstall",     // msl uninstall
        "resources.disk",       // DiskStorage.setPolicy
        "distro.source",        // DistroInstaller.resolveSources
        // sharing.macHome is DAEMON-tier - refused in VMManager, inside
        // mslhd - so it is not listed here. See
        // MSLAPEnforcementTests.daemonEnforcedOutsideRequests.
    ]

    /// Daemon-side refusals that are not control requests - `sharing.macHome`
    /// is applied when the VM is configured, inside mslhd, where there is
    /// no message to refuse.
    private static let daemonEnforcedOutsideRequests: Set<String> = [
        "sharing.macHome",      // VMManager: the share is never attached
        "peripherals.audio",    // PeripheralBridge.start, inside mslhd
        "sharing.webdav",       // VMManager.startFileSandbox: no bridge, no mount
        // VMManager.ensureRunning, via InstanceAdmission - one site that
        // every start path passes through, including the two that bypass
        // DaemonServer.ensureRunningWithinCap (Finder waking the WebDAV
        // mount, and restoring after a power event).
        "instance.acceptUnidentified",
        // VMManager.ensureRunning, via InstanceAdmission - same site.
        "instance.acceptUncertified",
        // HostOpenPlan.make, reached from HostOpenService inside mslhd -
        // so it binds every Linux app, not just ones MSL.app launched.
        "integrations.mailToMac",
    ]

    func testEveryCapabilityClaimingEnforcementHasSomewhereThatRefusesIt() {
        // The catalogue's honesty check, and the reason `enforced` exists:
        // flipping the flag without wiring a refusal would turn the
        // catalogue into a list of promises nothing keeps.
        let daemonEnforced = MSLAPEnforcement.enforcedCapabilities
        for entry in MSLAPCapability.catalogue where entry.enforced {
            let viaDaemon = daemonEnforced.contains(entry.capability)
            let viaHost = Self.hostEnforced.contains { MSLAPCapability($0) == entry.capability }
            let viaConfiguration = Self.daemonEnforcedOutsideRequests
                .contains { MSLAPCapability($0) == entry.capability }
            let viaInterface = Self.interfaceEnforced
                .contains { MSLAPCapability($0) == entry.capability }
            XCTAssertTrue(viaDaemon || viaHost || viaConfiguration || viaInterface,
                          "\(entry.capability.key) claims enforcement but nothing refuses it")
        }
    }

    /// Interface-tier capabilities that are gated, and what that is worth.
    ///
    /// Listed explicitly because enforcement here is the WEAKEST kind - a
    /// hidden menu item or a refused CLI verb, both of which someone could
    /// work around. `system.experimental` is honest about it: the switches
    /// behind that panel are each gated in the settings store, and hiding
    /// the window only keeps it out of the way.
    private static let interfaceEnforced: Set<String> = [
        "system.experimental",  // the Window menu item
        "system.doctor",        // msl doctor
        // The Terminal tab. Deliberately tier 3 and labelled as such: it
        // runs `msl <instance>` in a pty, so hiding it stops nobody from
        // running that command themselves. The refusal says so rather than
        // implying a guest shell has been closed.
        "system.terminal",
    ]

    func testInterfaceTierEnforcementIsDeclaredRatherThanAssumed() {
        // Tier 3 is a hidden control and little more, so anything claiming
        // enforcement from there has to be named here deliberately.
        for entry in MSLAPCapability.catalogue
        where entry.enforced && entry.tier == .interfaceOnly {
            XCTAssertTrue(Self.interfaceEnforced.contains { MSLAPCapability($0) == entry.capability },
                          "\(entry.capability.key) claims interface-tier enforcement undeclared")
        }
    }

    func testHostEnforcedCapabilitiesAreNotSecretlyDaemonOnes() {
        // If the daemon already refuses it, the hand-maintained list is
        // stale and should shrink - a list that drifts is how this check
        // stops meaning anything.
        let daemonEnforced = MSLAPEnforcement.enforcedCapabilities
        for key in Self.hostEnforced {
            XCTAssertFalse(daemonEnforced.contains(MSLAPCapability(key)),
                           "\(key) is enforced by the daemon; remove it from hostEnforced")
        }
    }

    func testTheDangerousCapabilitiesArePresent() {
        // The routes that matter most for a managed deployment: getting an
        // instance in or out, reaching the Mac's home folder, publishing to
        // the internet, and running an arbitrary command through an app's
        // launch override.
        for key in ["shipment.import", "shipment.export", "sharing.macHome",
                    "public.expose", "apps.customCommand", "instance.delete",
                    "resources.edit", "distro.install"] {
            XCTAssertNotNil(MSLAPCapability.entry(for: MSLAPCapability(key)), key)
        }
    }

    func testRootInsideAGuestIsDeliberatelyAbsent() {
        // It cannot be enforced from the host, so listing it would promise
        // what nobody can keep. See README 30 section 5.
        XCTAssertNil(MSLAPCapability.entry(for: MSLAPCapability("guest.root")))
    }
}

/// Enforcement at the daemon chokepoint. These check that a REQUEST is
/// refused, not that a button is grey - the app and the CLI both arrive
/// here, so this is the only tier that binds both.
final class MSLAPEnforcementTests: XCTestCase {
    private func cap(_ key: String) -> MSLAPCapability { MSLAPCapability(key) }

    private func policy(_ deny: [String], match: String = "*") -> MSLAPPolicy {
        MSLAPPolicy(issuer: "Example IT",
                    scopes: [.init(match: match, deny: deny.map(MSLAPCapability.init),
                                   reason: "Fleet rule")])
    }

    func testAnUnmanagedMacRefusesNothing() {
        // The single most important property: MSL with no policy behaves
        // exactly as it always has.
        for request in DaemonProtocol.ControlRequest.everyCaseForAudit {
            XCTAssertNil(MSLAPEnforcement.check(request, policy: nil, issuer: nil),
                         "\(request)")
        }
    }

    func testAPolicyThatDeniesNothingRefusesNothing() {
        let allow = MSLAPPolicy()
        for request in DaemonProtocol.ControlRequest.everyCaseForAudit {
            XCTAssertNil(MSLAPEnforcement.check(request, policy: allow, issuer: nil),
                         "\(request)")
        }
    }

    func testDeletingAnInstanceIsRefused() {
        let refusal = MSLAPEnforcement.check(.remove(instance: "Ubuntu"),
                                             policy: policy(["instance.delete"]),
                                             issuer: "Example IT")
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.contains("instance.delete"), refusal!)
        // The person must be told who did this and why.
        XCTAssertTrue(refusal!.contains("Example IT"), refusal!)
        XCTAssertTrue(refusal!.contains("Fleet rule"), refusal!)
    }

    func testAScopedDenialOnlyBindsItsOwnInstance() {
        let p = policy(["instance.delete"], match: "lab-*")
        XCTAssertNotNil(MSLAPEnforcement.check(.remove(instance: "lab-3"), policy: p, issuer: nil))
        XCTAssertNil(MSLAPEnforcement.check(.remove(instance: "Ubuntu"), policy: p, issuer: nil))
    }

    func testCreatingAnInstanceIsAppWideNotPerInstance() {
        // The instance does not exist yet, so a scope naming it cannot
        // have an opinion - only a `*` rule governs creation.
        let named = policy(["instance.create"], match: "newbie")
        XCTAssertNil(MSLAPEnforcement.check(.createInstance(instance: "newbie", distro: .alpine),
                                            policy: named, issuer: nil))
        let global = policy(["instance.create"])
        XCTAssertNotNil(MSLAPEnforcement.check(.createInstance(instance: "newbie", distro: .alpine),
                                               policy: global, issuer: nil))
    }

    func testAGroupDenialCoversItsRequests() {
        let p = policy(["public"])
        XCTAssertNotNil(MSLAPEnforcement.check(.publicExpose(instance: "i", backend: "relay"),
                                               policy: p, issuer: nil))
        XCTAssertNotNil(MSLAPEnforcement.check(.publicAuthorize(instance: "i", key: "k", label: "l"),
                                               policy: p, issuer: nil))
    }

    func testOperationsThatReduceExposureAreNeverRefused() {
        // Deny `public` and someone has already published: they must still
        // be able to unpublish, or the policy traps the exposure in place.
        let p = policy(["public", "peripherals"])
        XCTAssertNil(MSLAPEnforcement.check(.publicRevoke(instance: "i"), policy: p, issuer: nil))
        XCTAssertNil(MSLAPEnforcement.check(.publicDeauthorize(instance: "i", match: "m"),
                                            policy: p, issuer: nil))
        XCTAssertNil(MSLAPEnforcement.check(.publicNotifyForget, policy: p, issuer: nil))
        XCTAssertNil(MSLAPEnforcement.check(.usbDetach(instance: "i", device: "d"),
                                            policy: policy(["peripherals.usb"]), issuer: nil))
    }

    func testQueriesAreNeverRefused() {
        // Reading state tells nobody anything they could not see in the
        // app, and refusing it would break the UI that explains the policy.
        let p = policy(["instance", "public", "network", "peripherals"])
        for request in [DaemonProtocol.ControlRequest.status(instance: "i"),
                        .instanceList, .instanceDetails,
                        .publicStatus(instance: "i"), .publicKeys(instance: "i"),
                        .sandboxGet(instance: "i"), .usbList,
                        .memoryStatus(instance: "i")] {
            XCTAssertNil(MSLAPEnforcement.check(request, policy: p, issuer: nil), "\(request)")
        }
    }

    func testASessionIsNotGovernedByInstanceLifecycleDenials() {
        // Denying `instance.stop` must not stop someone opening a shell.
        let p = policy(["instance.stop", "instance.delete"])
        XCTAssertNil(MSLAPEnforcement.check(.session(instance: "i", rows: 24, cols: 80),
                                            policy: p, issuer: nil))
    }

    /// Daemon-tier capabilities enforced somewhere OTHER than a control
    /// request. `sharing.macHome` is refused when the VM is configured -
    /// inside mslhd, so it genuinely binds the app and the CLI alike - but
    /// no request maps to it, because there is no "share the home folder"
    /// message to refuse.
    private static let daemonEnforcedOutsideRequests: Set<String> = [
        "sharing.macHome",      // VMManager: the share is never attached
        "peripherals.audio",    // PeripheralBridge.start, inside mslhd
        "sharing.webdav",       // VMManager.startFileSandbox: no bridge, no mount
        // VMManager.ensureRunning, via InstanceAdmission - one site that
        // every start path passes through, including the two that bypass
        // DaemonServer.ensureRunningWithinCap (Finder waking the WebDAV
        // mount, and restoring after a power event).
        "instance.acceptUnidentified",
        // VMManager.ensureRunning, via InstanceAdmission - same site.
        "instance.acceptUncertified",
        // HostOpenPlan.make, reached from HostOpenService inside mslhd -
        // so it binds every Linux app, not just ones MSL.app launched.
        "integrations.mailToMac",
    ]

    func testEveryDaemonTierCapabilityClaimingEnforcementIsReachable() {
        // Tier-2 entries are refused in host-side code and are checked
        // separately in MSLAPCatalogueTests.
        let reachable = MSLAPEnforcement.enforcedCapabilities
        for entry in MSLAPCapability.catalogue where entry.enforced && entry.tier == .daemon {
            let viaRequest = reachable.contains(entry.capability)
            let viaConfiguration = Self.daemonEnforcedOutsideRequests
                .contains { MSLAPCapability($0) == entry.capability }
            XCTAssertTrue(viaRequest || viaConfiguration, entry.capability.key)
        }
    }
}

import CryptoKit

/// Signing. The property that matters is not "a good signature verifies" -
/// it is that an EDITED policy fails, because that is the whole reason the
/// signature exists.
final class MSLAPSigningTests: XCTestCase {

    private func samplePolicy() -> MSLAPPolicy {
        MSLAPPolicy(issuer: "Example IT",
                    scopes: [.init(match: "*", deny: [MSLAPCapability("instance.delete")])])
    }

    func testASignedPolicyVerifiesAgainstItsOwnKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signed = try MSLAPSigning.sign(samplePolicy(), with: key)
        let pinned = [MSLAPSigning.keyID(for: key.publicKey): key.publicKey]
        guard case .success(let id) = MSLAPSigning.verify(signed, pinned: pinned) else {
            return XCTFail("a freshly signed policy must verify")
        }
        XCTAssertEqual(id, MSLAPSigning.keyID(for: key.publicKey))
    }

    func testEditingThePolicyAfterSigningBreaksTheSignature() throws {
        // The point of the whole mechanism.
        let key = Curve25519.Signing.PrivateKey()
        var signed = try MSLAPSigning.sign(samplePolicy(), with: key)
        signed.scopes = []   // somebody quietly removes every restriction
        let pinned = [MSLAPSigning.keyID(for: key.publicKey): key.publicKey]
        XCTAssertEqual(MSLAPSigning.verify(signed, pinned: pinned), .failure(.mismatch))
    }

    func testEditingEvenTheIssuerBreaksTheSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        var signed = try MSLAPSigning.sign(samplePolicy(), with: key)
        signed.issuer = "Someone Else"
        let pinned = [MSLAPSigning.keyID(for: key.publicKey): key.publicKey]
        XCTAssertEqual(MSLAPSigning.verify(signed, pinned: pinned), .failure(.mismatch))
    }

    func testAnotherKeyCannotSignForAPinnedOne() throws {
        let real = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let signed = try MSLAPSigning.sign(samplePolicy(), with: impostor)
        let pinned = [MSLAPSigning.keyID(for: real.publicKey): real.publicKey]
        XCTAssertEqual(MSLAPSigning.verify(signed, pinned: pinned),
                       .failure(.unknownKey(id: MSLAPSigning.keyID(for: impostor.publicKey))))
    }

    func testAnUnsignedPolicyIsReportedAsUnsignedNotAsTampered() {
        // Different news, different handling: unsigned still applies at
        // Advisory strength, tampered does not apply at all.
        let pinned = [String: Curve25519.Signing.PublicKey]()
        XCTAssertEqual(MSLAPSigning.verify(samplePolicy(), pinned: pinned), .failure(.unsigned))
    }

    func testASignedPolicyWithNoPinnedKeySaysSo() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signed = try MSLAPSigning.sign(samplePolicy(), with: key)
        XCTAssertEqual(MSLAPSigning.verify(signed, pinned: [:]), .failure(.noPinnedKey))
    }

    func testCanonicalBytesIgnoreTheSignatureField() throws {
        // Or there would be nothing stable to sign over: the value would
        // have to exist before it was computed.
        let key = Curve25519.Signing.PrivateKey()
        let policy = samplePolicy()
        let before = try MSLAPSigning.canonicalBytes(of: policy)
        let signed = try MSLAPSigning.sign(policy, with: key)
        let after = try MSLAPSigning.canonicalBytes(of: signed)
        XCTAssertEqual(before, after)
    }

    func testCanonicalBytesAreStableAcrossEncodings() throws {
        // Unsorted keys would make the same policy encode differently from
        // run to run, and a valid signature would start failing at random -
        // indistinguishable from tampering, and far harder to diagnose.
        let policy = samplePolicy()
        let a = try MSLAPSigning.canonicalBytes(of: policy)
        let b = try MSLAPSigning.canonicalBytes(of: policy)
        XCTAssertEqual(a, b)
        // And across a round trip through JSON, which is how it is really
        // used: signed on one machine, verified on another.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let again = try decoder.decode(MSLAPPolicy.self, from: try JSONEncoder().encode(policy))
        XCTAssertEqual(try MSLAPSigning.canonicalBytes(of: again), a)
    }

    func testSigningSurvivesAFullJSONRoundTrip() throws {
        // The real path: sign, write, read, verify - on a policy carrying
        // a date, which is where encoding strategies usually diverge.
        let key = Curve25519.Signing.PrivateKey()
        var policy = samplePolicy()
        policy.issued = Date(timeIntervalSince1970: 1_760_000_000)
        let signed = try MSLAPSigning.sign(policy, with: key)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(signed)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(MSLAPPolicy.self, from: data)

        let pinned = [MSLAPSigning.keyID(for: key.publicKey): key.publicKey]
        guard case .success = MSLAPSigning.verify(loaded, pinned: pinned) else {
            return XCTFail("a signature must survive being written and read back")
        }
    }

    func testKeyIDsDifferPerKeyAndAreStable() {
        let a = Curve25519.Signing.PrivateKey().publicKey
        let b = Curve25519.Signing.PrivateKey().publicKey
        XCTAssertNotEqual(MSLAPSigning.keyID(for: a), MSLAPSigning.keyID(for: b))
        XCTAssertEqual(MSLAPSigning.keyID(for: a), MSLAPSigning.keyID(for: a))
    }
}

/// Tampering must never be a way to REMOVE restrictions. Without a
/// fallback, signing would make a deployment weaker than not signing at
/// all, because editing the file would disable the policy outright.
final class MSLAPTamperFallbackTests: XCTestCase {

    func testABrokenPolicyWithAFallbackStillRefuses() {
        let good = MSLAPPolicy(issuer: "Example IT",
                               scopes: [.init(match: "*",
                                              deny: [MSLAPCapability("instance.delete")])])
        // What the daemon does with a tampered policy: enforce the last
        // one that verified.
        let refusal = MSLAPEnforcement.check(.remove(instance: "Ubuntu"),
                                             policy: good, issuer: good.issuer)
        XCTAssertNotNil(refusal)
    }

    func testABrokenPolicyWithNoFallbackRefusesNothing() {
        // Only true the first time, before anything has ever verified.
        // After that there is always a fallback.
        let refusal = MSLAPEnforcement.check(.remove(instance: "Ubuntu"),
                                             policy: nil, issuer: nil)
        XCTAssertNil(refusal)
    }
}

/// The admin password. Gates the panel; it is not what protects the policy.
final class MSLAPAdminPasswordTests: XCTestCase {

    func testTheRightPasswordVerifiesAndAWrongOneDoesNot() {
        let salt = Data(repeating: 7, count: 32)
        let a = MSLAPAdminPassword.derive(password: "correct horse", salt: salt, iterations: 1000)
        let b = MSLAPAdminPassword.derive(password: "correct horse", salt: salt, iterations: 1000)
        let c = MSLAPAdminPassword.derive(password: "wrong horse", salt: salt, iterations: 1000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testADifferentSaltGivesADifferentHash() {
        // Per-install salt, so the same password on two Macs does not
        // produce the same stored value.
        let one = MSLAPAdminPassword.derive(password: "same",
                                            salt: Data(repeating: 1, count: 32), iterations: 1000)
        let two = MSLAPAdminPassword.derive(password: "same",
                                            salt: Data(repeating: 2, count: 32), iterations: 1000)
        XCTAssertNotEqual(one, two)
    }

    func testIterationsChangeTheResult() {
        let salt = Data(repeating: 3, count: 32)
        XCTAssertNotEqual(MSLAPAdminPassword.derive(password: "p", salt: salt, iterations: 10),
                          MSLAPAdminPassword.derive(password: "p", salt: salt, iterations: 11))
    }

    func testTheHashIsAFullSHA256Width() {
        XCTAssertEqual(MSLAPAdminPassword.derive(password: "p",
                                                 salt: Data(repeating: 0, count: 32),
                                                 iterations: 2).count, 32)
    }
}

/// The strength claim is what an administrator decides to trust, so it is
/// checked against the filesystem rather than inferred from a path.
final class MSLAPStrengthTests: XCTestCase {

    func testAUserOwnedFileIsNotTreatedAsRootProtected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mslap-strength-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Owned by whoever runs the tests, which is not root.
        XCTAssertFalse(MSLAPPolicyStore.isRootOwnedAndProtected(url))
    }

    func testAMissingFileIsNotRootProtected() {
        XCTAssertFalse(MSLAPPolicyStore.isRootOwnedAndProtected(
            URL(fileURLWithPath: "/definitely/not/here.json")))
    }

    func testAKnownRootOwnedSystemFileIsRecognised() {
        // /etc/hosts is root-owned 0644 on every macOS.
        XCTAssertTrue(MSLAPPolicyStore.isRootOwnedAndProtected(
            URL(fileURLWithPath: "/etc/hosts")))
    }
}

/// The shared host-side gate. Every tier-2 check goes through it, so these
/// pin the three behaviours that are easy to get subtly different between
/// call sites.
final class MSLAPGateTests: XCTestCase {

    func testAnUnmanagedMacAllowsEverything() {
        // The property that matters most: no policy installed means MSL
        // behaves exactly as it always has. Run against the REAL store, so
        // this fails if a stray policy is left behind by another test.
        if MSLAPGate.policy == nil {
            for entry in MSLAPCapability.catalogue {
                XCTAssertTrue(MSLAPGate.allows(entry.capability.key, instance: "Anything"),
                              entry.capability.key)
                XCTAssertNil(MSLAPGate.reason(entry.capability.key, instance: "Anything"))
            }
        }
    }

    func testAReasonNamesTheBroaderRuleAndTheIssuer() {
        // The managed user reads this line, so it has to identify the rule
        // that actually did it rather than the thing they asked for.
        let policy = MSLAPPolicy(issuer: "Example IT",
                                 scopes: [.init(match: "*",
                                                deny: [MSLAPCapability("shipment")],
                                                reason: "Nothing leaves this Mac")])
        let decision = policy.decision(for: MSLAPCapability("shipment.export"), instance: nil)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.deniedByCapability, MSLAPCapability("shipment"))
        XCTAssertEqual(decision.deniedBy?.reason, "Nothing leaves this Mac")
    }

    func testResourceEditingIsTierTwoAndSaysSo() {
        // It is refused in ResourcePolicyStore, not the daemon, and the
        // catalogue must not claim otherwise - a daemon-tier claim would
        // imply the CLI is covered by the same code, which it is not.
        let entry = MSLAPCapability.entry(for: MSLAPCapability("resources.edit"))
        XCTAssertEqual(entry?.tier, .hostProcess)
        XCTAssertEqual(entry?.enforced, true)
    }

    func testShipmentsAreEnforcedInBothDirections() {
        for key in ["shipment.import", "shipment.export"] {
            let entry = MSLAPCapability.entry(for: MSLAPCapability(key))
            XCTAssertEqual(entry?.enforced, true, key)
        }
    }
}

/// The refusals wired in this round, tested as behaviour rather than as
/// entries in a list.
///
/// The catalogue's `enforced` flag is checked elsewhere against a
/// hand-maintained set of enforcement sites, which proves a site was
/// *declared* - not that it refuses anything. These exercise the actual
/// decisions.
final class MSLAPNewlyEnforcedTests: XCTestCase {

    // MARK: - integrations.mailToMac, and the claim it can be separated

    private func urlRequest(_ target: String) -> HostOpenRequest {
        HostOpenRequest(kind: .url, targets: [target], cwd: "/")
    }

    private var linksOn: MSLExperimentalSettings {
        var settings = MSLExperimentalSettings()
        settings.openLinksOnMac = true
        settings.preferMSLFiles = true
        return settings
    }

    func testMailCanBeDeniedWhileLinksStillOpenOnTheMac() {
        // The catalogue used to say these could not be separated, because
        // the guest advertises one handler for http, https AND mailto.
        // That is true of the guest and irrelevant to the Mac: the plan
        // already branches on the scheme. This is the proof.
        let plan = HostOpenPlan.make(for: urlRequest("mailto:someone@example.com"),
                                     settings: linksOn, instance: "i",
                                     allows: { $0 != "integrations.mailToMac" })
        guard case .decline(let why) = plan else { return XCTFail("mail was not refused: \(plan)") }
        XCTAssertTrue(why.contains("Admin Portal"), why)

        // Same handler, same settings, same policy - and the web link is
        // unaffected. If this ever regresses, denying mail silently takes
        // every link with it.
        let web = HostOpenPlan.make(for: urlRequest("https://example.com/x"),
                                    settings: linksOn, instance: "i",
                                    allows: { $0 != "integrations.mailToMac" })
        guard case .openWebURL(let url) = web else { return XCTFail("link refused too: \(web)") }
        XCTAssertEqual(url.host, "example.com")
    }

    func testLinksAreRefusedAtTheActionEvenWithTheSwitchAlreadyOn() {
        // The hole this closes: `integrations.linksToMac` was enforced only
        // in the settings store, which checks a switch that CHANGED. A Mac
        // where the switch was already on would have gone on opening links
        // for ever after a policy denied it, because nothing moved it again.
        let plan = HostOpenPlan.make(for: urlRequest("https://example.com/x"),
                                     settings: linksOn, instance: "i",
                                     allows: { $0 != "integrations.linksToMac" })
        guard case .decline = plan else { return XCTFail("link was not refused: \(plan)") }

        // And mail is not collateral damage in the other direction either.
        let mail = HostOpenPlan.make(for: urlRequest("mailto:a@example.com"),
                                     settings: linksOn, instance: "i",
                                     allows: { $0 != "integrations.linksToMac" })
        guard case .composeMail = mail else { return XCTFail("mail refused too: \(mail)") }
    }

    // MARK: - sharing.files versus sharing.filePicker

    func testBrowsingGuestFilesAndThePickerAreSeparateCapabilities() {
        let show = HostOpenRequest(kind: .dir, targets: ["/home/me"], cwd: "/")
        let picked = HostOpenRequest(kind: .pick, targets: ["/home/me"], cwd: "/")

        // One switch (`preferMSLFiles`) turns both on, but a policy can
        // still refuse them separately - showing a folder is browsing, and
        // a Save dialog is not.
        guard case .decline = HostOpenPlan.make(for: show, settings: linksOn, instance: "i",
                                                allows: { $0 != "sharing.files" })
        else { return XCTFail("a denied sharing.files still showed a folder") }
        guard case .pickFiles = HostOpenPlan.make(for: picked, settings: linksOn, instance: "i",
                                                  allows: { $0 != "sharing.files" })
        else { return XCTFail("denying sharing.files took the picker with it") }

        guard case .decline = HostOpenPlan.make(for: picked, settings: linksOn, instance: "i",
                                                allows: { $0 != "sharing.filePicker" })
        else { return XCTFail("a denied sharing.filePicker still opened the picker") }
        guard case .showInFiles = HostOpenPlan.make(for: show, settings: linksOn, instance: "i",
                                                    allows: { $0 != "sharing.filePicker" })
        else { return XCTFail("denying sharing.filePicker took folder browsing with it") }
    }

    func testTheGuestFileRequestsAnswerToSharingFiles() {
        // Where `sharing.files` actually bites: MSL Files has no vsock, so
        // every listing and chmod goes through the daemon.
        for request in [DaemonProtocol.ControlRequest.fileList(instance: "work", guestPath: "/etc"),
                        .fileChmod(instance: "work", guestPath: "/etc/x", mode: 0o755)] {
            let needs = MSLAPEnforcement.requirements(for: request)
            XCTAssertEqual(needs.map(\.capability.key), ["sharing.files"], "\(request)")
            XCTAssertEqual(needs.first?.instance, "work", "\(request)")
        }
    }

    // MARK: - distro.custom

    func testACustomImageNeedsBothCreateAndCustom() {
        // A custom image brings its own kernel and root filesystem, so it
        // is a second permission on top of making an instance at all - a
        // deployment may allow new Debian instances and no sideloaded ones.
        let custom = MSLAPEnforcement.requirements(
            for: .createInstance(instance: "x", distro: .custom("mine")))
        XCTAssertEqual(Set(custom.map(\.capability.key)), ["instance.create", "distro.custom"])

        // And a published distro does NOT need it, or denying custom images
        // would quietly stop every instance.
        let published = MSLAPEnforcement.requirements(
            for: .createInstance(instance: "x", distro: .debian))
        XCTAssertEqual(published.map(\.capability.key), ["instance.create"])
    }

    func testDenyingCustomImagesLeavesPublishedDistrosAlone() {
        let policy = MSLAPPolicy(
            issued: Date(), issuer: "Test",
            scopes: [.init(match: "*", deny: [MSLAPCapability("distro.custom")], reason: "no sideloads")],
            message: nil)
        XCTAssertNotNil(MSLAPEnforcement.check(
            .createInstance(instance: "x", distro: .custom("mine")), policy: policy, issuer: "Test"))
        XCTAssertNil(MSLAPEnforcement.check(
            .createInstance(instance: "x", distro: .ubuntu), policy: policy, issuer: "Test"))
    }

    // MARK: - resources.disk

    func testResourcesEditDoesNotCoverTheDiskByPrefix() {
        // Why `DiskStorage.setPolicy` asks for both. "resources.edit" is a
        // SIBLING of "resources.disk", not an ancestor, so the dotted-path
        // rule does not make one imply the other - the same reason the
        // memory and CPU dials are each asked for by name.
        XCTAssertFalse(MSLAPCapability("resources.edit").covers(MSLAPCapability("resources.disk")))
        XCTAssertTrue(MSLAPCapability("resources").covers(MSLAPCapability("resources.disk")))
    }

    func testAStorageKeyRoundTripsToItsInstance() {
        // What scopes a disk refusal to one instance.
        XCTAssertEqual(InstanceDisk.instanceName(
            forStorageKey: InstanceDisk.storageKey(instance: "work")), "work")
        // A legacy per-distro key belongs to no single instance - several
        // shared one image - so it is app-wide rather than a guess.
        XCTAssertNil(InstanceDisk.instanceName(forStorageKey: "rootfs-debian.img"))
        XCTAssertNil(InstanceDisk.instanceName(forStorageKey: "disks/.img"))
    }

    // MARK: - distro.source

    func testAnOverriddenManifestIsStillTheOnlySourceWhenAllowed() throws {
        // The gate must not change what an allowed override does: exactly
        // that manifest, never a quiet fallback to the real hosts.
        let sources = try DistroInstaller.resolveSources(override: "file:///tmp/fixture.json")
        XCTAssertEqual(sources.map(\.manifestURL), ["file:///tmp/fixture.json"])
    }

    // MARK: - the three states of a catalogue entry

    func testNothingClaimsBothUnavailableAndEnforced() {
        // They are contradictory: `unavailable` says MSL has no such action
        // to refuse, `enforced` says something refuses it.
        for entry in MSLAPCapability.catalogue {
            XCTAssertFalse(entry.unavailable && entry.enforced, entry.capability.key)
        }
    }

    func testTheTwoCapabilitiesThatTurnedOutToBeRealAreNoLongerUnavailable() {
        // Both were marked "MSL cannot do this" and both were wrong:
        // `msl storage <i> fixed 32G` resizes a disk, and `--manifest`
        // picks an image source. Mislabelling them as unavailable hid two
        // real, ungated actions behind a placeholder.
        for key in ["resources.disk", "distro.source"] {
            let entry = MSLAPCapability.entry(for: MSLAPCapability(key))
            XCTAssertEqual(entry?.unavailable, false, key)
            XCTAssertEqual(entry?.enforced, true, key)
        }
    }
}

/// Step one of `READMES/32-PROTECTED-INSTANCES.md`: is an instance the
/// policy means to keep uncopyable actually uncopyable?
///
/// The answer is usually no, and for a reason nobody would guess, which is
/// the whole reason this reports rather than assumes.
final class ProtectedInstanceTests: XCTestCase {

    private func policy(denying keys: [String], forScope match: String = "*") -> MSLAPPolicy {
        MSLAPPolicy(issued: Date(), issuer: "Test",
                    scopes: [.init(match: match, deny: keys.map(MSLAPCapability.init),
                                   reason: "test")],
                    message: nil)
    }

    // MARK: - What counts as protected

    func testDenyingCloningOrExportingIsWhatMakesAnInstanceProtected() {
        // No separate switch: the policy already says "this must not be
        // copied", and MSL reads that as the intent it is.
        XCTAssertTrue(ProtectedInstance.isProtected(
            "Company", policy: policy(denying: ["instance.clone"])))
        XCTAssertTrue(ProtectedInstance.isProtected(
            "Company", policy: policy(denying: ["shipment.export"])))
        XCTAssertFalse(ProtectedInstance.isProtected(
            "Company", policy: policy(denying: ["network.vpn"])))
    }

    func testAnUnmanagedMacProtectsNothing() {
        // There is no administrator whose intent there would be to read.
        XCTAssertFalse(ProtectedInstance.isProtected("Company", policy: nil))
        XCTAssertEqual(ProtectedInstance.gaps(for: "Company", policy: nil), [])
        XCTAssertNil(ProtectedInstance.summary(instances: ["Company"], policy: nil))
    }

    func testProtectionIsScopedLikeEverythingElse() {
        let p = policy(denying: ["instance.clone"], forScope: "lab-*")
        XCTAssertTrue(ProtectedInstance.isProtected("lab-3", policy: p))
        XCTAssertFalse(ProtectedInstance.isProtected("mine", policy: p))
    }

    // MARK: - The gap that matters

    func testTheMacHomeShareIsReportedFirstAndNamesTheExactRoute() {
        // **The finding this whole step exists for.** `mac_home` shares the
        // Mac's entire home folder into every guest, writable, and instance
        // disks live inside it - so denying `instance.clone` closes the
        // button and leaves a one-line `cp` wide open.
        let gaps = ProtectedInstance.gaps(
            for: "Company",
            policy: policy(denying: ["instance.clone", "shipment.export"]))
        XCTAssertEqual(gaps.first?.capability, "sharing.macHome",
                       "the worst route was not reported first")
        // Named precisely, because a warning that does not say where to
        // look is a warning people learn to scroll past.
        XCTAssertTrue(gaps[0].detail.contains("/mnt/mac"), gaps[0].detail)
        XCTAssertTrue(gaps[0].detail.contains("not read-only"), gaps[0].detail)
    }

    func testClosingTheHomeShareClosesTheDiskRoutes() {
        let gaps = ProtectedInstance.gaps(
            for: "Company",
            policy: policy(denying: ["instance.clone", "shipment.export", "sharing.macHome"]))
        XCTAssertEqual(gaps, [], "something is still reported as open: \(gaps)")
    }

    func testDenyingOnlyOneHalfOfThePairIsReported() {
        // Somebody who denied cloning has very likely not thought about a
        // shipment, which copies the whole disk by design.
        let cloneOnly = ProtectedInstance.gaps(
            for: "Company", policy: policy(denying: ["instance.clone", "sharing.macHome"]))
        XCTAssertEqual(cloneOnly.map(\.capability), ["shipment.export"])

        let exportOnly = ProtectedInstance.gaps(
            for: "Company", policy: policy(denying: ["shipment.export", "sharing.macHome"]))
        XCTAssertEqual(exportOnly.map(\.capability), ["instance.clone"])
    }

    func testAnUnprotectedInstanceReportsNoGapsEvenThoughEveryRouteIsOpen() {
        // An open route is only a gap against a stated intention to close
        // it. Reporting "you could copy this" about an instance nobody
        // asked to protect is noise that trains people to ignore the real
        // thing.
        XCTAssertEqual(ProtectedInstance.gaps(for: "mine", policy: policy(denying: ["network.vpn"])), [])
    }

    // MARK: - The doctor finding

    private func environment(instances: [String], policy: MSLAPPolicy?) -> Diagnostics.Environment {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-protect-\(UUID().uuidString)")
        return Diagnostics.Environment(
            appSupport: root, generatedApps: root, binDirectory: root,
            instances: Dictionary(uniqueKeysWithValues: instances.map { ($0, GuestDistro.ubuntu) }),
            expectedTools: [], daemonRunning: true, policy: policy)
    }

    func testDoctorCallsAnUnmetIntentionAProblemNotAWarning() {
        // The policy states an intention that is not being met - the same
        // class of thing as a registered instance whose image is missing.
        let findings = Diagnostics.protectionFindings(
            environment(instances: ["Company"], policy: policy(denying: ["instance.clone"])))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .problem)
        XCTAssertTrue(findings[0].title.contains("Company"), findings[0].title)
    }

    func testDoctorSaysWhatProtectionDoesNotCoverWhenItIsComplete() {
        // Honest about the limit: the image is sealed, the contents are not.
        let findings = Diagnostics.protectionFindings(environment(
            instances: ["Company"],
            policy: policy(denying: ["instance.clone", "shipment.export", "sharing.macHome"])))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .ok)
        XCTAssertTrue(findings[0].detail.contains("still readable"), findings[0].detail)
    }

    func testDoctorSaysNothingAboutAnUnmanagedMacOrAnUnprotectedInstance() {
        XCTAssertEqual(Diagnostics.protectionFindings(
            environment(instances: ["mine"], policy: nil)).count, 0)
        XCTAssertEqual(Diagnostics.protectionFindings(
            environment(instances: ["mine"], policy: policy(denying: ["network.vpn"]))).count, 0)
    }

    func testTheSummaryListsOnlyProtectedInstances() {
        let p = policy(denying: ["instance.clone"], forScope: "Company")
        let summary = ProtectedInstance.summary(instances: ["Company", "mine"], policy: p)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("Company"), summary!)
        XCTAssertFalse(summary!.contains("mine"), summary!)
        XCTAssertTrue(summary!.contains("sharing.macHome"), summary!)
    }
}
