// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import CryptoKit
import Foundation

/// Bringing an instance's `shellinit` up to date, from MSL, at runtime.
///
/// **Why this exists rather than an image rebuild.** `shellinit` is compiled
/// into the rootfs by `provision-msl.sh`, so a distro image carries whatever
/// version it was built with - and detachable sessions
/// (`READMES/27-SESSION-PERSISTENCE.md`) need a newer one than any published
/// image has. Rebuilding and republishing twelve ~350 MB images for a 20 KB
/// C file would be absurd, and every instance already has its **own disk**,
/// so the upgrade is per instance and MSL can do it itself.
///
/// It is the same trick `GuestIntegration` uses for the integration kit: the
/// source travels base64'd inside one command, is compiled in the guest, and
/// a stamp file stops it happening twice.
///
/// Everything here degrades to doing nothing:
/// - no `cc` in the guest (not every image has one) - nothing happens, and
///   the old `shellinit` keeps working exactly as before;
/// - compile fails - the old binary is left in place, never a half-written
///   one;
/// - MSL.app not found - no source to install, nothing happens.
///
/// That is not politeness, it is required: a host that cannot upgrade a
/// guest must still be able to talk to it, and the protocol is built so an
/// old `shellinit` simply never answers with a `session` frame.
public enum GuestShellUpgrade {

    /// Where the guest records which version it has, so this is a no-op
    /// after the first time.
    static let stampPath = "/usr/local/bin/.shellinit-msl-version"

    /// `Guest/init/shellinit.c`, as shipped inside MSL.app.
    public static func source(kit: URL? = CustomImage.bundledKit()) -> Data? {
        guard let kit else { return nil }
        return try? Data(contentsOf: kit.appendingPathComponent("daemons/shellinit.c"))
    }

    /// Identifies a build of the source. Short because it only has to differ.
    public static func version(of source: Data) -> String {
        String(SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The root command that installs it, or nil when there is nothing to
    /// install.
    ///
    /// Compiled to a temporary path and only moved into place **after** a
    /// successful compile, so a guest without the headers or with a broken
    /// toolchain is left with the `shellinit` it already had rather than a
    /// truncated one. The stamp is written last, for the same reason.
    public static func installCommand(source: Data? = source()) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let version = version(of: source)
        let encoded = source.base64EncodedString()
        return """
        set -e
        if [ -f '\(stampPath)' ] && [ "$(cat '\(stampPath)' 2>/dev/null)" = '\(version)' ]; then
            echo "shellinit already \(version)"
            exit 0
        fi
        command -v cc >/dev/null 2>&1 || { echo "no cc - leaving shellinit alone"; exit 0; }
        printf '%s' '\(encoded)' | base64 -d > /tmp/shellinit-msl.c || exit 0
        # -lutil for forkpty. Both spellings, because musl folds it into libc
        # and glibc does not.
        if ! cc -O2 -o /tmp/shellinit-msl /tmp/shellinit-msl.c -lutil 2>/tmp/shellinit-msl.log; then
            cc -O2 -o /tmp/shellinit-msl /tmp/shellinit-msl.c 2>>/tmp/shellinit-msl.log || {
                echo "shellinit did not build - keeping the one already here"
                exit 0
            }
        fi
        cp /tmp/shellinit-msl /usr/local/bin/shellinit
        chmod +x /usr/local/bin/shellinit
        printf '%s' '\(version)' > '\(stampPath)'
        echo "shellinit updated to \(version)"
        """
    }

    /// **Why there is no restart here.**
    ///
    /// Replacing the binary does not replace the running listener, so the
    /// upgrade takes effect at this instance's next start. Restarting it in
    /// place was tried and is not worth it: the listener owns the vsock
    /// port, so a new one cannot bind until the old one is gone, and every
    /// connection arriving in that window is reset - which is exactly what
    /// happened, leaving `msl <instance>` answering "Connection reset by
    /// peer" for seconds after an otherwise successful upgrade.
    ///
    /// One deferred boot is a much better trade than a window where the
    /// instance cannot be reached at all, and the stamp means the cost is
    /// paid once per instance ever.

    /// Whether this guest's `shellinit` is already current - used to skip
    /// the work entirely, and to report honestly.
    public static func isCurrent(stamp: String?, source: Data? = source()) -> Bool {
        guard let source, let stamp else { return false }
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines) == version(of: source)
    }
}
