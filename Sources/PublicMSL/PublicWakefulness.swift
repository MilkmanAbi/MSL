// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while something is published.
///
/// Everything else about this feature can be perfect and it still fails if
/// the Mac goes to sleep: the tunnel's socket dies, the guest stops, and a
/// colleague's `ssh` hangs. A machine somebody is treating as a small
/// server has to stay a machine.
///
/// ## What it holds, and what it deliberately does not
///
/// `PreventUserIdleSystemSleep` only stops the Mac dozing off **on its
/// own**. Closing the lid still sleeps it, and so does choosing Sleep -
/// which is correct, and the honest limit to state: a laptop in a bag is
/// not a server, and no assertion should pretend otherwise. MSL already
/// handles waking up again (see the sleep/wake work), so a lid-closed Mac
/// comes back and the watcher re-opens the tunnel.
///
/// The assertion is dropped the moment the last instance is unpublished, so
/// nothing MSL does keeps a Mac awake longer than the user asked for.
public final class PublicWakefulness: @unchecked Sendable {
    public static let shared = PublicWakefulness()

    private var assertion: IOPMAssertionID = 0
    private var holders: Set<String> = []
    private let lock = NSLock()

    private init() {}

    public func hold(for instance: String) {
        lock.lock(); defer { lock.unlock() }
        holders.insert(instance)
        guard assertion == 0 else { return }
        var identifier: IOPMAssertionID = 0
        // Named so it shows up in `pmset -g assertions` as something a
        // person can understand - "why is my Mac not sleeping" should have
        // a readable answer.
        let reason = "MSL is publishing a Linux instance for SSH" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &identifier)
        if result == kIOReturnSuccess { assertion = identifier }
    }

    public func release(for instance: String) {
        lock.lock(); defer { lock.unlock() }
        holders.remove(instance)
        // Only when nothing is published any more: two published instances
        // share one assertion, and releasing on the first would let the Mac
        // sleep while the second was still meant to be reachable.
        guard holders.isEmpty, assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return assertion != 0
    }
}
