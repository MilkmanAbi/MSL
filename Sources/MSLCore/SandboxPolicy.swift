import Foundation

/// What an instance is allowed to reach.
///
/// Four independent gates, each one a real host-side mechanism rather than
/// a request the guest could decline:
///
/// - `networkCut` sets the live `VZNetworkDevice.attachment` to nil.
/// - `macHomeShareRevoked` sets the live `VZVirtioFileSystemDevice.share`
///   to nil, so `/mnt/mac` stops resolving to anything.
/// - `displayServerDisabled` stops `mslgd`'s vsock listener.
/// - `inputFrozen` drops host input events before they reach the guest.
///
/// That matters for what this is *for*: a compromised or merely untrusted
/// guest cannot undo any of it from the inside, because none of it is
/// implemented inside the guest. What it is **not** is a security boundary
/// in the formal sense - the VM itself is that boundary, and this is a set
/// of switches on top of it.
public struct SandboxPolicy: Equatable, Codable, Sendable {
    public var networkCut: Bool
    public var displayServerDisabled: Bool
    public var inputFrozen: Bool
    public var macHomeShareRevoked: Bool

    public init(networkCut: Bool = false,
                displayServerDisabled: Bool = false,
                inputFrozen: Bool = false,
                macHomeShareRevoked: Bool = false) {
        self.networkCut = networkCut
        self.displayServerDisabled = displayServerDisabled
        self.inputFrozen = inputFrozen
        self.macHomeShareRevoked = macHomeShareRevoked
    }

    /// Nothing restricted - what every instance gets unless asked otherwise.
    public static let open = SandboxPolicy()

    /// Everything off at once. The panic button, and the reason the gates
    /// are one struct rather than four scattered booleans.
    public static let sealed = SandboxPolicy(networkCut: true,
                                             displayServerDisabled: true,
                                             inputFrozen: true,
                                             macHomeShareRevoked: true)

    public var isOpen: Bool { self == .open }
    public var isSealed: Bool { self == .sealed }

    /// How many gates are closed. Drives the summary line in the UI.
    public var closedGateCount: Int {
        [networkCut, displayServerDisabled, inputFrozen, macHomeShareRevoked]
            .filter { $0 }.count
    }

    /// A one-word state for a badge.
    public enum Posture: String, Equatable, Sendable {
        case open = "Open"
        case partial = "Partly sealed"
        case sealed = "Sealed"
    }

    public var posture: Posture {
        if isSealed { return .sealed }
        return closedGateCount == 0 ? .open : .partial
    }

    /// The gates, in a fixed order, for rendering. Kept here rather than in
    /// the view so the labels and the semantics live together.
    public enum Gate: String, CaseIterable, Identifiable, Sendable {
        case network, macHomeShare, displayServer, input
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .network:       return "Network"
            case .macHomeShare:  return "Mac home share"
            case .displayServer: return "Graphics (mslgd)"
            case .input:         return "Keyboard & mouse"
            }
        }

        /// What closing this gate actually does - written to be honest
        /// about scope, because "cut the internet" and "cut this VM's
        /// virtual NIC" are not the same claim.
        public var closedDetail: String {
            switch self {
            case .network:
                return "The virtual network card is detached. The guest keeps its "
                     + "IP and routes but no packet reaches the host, so it looks "
                     + "like an unplugged cable rather than a firewall block."
            case .macHomeShare:
                return "/mnt/mac stops resolving. Anything already reading a file "
                     + "there will see I/O errors, not a clean unmount."
            case .displayServer:
                return "mslgd stops accepting new X11 connections. Windows that "
                     + "are already open keep their connection and keep drawing."
            case .input:
                return "Keyboard and pointer events are dropped on the host side, "
                     + "before they are encoded. The guest sees an idle input "
                     + "device, not a disconnected one."
            }
        }

        public var symbol: String {
            switch self {
            case .network:       return "network"
            case .macHomeShare:  return "folder.badge.person.crop"
            case .displayServer: return "display"
            case .input:         return "keyboard"
            }
        }
    }

    public func isClosed(_ gate: Gate) -> Bool {
        switch gate {
        case .network:       return networkCut
        case .macHomeShare:  return macHomeShareRevoked
        case .displayServer: return displayServerDisabled
        case .input:         return inputFrozen
        }
    }

    public mutating func set(_ gate: Gate, closed: Bool) {
        switch gate {
        case .network:       networkCut = closed
        case .macHomeShare:  macHomeShareRevoked = closed
        case .displayServer: displayServerDisabled = closed
        case .input:         inputFrozen = closed
        }
    }

    // MARK: - Wire form

    /// Encoded for the daemon protocol, which is line-based text - four
    /// flags as one compact token rather than four commands.
    ///
    /// Order is fixed and append-only: a future gate goes on the end, so an
    /// older peer reading a longer string still reads the gates it knows.
    public var wireToken: String {
        let flags = [networkCut, macHomeShareRevoked, displayServerDisabled, inputFrozen]
        return flags.map { $0 ? "1" : "0" }.joined()
    }

    /// Parses `wireToken`. Unknown trailing characters are ignored (a newer
    /// peer with more gates), and a short or malformed token yields nil
    /// rather than a half-applied policy - applying half of a sandbox is
    /// worse than refusing the whole thing.
    public static func fromWireToken(_ token: String) -> SandboxPolicy? {
        let characters = Array(token)
        guard characters.count >= 4 else { return nil }
        guard characters.prefix(4).allSatisfy({ $0 == "0" || $0 == "1" }) else { return nil }
        return SandboxPolicy(networkCut: characters[0] == "1",
                             displayServerDisabled: characters[2] == "1",
                             inputFrozen: characters[3] == "1",
                             macHomeShareRevoked: characters[1] == "1")
    }
}

/// Where a policy lives between runs.
///
/// A sandbox that forgets is not a sandbox: cutting a guest's network and
/// then having a restart quietly restore it is the exact failure this
/// avoids. `VMManager` re-applies the stored policy after every start and
/// every restore, rather than baking it into the VM configuration, so the
/// saved-state format is untouched and a policy change never has to care
/// whether the instance is running.
public enum SandboxPolicyStore {
    public static func file(for instance: String) -> URL {
        MSLPaths.appSupport
            .appendingPathComponent("sandbox", isDirectory: true)
            .appendingPathComponent("\(instance).json")
    }

    public static func load(instance: String) -> SandboxPolicy {
        guard let data = try? Data(contentsOf: file(for: instance)),
              let policy = try? JSONDecoder().decode(SandboxPolicy.self, from: data)
        else { return .open }
        return policy
    }

    /// Best-effort. A policy that fails to persist still applies to the
    /// running VM; the caller is told so it can say so rather than claiming
    /// a durable change it did not make.
    @discardableResult
    public static func save(_ policy: SandboxPolicy, instance: String) -> Bool {
        let url = file(for: instance)
        guard MSLPaths.ensureDirectory(url.deletingLastPathComponent()) else { return false }
        guard let data = try? JSONEncoder().encode(policy) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: file(for: instance))
    }
}
