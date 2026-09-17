import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Finding e2fsck

/// Locates `e2fsck` on the Mac.
///
/// **macOS does not ship it.** On the machine this was written on it came
/// from Homebrew's `e2fsprogs`, which is keg-only - it lives under the
/// formula's own prefix and is deliberately not linked onto `PATH`, so a
/// plain `which e2fsck` misses it. The probe list below covers the places it
/// actually ends up.
///
/// When none of them exist, host-side check and repair are simply
/// unavailable and the UI says what to install. It is not bundled into
/// MSL.app: the binary links six Homebrew dylibs (libext2fs, libcom_err,
/// libblkid, libuuid, libe2p, libintl), so shipping it is a relocation and
/// re-signing job of its own. The maintenance boot is the fallback - it
/// repairs using the *guest's* e2fsck instead.
public enum E2fsck {
    /// Most specific first.
    public static let candidatePaths = [
        "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck",  // Homebrew, Apple silicon - keg-only
        "/usr/local/opt/e2fsprogs/sbin/e2fsck",     // Homebrew, Intel - keg-only
        "/opt/homebrew/sbin/e2fsck",
        "/usr/local/sbin/e2fsck",
        "/opt/local/sbin/e2fsck",                   // MacPorts
    ]

    /// Pure: the filesystem is a parameter, so this is testable against
    /// machines other than this one.
    public static func locate(pathEnvironment: String?,
                              isExecutable: (String) -> Bool) -> String? {
        if let hit = candidatePaths.first(where: isExecutable) { return hit }
        let pathDirectories = (pathEnvironment ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent("e2fsck")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    public static func locate() -> String? {
        locate(pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
               isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    public static let installHint =
        "Checking a disk from the Mac side needs e2fsprogs, which macOS doesn't include. Install it with `brew install e2fsprogs`, or use Maintenance Boot, which checks the disk using the tools inside Linux instead."
}

// MARK: - Verdicts

public enum FsckMode: String, Codable, Sendable {
    /// `-f -n`: read everything, change nothing.
    case check
    /// `-f -y`: fix everything it can, answering yes to every question.
    case repair
}

/// What an e2fsck exit code means, for a person.
///
/// e2fsck's exit status is a **bitmask**, not an enum: 1 corrected, 2
/// corrected and needs a reboot, 4 errors left, 8 operational error,
/// 16 usage error, 32 cancelled, 128 shared-library error. A run can set
/// several at once.
///
/// The bits that matter most are 8/16/32/128, because they mean the check
/// **did not happen**. Rendering those as "clean" is the worst possible bug
/// in a repair tool - it would tell someone a corrupt disk is fine - so they
/// are checked first and take priority over everything else.
public struct FsckVerdict: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case clean
        case repaired
        /// Corrected, but e2fsck wants the system restarted before the
        /// filesystem is used. For a stopped VM that simply means: fine to
        /// boot now.
        case repairedNeedsRestart
        /// In check mode: problems found, nothing changed. In repair mode:
        /// problems it could not fix on its own.
        case problemsRemain
        /// The check did not complete. Says nothing about the disk.
        case didNotRun(reason: String)
    }

    public let outcome: Outcome
    public let exitCode: Int32
    public let mode: FsckMode

    public static func from(exitCode: Int32, mode: FsckMode) -> FsckVerdict {
        let outcome: Outcome
        if exitCode < 0 {
            outcome = .didNotRun(reason: "e2fsck could not be started")
        } else if exitCode & 128 != 0 {
            outcome = .didNotRun(reason: "e2fsck failed to load a library it needs")
        } else if exitCode & 32 != 0 {
            outcome = .didNotRun(reason: "the check was cancelled")
        } else if exitCode & 16 != 0 {
            outcome = .didNotRun(reason: "e2fsck rejected its arguments")
        } else if exitCode & 8 != 0 {
            outcome = .didNotRun(reason: "e2fsck hit an operational error - often the disk image being in use or unreadable")
        } else if exitCode & 4 != 0 {
            outcome = .problemsRemain
        } else if exitCode & 2 != 0 {
            outcome = .repairedNeedsRestart
        } else if exitCode & 1 != 0 {
            outcome = .repaired
        } else {
            outcome = .clean
        }
        return FsckVerdict(outcome: outcome, exitCode: exitCode, mode: mode)
    }

    /// Whether the disk is known to be healthy *now*.
    public var isHealthy: Bool {
        switch outcome {
        case .clean, .repaired, .repairedNeedsRestart: return true
        case .problemsRemain, .didNotRun: return false
        }
    }

    /// Whether an instance may boot on the strength of this result.
    /// "Didn't run" is not a pass - an unchecked disk under check-at-start
    /// is refused, not waved through.
    public var allowsBoot: Bool { isHealthy }

    public var title: String {
        switch outcome {
        case .clean: return "No problems found"
        case .repaired: return "Problems found and fixed"
        case .repairedNeedsRestart: return "Problems fixed"
        case .problemsRemain:
            return mode == .check ? "Problems found" : "Some problems couldn't be fixed"
        case .didNotRun: return "The check didn't run"
        }
    }

    public var detail: String {
        switch outcome {
        case .clean:
            return "The filesystem is consistent."
        case .repaired:
            return "e2fsck corrected the filesystem. A copy of the disk from before the repair is kept until you discard it."
        case .repairedNeedsRestart:
            return "e2fsck corrected the filesystem and asks for a restart before it's used. The instance is stopped, so starting it now is that restart."
        case .problemsRemain where mode == .check:
            return "Nothing was changed. Run Repair to fix them — a backup of the disk is taken first."
        case .problemsRemain:
            return "e2fsck fixed what it safely could. What remains needs a closer look; the pre-repair backup is kept."
        case .didNotRun(let reason):
            return "This says nothing about the disk: \(reason)."
        }
    }
}

// MARK: - Backup

/// An instant, free copy of a disk image, taken before every repair.
///
/// `clonefile(2)`, not `cp -c`. The distinction is the whole point: on
/// APFS a clone shares every block with its source, so a 58 GB image clones
/// in milliseconds for zero bytes - but `cp -c` quietly falls back to a
/// *real* copy when it cannot clone, which would fill the disk. `clonefile`
/// fails instead (`EXDEV` across volumes, `ENOTSUP` off APFS), and a repair
/// that cannot get a free backup does not proceed.
public enum ImageBackup {
    public static func path(for imagePath: String) -> String {
        imagePath + ".pre-repair"
    }

    public static func exists(for imagePath: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: imagePath))
    }

    public enum BackupError: Error, CustomStringConvertible {
        case cannotClone(errno: Int32)

        public var description: String {
            switch self {
            case .cannotClone(let code) where code == EXDEV:
                return "the disk image can't be cloned across volumes, and a full copy could be enormous - not repairing without a backup"
            case .cannotClone(let code) where code == ENOTSUP:
                return "this volume doesn't support instant clones (it isn't APFS) - not repairing without a backup"
            case .cannotClone(let code):
                return "couldn't clone the disk image (\(String(cString: strerror(code)))) - not repairing without a backup"
            }
        }
    }

    /// Clones `imagePath` beside itself.
    ///
    /// An existing backup is **kept**, not replaced: it is the image from
    /// before the *first* repair, which is the truly original one. A second
    /// repair's starting point is the first repair's output, and that is not
    /// the copy anyone would want back.
    @discardableResult
    public static func make(for imagePath: String) throws -> String {
        let destination = path(for: imagePath)
        if FileManager.default.fileExists(atPath: destination) { return destination }
        guard clonefile(imagePath, destination, 0) == 0 else {
            throw BackupError.cannotClone(errno: errno)
        }
        return destination
    }

    public static func discard(for imagePath: String) {
        try? FileManager.default.removeItem(atPath: path(for: imagePath))
    }

    /// Puts the backup back in place of the image.
    ///
    /// `rename(2)`, so it is atomic - there is never a moment with no disk
    /// image at all - and the backup is consumed by it.
    public static func restore(for imagePath: String) throws {
        let backup = path(for: imagePath)
        guard rename(backup, imagePath) == 0 else {
            throw BackupError.cannotClone(errno: errno)
        }
    }
}

// MARK: - Running it

public struct FsckRun: Sendable {
    public let verdict: FsckVerdict
    /// e2fsck's own report, trimmed. Shown behind a disclosure, since the
    /// verdict is what most people need and the detail is for the rest.
    public let output: String
    /// Set when a repair took a backup first.
    public let backupPath: String?
}

public enum FilesystemCheck {
    public static func arguments(for mode: FsckMode) -> [String] {
        switch mode {
        // -f: check even if the filesystem claims to be clean - a disk that
        // was cut off mid-write can be marked clean and still be wrong.
        case .check: return ["-f", "-n"]
        case .repair: return ["-f", "-y"]
        }
    }

    /// Runs e2fsck against a **stopped** instance's image.
    ///
    /// Callers own that precondition - see `VMManager.runFilesystemMaintenance`,
    /// which checks the VM is stopped and holds starts off for the duration.
    /// Checking an image a running guest has mounted produces nonsense;
    /// repairing one destroys it.
    ///
    /// Synchronous on purpose, and meant to be called off any VM queue: a
    /// real disk can take minutes.
    public static func run(e2fsck: String, imagePath: String, mode: FsckMode) -> FsckRun {
        var backupPath: String?
        if mode == .repair {
            do {
                backupPath = try ImageBackup.make(for: imagePath)
            } catch {
                return FsckRun(
                    verdict: FsckVerdict(outcome: .didNotRun(reason: "\(error)"), exitCode: -1, mode: mode),
                    output: "", backupPath: nil)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: e2fsck)
        process.arguments = arguments(for: mode) + [imagePath]
        // -n/-y mean it never asks, but a tty on stdin can still change how
        // e2fsck behaves; nothing should ever wait on a keyboard here.
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return FsckRun(verdict: .from(exitCode: -1, mode: mode), output: "\(error)", backupPath: backupPath)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return FsckRun(
            verdict: .from(exitCode: process.terminationStatus, mode: mode),
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            backupPath: backupPath)
    }
}
