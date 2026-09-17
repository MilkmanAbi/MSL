import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the Mac has left, for the balloon controller.
///
/// Two sources, trusted very differently.
///
/// The **pressure level** (`kern.memorystatus_vm_pressure_level`) is the
/// number macOS actually stands behind - it is what the kernel publishes to
/// applications through `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` to tell them
/// to shed caches, and it accounts for the compressor and swap in ways no
/// arithmetic here could. The controller treats it as authoritative.
///
/// The **byte counts** from `host_statistics64` are advisory. "Free" memory
/// on macOS is close to meaningless: memory is compressed rather than paged,
/// inactive pages are usually reclaimable, and a healthy Mac normally shows
/// very little free. Building precise accounting on these numbers would be
/// building on sand, so they only ever answer the loose question "is there
/// obviously room to grow?"
public enum HostMemoryMonitor {
    public static func sample(now: Date = Date()) -> HostMemorySample {
        HostMemorySample(
            physical: ProcessInfo.processInfo.physicalMemory,
            availableBytes: availableBytes(),
            pressure: pressure(),
            capturedAt: now)
    }

    /// 1 = normal, 2 = warn, 4 = critical. These are the
    /// `DISPATCH_MEMORYPRESSURE_*` values; anything unrecognised is treated
    /// as normal rather than as an emergency, since guessing "critical"
    /// would shrink every guest on the machine over a failed sysctl.
    public static func pressure() -> HostMemorySample.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    /// Free + inactive + speculative + purgeable, in bytes.
    ///
    /// Inactive and speculative are included because on macOS they are
    /// ordinarily reclaimable on demand - excluding them would report a
    /// perfectly healthy Mac as having almost nothing left, and the
    /// controller would never let a guest grow.
    public static func availableBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            // Better to report nothing available than to invent a figure: the
            // controller reads "no room" as "do not grow", which is the safe
            // reading of an unknown host.
            return 0
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }

        let reclaimable = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return reclaimable * UInt64(pageSize)
    }
}
