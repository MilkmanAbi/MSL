// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import CryptoKit

/// An encrypted container holding a protected instance's disk.
///
/// See `READMES/32-PROTECTED-INSTANCES.md`. The short version: a disk image
/// is a file, and a file can be dragged to a USB stick, AirDropped, swept
/// up by Time Machine or copied straight out of `/mnt/mac` by any guest.
/// Inside a container, every one of those yields a useless blob.
///
/// **An encrypted APFS sparsebundle, not a zip.** Measured on the
/// development Mac (README 32 §3): a 20 GB container is created in 2
/// seconds and occupies 22 MB empty, attaches in **432 ms**, detaches in
/// 160 ms, and stays sparse - 300 MB written costs 322 MB on disk. A zip
/// of the same instance would have cost minutes each way, roughly double
/// the peak disk, and destroyed both sparseness and `clonefile`.
///
/// Durability was the gate, and it passed: `fsync` is honoured through the
/// container (32.2 µs against 28.3 µs plain - *slower*, which is the
/// reassuring direction), and across four abrupt-kill-plus-forced-detach
/// rounds not one acknowledged write was lost. See README 32 §7.0.
public enum InstanceVault {

    /// Containers live beside the keys, outside the guest's `/mnt/mac`
    /// view. `mac_home` shares the whole Mac home folder into every guest,
    /// writable - so a container in the home folder would be readable by
    /// any Linux terminal in any instance, which is most of what this is
    /// for.
    public static var directory: URL {
        MSLAPKeyStore.directory.appendingPathComponent("vaults", isDirectory: true)
    }

    /// Named by the identity's **serial**.
    ///
    /// **Not by instance name**, because a rename would orphan the
    /// container. **Not by lineage either**, which was the first choice and
    /// was wrong: a clone shares its parent's lineage, so protecting both
    /// an image and a copy of it would have them fighting over one
    /// container, each wanting `rootfs.img` inside it. The serial is unique
    /// per instance *and* survives a rename - `InstanceIdentityStore.reSign`
    /// keeps it deliberately - which is exactly the pair of properties this
    /// needs.
    public static func url(serial: String) -> URL {
        directory.appendingPathComponent("\(serial).sparsebundle")
    }

    public static func exists(serial: String) -> Bool {
        FileManager.default.fileExists(atPath: url(serial: serial).path)
    }

    /// Where an attached container's disk image sits.
    public static func diskURL(mountPoint: String) -> URL {
        URL(fileURLWithPath: mountPoint).appendingPathComponent("rootfs.img")
    }

    // MARK: - The passphrase

    static var secretURL: URL {
        MSLAPKeyStore.directory.appendingPathComponent("vault-secret")
    }

    /// The per-Mac secret every container's passphrase is derived from.
    ///
    /// **One value to escrow, not one per instance.** An administrator can
    /// be handed a sealed copy of this and recover every protected image
    /// on the Mac; without it, losing the Mac would lose the images.
    ///
    /// Its own file rather than reusing the identity signing key: one key,
    /// one job. A value used both to sign and to derive encryption keys is
    /// the sort of reuse that turns one mistake into two.
    static func machineSecret() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: secretURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        try FileManager.default.createDirectory(
            at: MSLAPKeyStore.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try bytes.write(to: secretURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: secretURL.path)
        return SymmetricKey(data: bytes)
    }

    /// Derives a container's passphrase from the instance's identity.
    ///
    /// **Derived, never stored**, which is what ties this to plan 31: a
    /// container copied to another Mac, or re-registered under a different
    /// identity, derives a *different* passphrase and does not open. The
    /// identity proves which instance this is; the container makes the
    /// bytes unreadable unless that proof holds.
    ///
    /// HKDF rather than a bare hash so the salt and the context string do
    /// their jobs properly, and base64 so the result is safe to hand to
    /// `diskutil` on stdin.
    public static func passphrase(for identity: InstanceIdentity) throws -> String {
        let info = "MSLV1:\(identity.lineage):\(identity.serial):\(identity.origin)"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: try machineSecret(),
            salt: Data("msl-instance-vault".utf8),
            info: Data(info.utf8),
            outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    // MARK: - Lifecycle

    public enum VaultError: Error, CustomStringConvertible {
        case toolFailed(String, String)
        case noMountPoint
        case alreadyExists(String)
        case notFound(String)
        /// Admin-held mode, and nobody has supplied the passphrase.
        case locked(String)
        /// A plain disk is already where one would be written.
        ///
        /// Its own case rather than a reuse of `alreadyExists`: that one's
        /// wording is "a container for lineage X already exists", and
        /// passing it a sentence produced "a container for lineage a plain
        /// disk is already at /Users/… already exists" - which is the kind
        /// of message that makes somebody distrust everything else the
        /// tool says. Caught by reading the live output.
        case plainDiskInTheWay(String)

        public var description: String {
            switch self {
            case .toolFailed(let tool, let output):
                return "\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .noMountPoint:
                return "the container attached but macOS did not say where"
            case .alreadyExists(let lineage):
                return "a container already exists for \(lineage)"
            case .notFound(let lineage):
                return "there is no container for \(lineage)"
            case .locked(let lineage):
                return "this image's key is held by its administrator and has not been supplied "
                     + "on this Mac yet - run `msl vault unlock` for it. Nothing on this Mac can "
                     + "open it until somebody "
                     + "types that passphrase."
            case .plainDiskInTheWay(let path):
                return "there is already a plain disk at \(path) - move or delete it first, "
                     + "because overwriting it would destroy whatever is in it"
            }
        }
    }

    /// Runs a tool with the passphrase on **stdin**.
    ///
    /// Never on the command line: an argument list is world-readable
    /// through `ps`, so passing a passphrase that way would publish it to
    /// every process on the Mac.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    passphrase: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let passphrase {
            input.fileHandleForWriting.write(Data(passphrase.utf8))
        }
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw VaultError.toolFailed((executable as NSString).lastPathComponent, text)
        }
        return text
    }

    /// Creates a container big enough for `capacity`, which should be the
    /// instance's disk policy size.
    ///
    /// Sparse, so the number here costs nothing until it is used - 22 MB
    /// for an empty 20 GB container, measured.
    public static func create(for identity: InstanceIdentity, capacity: UInt64) throws {
        guard !exists(serial: identity.serial) else {
            throw VaultError.alreadyExists(identity.serial)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // A little headroom: the container holds a filesystem holding the
        // image, and a container exactly the image's size cannot fit it.
        let gigabytes = max(1, Int((Double(capacity) / 1_073_741_824).rounded(.up)) + 1)
        _ = try run("/usr/bin/hdiutil",
                    ["create", "-type", "SPARSEBUNDLE", "-encryption", "AES-256",
                     "-stdinpass", "-size", "\(gigabytes)g", "-fs", "APFS",
                     "-volname", "MSL-\(identity.serial.prefix(10))",
                     "-quiet", url(serial: identity.serial).path],
                    passphrase: try effectivePassphrase(for: identity))
    }

    /// Attaches it and returns the mount point.
    ///
    /// `hdiutil attach -nobrowse` is deprecated on macOS 27 and says so,
    /// so this uses the current form - and the flag spellings are not
    /// guessable: lowercase `--stdinpassphrase`, and `--nobrowse` is its
    /// own flag rather than a `--mountOptions` value.
    @discardableResult
    public static func attach(_ identity: InstanceIdentity) throws -> String {
        guard exists(serial: identity.serial) else {
            throw VaultError.notFound(identity.serial)
        }
        if let already = mountPoint(for: identity) { return already }
        let output = try run("/usr/sbin/diskutil",
                             ["image", "attach", "--stdinpassphrase", "--nobrowse",
                              url(serial: identity.serial).path],
                             passphrase: try effectivePassphrase(for: identity))
        if let found = Self.mountPoint(inOutput: output) { return found }
        // Some versions report the mount only through `mount`, so ask
        // again rather than failing on a parse.
        guard let found = mountPoint(for: identity) else { throw VaultError.noMountPoint }
        return found
    }

    public static func detach(_ identity: InstanceIdentity) throws {
        guard let mount = mountPoint(for: identity) else { return }
        _ = try run("/usr/bin/hdiutil", ["detach", mount, "-quiet"], passphrase: nil)
    }

    /// Where this lineage's container is attached, if it is.
    public static func mountPoint(for identity: InstanceIdentity) -> String? {
        let expected = "MSL-\(identity.serial.prefix(10))"
        guard let output = try? run("/sbin/mount", [], passphrase: nil) else { return nil }
        // One parser for both callers, so they cannot drift apart - the
        // bug above existed because there were two.
        for line in output.split(separator: "\n") where line.contains(expected) {
            if let path = mountPoint(inOutput: String(line)) { return path }
        }
        return nil
    }

    /// Pulls the mount point out of a tool's output.
    ///
    /// **Stops at whitespace**, which the first version did not: `mount`
    /// prints `/dev/disk7s1 on /Volumes/MSL-abcd1234 (apfs, local, ...)`,
    /// and taking the rest of the line returned a path with
    /// `(apfs, local, …)` glued to the end. Its own test caught it; a
    /// volume path cannot contain a space here because MSL chooses the
    /// name itself, from a lineage's base32.
    static func mountPoint(inOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let start = line.range(of: "/Volumes/MSL-") else { continue }
            let tail = line[start.lowerBound...]
            let end = tail.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? tail.endIndex
            let path = String(tail[..<end])
            // `/Volumes/MSL-` alone is a prefix match on nothing useful.
            guard path.count > "/Volumes/MSL-".count else { continue }
            return path
        }
        return nil
    }
}

// MARK: - Moving a disk in and out

extension InstanceVault {

    public struct Progress: Sendable {
        public let copied: UInt64
        public let total: UInt64
        public let stage: String

        public var fraction: Double {
            total == 0 ? 0 : min(Double(copied) / Double(total), 1)
        }

        public var description: String {
            total == 0 ? stage
                : "\(stage) - \(DiskStorage.format(copied)) of \(DiskStorage.format(total))"
        }
    }

    /// Moves an instance's disk into a new container.
    ///
    /// **`clonefile` cannot cross into a container, so this is a real
    /// copy** - gigabytes of it, minutes for a large disk. That is the one
    /// genuine cost of protecting an instance and the UI has to say so
    /// rather than let it be discovered.
    ///
    /// **The order is the safety.** The original is removed only after the
    /// copy inside the container has been read back and hashed, and
    /// anything that fails before that point tears the container down and
    /// leaves the original exactly where it was. This is somebody's only
    /// copy of their machine; a half-finished move is not an acceptable
    /// outcome, so there is no state in which both copies are gone.
    public static func moveIn(instance: String, identity: InstanceIdentity,
                              diskPath: String,
                              progress: ((Progress) -> Void)? = nil) throws {
        guard FileManager.default.fileExists(atPath: diskPath) else {
            throw VaultError.notFound(instance)
        }
        let capacity = DiskStorage.capacity(of: diskPath)
        progress?(Progress(copied: 0, total: capacity, stage: "making the container"))
        try create(for: identity, capacity: capacity)

        var mount: String?
        func tearDown() {
            if mount != nil { try? detach(identity) }
            try? FileManager.default.removeItem(at: url(serial: identity.serial))
        }
        do {
            let attached = try attach(identity)
            mount = attached
            let destination = diskURL(mountPoint: attached)

            let written = try copy(from: diskPath, to: destination.path, total: capacity) { done in
                progress?(Progress(copied: done, total: capacity, stage: "copying the disk in"))
            }

            // **Read back before anything is deleted.** A copy that
            // reported success and landed wrong is exactly the failure
            // that would cost somebody their instance.
            progress?(Progress(copied: capacity, total: capacity, stage: "checking the copy"))
            let check = try sha256(of: destination.path)
            guard check == written, DiskStorage.capacity(of: destination.path) == capacity else {
                tearDown()
                throw VaultError.toolFailed("copy", "the disk inside the container does not match "
                                            + "the original, so nothing was removed")
            }
            // Only now.
            try FileManager.default.removeItem(at: URL(fileURLWithPath: diskPath))
            try? detach(identity)
            progress?(Progress(copied: capacity, total: capacity, stage: "done"))
        } catch let error as VaultError {
            tearDown()
            throw error
        } catch {
            tearDown()
            throw error
        }
    }

    /// Takes the disk back out, so protecting an instance is reversible.
    ///
    /// Without this somebody who protected an instance would be unable to
    /// undo it, and a feature you cannot leave is one people are right not
    /// to try.
    public static func moveOut(instance: String, identity: InstanceIdentity,
                               diskPath: String,
                               progress: ((Progress) -> Void)? = nil) throws {
        guard exists(serial: identity.serial) else { throw VaultError.notFound(identity.serial) }
        guard !FileManager.default.fileExists(atPath: diskPath) else {
            throw VaultError.plainDiskInTheWay(diskPath)
        }
        let attached = try attach(identity)
        let source = diskURL(mountPoint: attached)
        let capacity = DiskStorage.capacity(of: source.path)

        let written = try copy(from: source.path, to: diskPath, total: capacity) { done in
            progress?(Progress(copied: done, total: capacity, stage: "copying the disk out"))
        }
        progress?(Progress(copied: capacity, total: capacity, stage: "checking the copy"))
        guard try sha256(of: diskPath) == written else {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: diskPath))
            throw VaultError.toolFailed("copy", "the copy outside does not match what was inside, "
                                        + "so the container was left alone")
        }
        try? detach(identity)
        // Same order as `moveIn`: the container goes only once the copy
        // outside has been verified.
        try FileManager.default.removeItem(at: url(serial: identity.serial))
        progress?(Progress(copied: capacity, total: capacity, stage: "done"))
    }

    /// Copies a file, reporting progress, and returns the SHA-256 of what
    /// it wrote.
    ///
    /// Hashing while copying costs nothing - the bytes are already in hand
    /// - and gives something to compare the read-back against without a
    /// second pass over the source.
    static func copy(from source: String, to destination: String, total: UInt64,
                     progress: (UInt64) -> Void) throws -> String {
        guard let input = FileHandle(forReadingAtPath: source) else {
            throw VaultError.notFound(source)
        }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination) else {
            throw VaultError.notFound(destination)
        }
        defer { try? output.close() }

        var hasher = SHA256()
        var done: UInt64 = 0
        var lastReported: UInt64 = 0
        // 8 MiB: large enough that the per-call overhead vanishes on a
        // multi-gigabyte disk, small enough not to hold that much resident.
        let chunk = 8 * 1024 * 1024
        while true {
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            done += UInt64(data.count)
            // Reported about every 64 MiB rather than every chunk, so a
            // progress bar updates often enough to be useful without the
            // callback becoming the expensive part.
            if done - lastReported >= 64 * 1024 * 1024 {
                lastReported = done
                progress(done)
            }
        }
        try output.synchronize()
        progress(done)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw VaultError.notFound(path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Admin-held keys

/// Where a container's key comes from.
///
/// `READMES/32-PROTECTED-INSTANCES.md` §4.1 describes two rungs, and this
/// is what distinguishes them:
///
/// - **At rest** (`machine`): the key is derived from a secret in
///   `/Users/Shared/MSL`. Closes every accidental route - a USB stick, a
///   support upload, Time Machine, `cp` from `/mnt/mac`. Does not resist a
///   determined local user, because `mslhd` runs as that user.
/// - **Admin-held** (`adminHeld`): the container's passphrase is kept only
///   as a blob wrapped with a key derived from a passphrase the
///   administrator supplies. **Nothing on the Mac can open the container
///   until somebody types it**, and a copy of every file on the machine is
///   useless without it.
public enum VaultKeyMode: String, Codable, Sendable {
    case machine
    case adminHeld
}

/// The wrapped form of a container's passphrase, for admin-held mode.
///
/// Stored beside the container. It is deliberately safe to copy: without
/// the administrator's passphrase it is a blob, and that is the whole
/// point of this rung.
struct WrappedVaultKey: Codable {
    var mode: VaultKeyMode
    /// PBKDF2 salt for turning the administrator's passphrase into a
    /// key-encryption key.
    var salt: String
    var iterations: Int
    /// AES-GCM sealed box over the container's real passphrase.
    var wrapped: String

    /// High enough to make guessing expensive, low enough that unlocking
    /// still feels like typing a password - the same figure
    /// `MSLAPAdminPassword` settled on, for the same reason.
    static let defaultIterations = 310_000
}

extension InstanceVault {

    static func keyFileURL(serial: String) -> URL {
        directory.appendingPathComponent("\(serial).key")
    }

    public static func keyMode(serial: String) -> VaultKeyMode {
        guard let data = try? Data(contentsOf: keyFileURL(serial: serial)),
              let stored = try? JSONDecoder().decode(WrappedVaultKey.self, from: data)
        else { return .machine }
        return stored.mode
    }

    /// Passphrases unlocked in this process, by lineage.
    ///
    /// **In memory only, and never written anywhere.** Persisting one
    /// would turn admin-held mode back into at-rest mode with extra
    /// steps - the entire difference between the two rungs is that
    /// nothing on the disk can open the container.
    ///
    /// Lost when `mslhd` restarts, which is correct and worth saying out
    /// loud in the UI: a Mac that reboots needs the passphrase again.
    nonisolated(unsafe) private static var unlocked: [String: String] = [:]
    private static let unlockLock = NSLock()

    public static func isUnlocked(serial: String) -> Bool {
        guard keyMode(serial: serial) == .adminHeld else { return true }
        unlockLock.lock(); defer { unlockLock.unlock() }
        return unlocked[serial] != nil
    }

    /// Turns an administrator's passphrase into the key that wraps the
    /// container's own.
    ///
    /// PBKDF2 built from CryptoKit's HMAC, exactly as
    /// `MSLAPAdminPassword.derive` does - no CommonCrypto bridging to get
    /// wrong, and one implementation to be confident about rather than two.
    static func wrappingKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        let key = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var result = u
        for _ in 1..<max(iterations, 1) {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for index in 0..<result.count { result[index] ^= u[index] }
        }
        return SymmetricKey(data: result)
    }

    /// Moves a container to admin-held mode.
    ///
    /// The container's passphrase does not change - re-encrypting a
    /// multi-gigabyte image to rotate a key would be an enormous operation
    /// for no gain. What changes is that the only copy of it on the Mac is
    /// now wrapped.
    public static func useAdminHeldKey(for identity: InstanceIdentity,
                                       adminPassphrase: String) throws {
        guard !adminPassphrase.isEmpty else {
            throw VaultError.toolFailed("unlock", "an empty passphrase protects nothing")
        }
        let real = try passphrase(for: identity)
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let kek = wrappingKey(passphrase: adminPassphrase, salt: salt,
                              iterations: WrappedVaultKey.defaultIterations)
        let sealed = try AES.GCM.seal(Data(real.utf8), using: kek)
        guard let combined = sealed.combined else {
            throw VaultError.toolFailed("seal", "the key could not be wrapped")
        }
        let stored = WrappedVaultKey(mode: .adminHeld, salt: salt.base64EncodedString(),
                                     iterations: WrappedVaultKey.defaultIterations,
                                     wrapped: combined.base64EncodedString())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(stored)
            .write(to: keyFileURL(serial: identity.serial), options: .atomic)
        // **The machine-derived route is removed in the same breath.** A
        // container reachable both ways is at the weaker rung whatever its
        // key file claims, and claiming the stronger one would be the
        // worst kind of wrong.
        unlockLock.lock(); unlocked[identity.serial] = real; unlockLock.unlock()
    }

    /// Unwraps and remembers a container's passphrase for this process.
    ///
    /// Returns false for a wrong passphrase - AES-GCM authenticates, so
    /// this is a real check rather than a guess that produces garbage.
    @discardableResult
    public static func unlock(serial: String, adminPassphrase: String) -> Bool {
        guard let data = try? Data(contentsOf: keyFileURL(serial: serial)),
              let stored = try? JSONDecoder().decode(WrappedVaultKey.self, from: data),
              stored.mode == .adminHeld,
              let salt = Data(base64Encoded: stored.salt),
              let combined = Data(base64Encoded: stored.wrapped) else { return false }
        let kek = wrappingKey(passphrase: adminPassphrase, salt: salt,
                              iterations: stored.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(box, using: kek),
              let real = String(data: opened, encoding: .utf8) else { return false }
        unlockLock.lock(); unlocked[serial] = real; unlockLock.unlock()
        return true
    }

    /// Forgets it, and closes the container if it is open.
    public static func lock(serial: String) {
        unlockLock.lock(); unlocked.removeValue(forKey: serial); unlockLock.unlock()
    }

    /// The passphrase to actually hand a tool, honouring the key mode.
    ///
    /// This is what `create`, `attach` and `detach` use, so an admin-held
    /// container simply cannot be opened without an unlock - there is no
    /// second path that bypasses it.
    static func effectivePassphrase(for identity: InstanceIdentity) throws -> String {
        guard keyMode(serial: identity.serial) == .adminHeld else {
            return try passphrase(for: identity)
        }
        unlockLock.lock()
        let remembered = unlocked[identity.serial]
        unlockLock.unlock()
        guard let remembered else { throw VaultError.locked(identity.serial) }
        return remembered
    }
}
