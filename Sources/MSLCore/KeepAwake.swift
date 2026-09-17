import Foundation

/// Keeps the Mac awake while something long runs - a distro download above
/// all, which is gigabytes over whatever connection the user has and used to
/// die whenever the display slept or the lid timer ran out.
///
/// `caffeinate -dimsu`, the same assertions you would ask for by hand:
/// display (`d`), idle (`i`), disk (`m`) and system (`s`) sleep held off, and
/// the user marked active (`u`) so the screen doesn't dim part-way. `-w`
/// ties it to this process as well, so a crash or a Ctrl-C can never leave
/// a stray caffeinate keeping the Mac up after MSL has gone.
public final class KeepAwake {
    private var process: Process?

    /// Starts holding the Mac awake. Never throws: failing to start
    /// caffeinate is no reason to fail the work it was meant to protect.
    public init() {
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        caffeinate.standardOutput = FileHandle.nullDevice
        caffeinate.standardError = FileHandle.nullDevice
        if (try? caffeinate.run()) != nil {
            process = caffeinate
        }
    }

    public var isHolding: Bool { process?.isRunning ?? false }

    /// Lets the Mac sleep again. Safe to call more than once.
    public func release() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    deinit { release() }
}
