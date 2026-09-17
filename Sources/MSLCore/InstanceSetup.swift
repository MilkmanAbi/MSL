import Foundation
import Virtualization

/// CPUs, memory and disk for one instance, set from the command line.
///
/// The app has had cards for all three since they existed; the CLI had
/// `msl storage` and nothing else, so a terminal-only user could not give an
/// instance more than the default memory without hand-editing JSON. This is
/// the one parser and the one writer both `msl new` and `msl resources` use,
/// and it writes exactly what the Resources and Storage cards write -
/// `ResourcePolicyStore` and `DiskStorage` - so the two stay one setting.
///
///     --cpus 4
///     --memory 6G            fixed
///     --memory 2G-8G         dynamic: starts at 8G, the balloon gives back down to 2G
///     --disk 128G            dynamic: grows up to 128G, costs only what is written
///     --disk-fixed 128G      reserved on the Mac up front
public struct InstanceSetupOptions: Equatable {
    public var cpus: Int?
    public var memory: MemoryMode?
    public var disk: StoragePolicy?

    public init(cpus: Int? = nil, memory: MemoryMode? = nil, disk: StoragePolicy? = nil) {
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
    }

    public var isEmpty: Bool { cpus == nil && memory == nil && disk == nil }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case invalidValue(option: String, value: String, hint: String)

        public var description: String {
            switch self {
            case .missingValue(let option):
                return "\(option) needs a value"
            case .invalidValue(let option, let value, let hint):
                return "\(option) \(value): \(hint)"
            }
        }
    }

    public static let usage = "[--cpus <n>] [--memory <size>|<min>-<max>] [--disk <size>] [--disk-fixed <size>]"

    /// Pulls the setup options out of `arguments` and returns them with
    /// every argument that wasn't one of them, in order - so a command can
    /// parse its own positional arguments from what is left.
    public static func parse(_ arguments: [String]) throws -> (options: InstanceSetupOptions, remaining: [String]) {
        var options = InstanceSetupOptions()
        var remaining: [String] = []
        var index = 0

        func value(for option: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw ParseError.missingValue(option)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            // `--cpus=4` as well as `--cpus 4`.
            let (option, inline): (String, String?) = {
                guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
                return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
            }()
            func take() throws -> String { try inline ?? value(for: option) }

            switch option {
            case "--cpus", "--cpu":
                let text = try take()
                guard let count = Int(text), count > 0 else {
                    throw ParseError.invalidValue(option: option, value: text, hint: "a whole number of CPUs, like 4")
                }
                options.cpus = count
            case "--memory", "--mem", "--ram":
                let text = try take()
                guard let mode = parseMemory(text) else {
                    throw ParseError.invalidValue(option: option, value: text,
                                                  hint: "a size like 6G, or a range like 2G-8G for dynamic memory")
                }
                options.memory = mode
            case "--disk", "--disk-fixed":
                let text = try take()
                guard let size = DiskStorage.parseSize(text) else {
                    throw ParseError.invalidValue(option: option, value: text, hint: "a size like 64G")
                }
                let fixed = option == "--disk-fixed"
                options.disk = StoragePolicy(mode: fixed ? .fixed : .dynamic, size: size, autoGrow: !fixed)
            default:
                remaining.append(argument)
            }
            index += 1
        }
        return (options, remaining)
    }

    /// `6G` is fixed memory; `2G-8G` is a dynamic range. Megabytes, whole.
    static func parseMemory(_ text: String) -> MemoryMode? {
        func megabytes(_ part: Substring) -> UInt64? {
            guard let bytes = DiskStorage.parseSize(String(part)), bytes >= 1 << 20 else { return nil }
            return bytes / (1 << 20)
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return megabytes(parts[0]).map { .manual(megabytes: $0) }
        case 2:
            guard let floor = megabytes(parts[0]), let ceiling = megabytes(parts[1]) else { return nil }
            return .dynamic(floorMegabytes: floor, ceilingMegabytes: ceiling)
        default:
            return nil
        }
    }
}

public enum InstanceSetup {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    /// The same ceiling the Resources card's stepper uses.
    public static var maximumCPUs: Int {
        min(max(1, ProcessInfo.processInfo.processorCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    /// Checks the options against this Mac before anything is written, so
    /// `msl new` can refuse without leaving a half-made instance behind.
    /// Returns warnings - things that are allowed but worth saying.
    public static func validate(_ options: InstanceSetupOptions,
                                hostMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                maximumCPUs: Int = InstanceSetup.maximumCPUs) throws -> [String] {
        var warnings: [String] = []
        if let cpus = options.cpus, cpus > maximumCPUs {
            throw Refusal(message: "\(cpus) CPUs is more than this Mac can give one VM - at most \(maximumCPUs)")
        }
        if let memory = options.memory {
            let advice = MemoryAdvisor.advise(mode: memory, hostMemory: hostMemory)
            switch advice.severity {
            case .blocking: throw Refusal(message: advice.message ?? "that memory size can't be used")
            case .caution: if let message = advice.message { warnings.append(message) }
            case .fine: break
            }
        }
        if let disk = options.disk, disk.size < StoragePolicy.minimumSize || disk.size > StoragePolicy.maximumSize {
            throw Refusal(message: "the disk must be between \(DiskStorage.format(StoragePolicy.minimumSize)) and \(DiskStorage.format(StoragePolicy.maximumSize))")
        }
        return warnings
    }

    /// Writes the options for `instance`. CPUs and memory are per instance;
    /// the disk belongs to the distro's image, shared by every instance of
    /// it, so the message says which file it changed.
    ///
    /// `isRunning` because neither can reach a running VM: memory and CPUs
    /// are fixed when it boots. `diskInUseBy` is every running instance on
    /// the same image, not just this one - the image is shared, so resizing
    /// it under a *different* running instance of the distro is exactly as
    /// unsafe as under this one.
    public static func apply(_ options: InstanceSetupOptions, instance: String, distro: GuestDistro,
                             isRunning: Bool, diskInUseBy: [String],
                             reservationProgress: ((DiskStorage.ReservationProgress) -> Void)? = nil) throws -> [String] {
        var lines: [String] = []
        if options.cpus != nil || options.memory != nil {
            var policy = ResourcePolicyStore.load(instance: instance)
            if let cpus = options.cpus { policy.cpuCount = cpus }
            if let memory = options.memory { policy.memory = memory }
            guard ResourcePolicyStore.save(policy, instance: instance) else {
                throw Refusal(message: "couldn't save the CPU and memory settings for \(instance)")
            }
            if let cpus = options.cpus { lines.append("cpus    \(cpus)") }
            if let memory = options.memory { lines.append("memory  \(describe(memory))") }
            if isRunning { lines.append("        takes effect the next time \(instance) starts") }
        }

        if let disk = options.disk {
            let boot = distro.bootFiles()
            let imageName = boot.storageKey
            let imagePath = boot.disk.path
            DiskStorage.setPolicy(disk, forImageNamed: imageName)
            lines.append("disk    \(describe(disk))")
            if !FileManager.default.fileExists(atPath: imagePath) {
                lines.append("        used when \(distro.rawValue) is installed")
            } else if !diskInUseBy.isEmpty {
                lines.append("        takes effect once \(diskInUseBy.joined(separator: ", ")) \(diskInUseBy.count == 1 ? "is" : "are") off - the disk is in use")
            } else {
                let before = DiskStorage.capacity(of: imagePath)
                do {
                    let awake = disk.mode == .fixed ? KeepAwake() : nil
                    defer { awake?.release() }
                    try DiskStorage.setCapacity(of: imagePath, to: disk.size, reserveSpace: disk.mode == .fixed,
                                                progress: reservationProgress)
                } catch {
                    throw Refusal(message: "couldn't resize \(imageName): \(error)")
                }
                // Only when it actually grew - see `msl storage`.
                if DiskStorage.capacity(of: imagePath) > before {
                    DiskStorage.markFilesystemResizePending(forImageNamed: imageName)
                    lines.append("        the guest's filesystem grows to fit on its next start")
                }
            }
        }
        return lines
    }

    /// What an instance has, for `msl resources <instance>` with no options.
    public static func summary(instance: String, distro: GuestDistro) -> [String] {
        let policy = ResourcePolicyStore.load(instance: instance)
        let boot = distro.bootFiles()
        let disk = DiskStorage.policy(forImageNamed: boot.storageKey, path: boot.disk.path)
        var lines = [
            "\(instance) (\(distro.rawValue))",
            "  cpus    \(policy.resolvedCPUCount())\(policy.cpuCount == nil ? " (default)" : "")",
            "  memory  \(describe(policy.resolvedMemory()))\(policy.memory == nil ? " (default)" : "")",
            "  disk    \(describe(disk))",
        ]
        if FileManager.default.fileExists(atPath: boot.disk.path) {
            lines.append("          \(DiskStorage.format(DiskStorage.allocatedSize(of: boot.disk.path))) used on your Mac, shared by every \(distro.rawValue) instance")
        } else {
            lines.append("          not installed yet - `msl install \(distro.rawValue)`")
        }
        return lines
    }

    public static func describe(_ memory: MemoryMode) -> String {
        switch memory {
        case .manual(let megabytes):
            return "\(megabytesText(megabytes)) fixed"
        case .dynamic(let floor, let ceiling):
            return "\(megabytesText(floor))-\(megabytesText(ceiling)) dynamic"
        }
    }

    public static func describe(_ disk: StoragePolicy) -> String {
        disk.mode == .fixed
            ? "\(DiskStorage.format(disk.size)) fixed (reserved on your Mac)"
            : "up to \(DiskStorage.format(disk.size)), dynamic (only what's written)"
    }

    static func megabytesText(_ megabytes: UInt64) -> String {
        megabytes >= 1024 && megabytes % 1024 == 0 ? "\(megabytes / 1024)G" : "\(megabytes)M"
    }
}
