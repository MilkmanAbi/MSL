import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// The macOS privacy permissions MSL actually uses, and how to ask for them.
///
/// macOS offers no way to *grant* a permission - only to raise its prompt, read
/// its status where an API exists, or open the right pane of System Settings.
/// So "grant all" here means raising every prompt at one moment the user chose,
/// instead of one at a time whenever some feature first touches it.
///
/// Why these prompts kept coming back: MSL is ad-hoc signed, and privacy
/// grants are tied to the signing identity, which changes with every build.
/// A released build signed with a stable identity keeps its grants.
public enum MacPermissions {
    public enum State: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
        /// Not asked about yet in this session - some permissions have no
        /// status API, and checking them is the same as asking.
        case notChecked
        case unavailable(String)

        public var isGranted: Bool { self == .granted }
    }

    // MARK: - Automation (Terminal)

    public static let terminalBundleIdentifier = "com.apple.Terminal"

    /// `AEDeterminePermissionToAutomateTarget`'s result, as a state.
    public static func automationState(osStatus: Int32) -> State {
        switch osStatus {
        case 0: return .granted
        case -1743: return .denied          // errAEEventNotPermitted
        case -1744: return .notDetermined   // errAEEventWouldRequireUserConsent
        case -600: return .unavailable("Terminal isn't running") // procNotFound
        default: return .unavailable("macOS answered \(osStatus)")
        }
    }

    #if canImport(CoreServices)
    /// Whether MSL may send Apple events to `bundleIdentifier`. With `ask`,
    /// raises the prompt if the user hasn't decided yet - blocks until they
    /// answer, so never call it on the main thread.
    public static func automationStatus(bundleIdentifier: String, ask: Bool) -> Int32 {
        var target = AEAddressDesc()
        let created = bundleIdentifier.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return Int32(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
    #endif

    // MARK: - Folders and volumes

    /// The folders macOS guards individually, which MSL Files shows.
    public static let protectedFolders: [(name: String, directory: FileManager.SearchPathDirectory)] = [
        ("Desktop", .desktopDirectory),
        ("Documents", .documentDirectory),
        ("Downloads", .downloadsDirectory),
    ]

    /// Reading a guarded folder is how its prompt is raised, and its outcome
    /// is the only status there is.
    public static func folderState(readError: Error?) -> State {
        guard let readError else { return .granted }
        let nsError = readError as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return .denied }
        if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           posix.domain == NSPOSIXErrorDomain, posix.code == Int(EPERM) || posix.code == Int(EACCES) {
            return .denied
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return .denied
        }
        return .unavailable(nsError.localizedDescription)
    }

    /// Lists `path` - raising the folder's or volume's prompt if it hasn't
    /// been answered - and reports what came of it. Blocks while a prompt is
    /// up.
    public static func requestRead(path: String) -> State {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .granted
        } catch {
            return folderState(readError: error)
        }
    }

    // MARK: - Full Disk Access

    /// Readable only with Full Disk Access, and reading it never prompts - the
    /// usual way to ask "do I have it" without asking the user.
    public static let fullDiskAccessProbePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    public static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: fullDiskAccessProbePath)
    }

    // MARK: - System Settings

    public enum Pane: String, CaseIterable, Sendable {
        case automation = "Privacy_Automation"
        case filesAndFolders = "Privacy_FilesAndFolders"
        case fullDiskAccess = "Privacy_AllFiles"
        case localNetwork = "Privacy_LocalNetwork"

        public var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }
}
