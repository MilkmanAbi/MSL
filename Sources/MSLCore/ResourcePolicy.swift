import Foundation
import Virtualization

/// How much memory an instance gets, and who decides.
///
/// The two modes are genuinely different shapes, not one number with a flag:
/// manual is a single fixed size, dynamic is a range the balloon moves within.
public enum MemoryMode: Codable, Equatable, Sendable {
    /// A fixed size, in megabytes. What the user typed, honoured exactly.
    case manual(megabytes: UInt64)

    /// A range. The VM boots with `ceilingMegabytes` of memory and the
    /// balloon takes some of it back, never going below `floorMegabytes`.
    ///
    /// Boots at the *ceiling* because of a hard constraint in the framework:
    /// `VZVirtioTraditionalMemoryBalloonDevice.targetVirtualMachineMemorySize`
    /// accepts values from `minimumAllowedMemorySize` up to
    /// `VZVirtualMachineConfiguration.memorySize` and no further. The balloon
    /// can only ever *take memory away* from what the VM was configured
    /// with - there is no mechanism to hand a running guest more than its
    /// configured size. So the configured size is the ceiling, and "growing"
    /// the guest means deflating the balloon back towards it.
    case dynamic(floorMegabytes: UInt64, ceilingMegabytes: UInt64)

    /// What `VZVirtualMachineConfiguration.memorySize` must be set to, in
    /// bytes - the fixed size, or the ceiling.
    public var configuredBytes: UInt64 {
        switch self {
        case .manual(let megabytes): return megabytes * 1024 * 1024
        case .dynamic(_, let ceiling): return ceiling * 1024 * 1024
        }
    }

    public var isDynamic: Bool {
        if case .dynamic = self { return true }
        return false
    }
}

/// Per-instance CPU and memory allocation.
///
/// Both fields are optional and `nil` means "whatever the existing code
/// decides" - `VMConfiguration.defaultCPUCount()` and
/// `defaultMemorySize()`. An instance that has never been touched behaves
/// exactly as it did before this file existed.
public struct ResourcePolicy: Codable, Equatable, Sendable {
    public var cpuCount: Int?
    public var memory: MemoryMode?

    public init(cpuCount: Int? = nil, memory: MemoryMode? = nil) {
        self.cpuCount = cpuCount
        self.memory = memory
    }

    public static let inherited = ResourcePolicy()

    /// The memory mode to actually use, filling in the existing default for
    /// an instance that has never been configured.
    public func resolvedMemory() -> MemoryMode {
        memory ?? .manual(megabytes: VMConfiguration.defaultMemorySize() / (1024 * 1024))
    }

    public func resolvedCPUCount() -> Int {
        cpuCount ?? VMConfiguration.defaultCPUCount()
    }
}

// MARK: - Advice

/// What to tell someone about a memory figure before they commit to it.
///
/// Pure, and separate from the UI, so the same judgement can be tested
/// against hosts other than this one - the interesting cases are an 8 GB
/// Mac and a 192 GB Mac, and this machine is neither.
public struct MemoryAdvice: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// Nothing worth saying.
        case fine
        /// Allowed, and the user may well mean it, but they should know.
        case caution
        /// The framework or the machine will not accept this.
        case blocking
    }

    public let severity: Severity
    public let message: String?

    public var allowsStart: Bool { severity != .blocking }

    static let fine = MemoryAdvice(severity: .fine, message: nil)
}

public enum MemoryAdvisor {
    /// The share of host RAM above which we warn.
    ///
    /// Three fifths, as asked for. The reasoning behind the number: macOS
    /// itself, the window server, and whatever the user is actually doing
    /// all live in the remainder, and a VM's memory is *wired* from the
    /// host's point of view - it cannot be compressed or paged out the way
    /// an ordinary application's can. Handing most of the machine to a guest
    /// does not slow the guest down, it slows the Mac down.
    public static let cautionNumerator: UInt64 = 3
    public static let cautionDenominator: UInt64 = 5

    public static func cautionThresholdMegabytes(hostMemory: UInt64) -> UInt64 {
        (hostMemory / cautionDenominator * cautionNumerator) / (1024 * 1024)
    }

    /// `hostMemory`, `frameworkMinimum` and `frameworkMaximum` are passed in
    /// rather than read from the process so this stays testable.
    ///
    /// The host check is made separately from `frameworkMaximum` rather than
    /// assumed to be covered by it. Measured on a real 16 GB Mac, the two
    /// happen to coincide - `maximumAllowedMemorySize` came back as exactly
    /// 16384 MB, the machine's physical memory, and the minimum as 4 MB -
    /// but that is an observation about one machine and one OS version, not
    /// a documented guarantee. Checking both costs nothing and means an
    /// over-allocation is refused here, with a sentence about this Mac,
    /// rather than at `vm.start` with a framework error.
    public static func advise(
        megabytes: UInt64, hostMemory: UInt64,
        frameworkMinimum: UInt64 = VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        frameworkMaximum: UInt64 = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    ) -> MemoryAdvice {
        let bytes = megabytes * 1024 * 1024
        let hostMB = hostMemory / (1024 * 1024)

        if bytes < frameworkMinimum {
            return MemoryAdvice(
                severity: .blocking,
                message: "Too small. Virtualization won't start a VM with less than \(frameworkMinimum / (1024 * 1024)) MB.")
        }
        if bytes > frameworkMaximum {
            return MemoryAdvice(
                severity: .blocking,
                message: "Too large. Virtualization caps a single VM at \(frameworkMaximum / (1024 * 1024)) MB.")
        }
        if bytes >= hostMemory {
            return MemoryAdvice(
                severity: .blocking,
                message: "This Mac only has \(hostMB) MB in total. The VM has to fit inside it, with room left for macOS.")
        }

        let threshold = cautionThresholdMegabytes(hostMemory: hostMemory)
        if megabytes > threshold {
            return MemoryAdvice(
                severity: .caution,
                message: "That's more than three fifths of this Mac's \(hostMB) MB. A VM's memory is wired down and can't be compressed or paged out, so macOS is left with \(hostMB - megabytes) MB for itself and everything else you're running — expect heavy paging, beachballs, and possibly an unstable machine. It will still start.")
        }
        return .fine
    }

    /// The same judgement for a dynamic range, which is warned about on its
    /// ceiling: that is what the VM actually boots with and therefore what
    /// the host has to find.
    public static func advise(
        mode: MemoryMode, hostMemory: UInt64,
        frameworkMinimum: UInt64 = VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        frameworkMaximum: UInt64 = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    ) -> MemoryAdvice {
        switch mode {
        case .manual(let megabytes):
            return advise(megabytes: megabytes, hostMemory: hostMemory,
                          frameworkMinimum: frameworkMinimum, frameworkMaximum: frameworkMaximum)
        case .dynamic(let floor, let ceiling):
            if floor > ceiling {
                return MemoryAdvice(severity: .blocking,
                                    message: "The minimum can't be larger than the maximum.")
            }
            let onCeiling = advise(megabytes: ceiling, hostMemory: hostMemory,
                                   frameworkMinimum: frameworkMinimum, frameworkMaximum: frameworkMaximum)
            if onCeiling.severity != .fine { return onCeiling }
            return advise(megabytes: floor, hostMemory: hostMemory,
                          frameworkMinimum: frameworkMinimum, frameworkMaximum: frameworkMaximum)
        }
    }

    /// A sensible starting range for dynamic mode on this host.
    ///
    /// The ceiling is deliberately not the caution threshold. Hibernating an
    /// instance writes its memory to disk, and a guest configured with a
    /// large ceiling is a large write every time - so the default stays
    /// modest and the user can raise it knowingly.
    public static func defaultDynamicRange(hostMemory: UInt64) -> MemoryMode {
        let floorMB: UInt64 = 1024
        let ceilingMB = min(max(hostMemory / 3 / (1024 * 1024), floorMB), 8 * 1024)
        return .dynamic(floorMegabytes: floorMB, ceilingMegabytes: ceilingMB)
    }
}

// MARK: - Storage

/// Per-instance, on disk, in the same shape as `SandboxPolicyStore`.
public enum ResourcePolicyStore {
    public static func file(for instance: String) -> URL {
        MSLPaths.appSupport
            .appendingPathComponent("resources", isDirectory: true)
            .appendingPathComponent("\(instance).json")
    }

    public static func load(instance: String) -> ResourcePolicy {
        guard let data = try? Data(contentsOf: file(for: instance)),
              let policy = try? JSONDecoder().decode(ResourcePolicy.self, from: data)
        else { return .inherited }
        return policy
    }

    @discardableResult
    public static func save(_ policy: ResourcePolicy, instance: String) -> Bool {
        let url = file(for: instance)
        guard MSLPaths.ensureDirectory(url.deletingLastPathComponent()) else { return false }
        guard let data = try? JSONEncoder().encode(policy) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: file(for: instance))
    }
}
