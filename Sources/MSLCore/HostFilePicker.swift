import Foundation

/// A Linux app asking the Mac to choose a file.
///
/// The Linux side of this is `org.freedesktop.portal.FileChooser`: when a GTK
/// or Qt app is told to use portals, its Open/Save dialog becomes a D-Bus
/// call rather than a dialog it draws itself. MSL answers that call, so the
/// person gets **MSL Files** - which can see the Mac's own disk as well as
/// the guest's - instead of a Linux file chooser that can only see inside
/// Linux.
public struct HostFilePickRequest: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case open
        case save
        case directory
    }

    public var mode: Mode
    /// Where to start, as a guest path. `/` when the app does not say.
    public var startGuestPath: String
    /// The name a Save picker should start with.
    public var suggestedName: String
    public var allowsMultiple: Bool
    /// The app's own title for the dialog.
    public var title: String

    public init(mode: Mode, startGuestPath: String = "/", suggestedName: String = "",
                allowsMultiple: Bool = false, title: String = "") {
        self.mode = mode
        self.startGuestPath = startGuestPath
        self.suggestedName = suggestedName
        self.allowsMultiple = allowsMultiple
        self.title = title
    }
}

/// Turning what the picker returns into paths the guest can open.
///
/// **Presentation lives in MSL Files, not here.** `mslhd` is a launchd agent
/// with no windows and cannot put a panel on screen at all - both attempts
/// are written up in `READMES/24-FILE-PICKER.md`, and the second one hung
/// every Linux app that asked for a file. What is left here is the part that
/// is pure, shared and worth testing on its own: the translation, and the
/// rule about what the guest may be handed.
public enum HostFilePicker {
    /// Turns chosen host paths into paths **the guest can actually open**.
    ///
    /// Anything the guest cannot reach is dropped rather than returned: a
    /// path on an external disk or in another user's home has no guest
    /// equivalent, and handing one over would give the app a path that
    /// silently does not exist. `GuestPathMapper` already knows the two
    /// routes in - the instance's own mount, and the Mac home share at
    /// `/mnt/mac` - so this is only the translation and the refusal.
    public static func guestPaths(for hostPaths: [String], instance: String,
                                  mountPath: String?) -> [String] {
        let mounts = mountPath.map { [GuestMount(instance: instance, mountPath: $0)] } ?? []
        return hostPaths.compactMap { hostPath in
            switch GuestPathMapper.map(hostPath: hostPath, guestMounts: mounts) {
            case .guestFilesystem(let mappedInstance, let guestPath):
                // Another instance's mount is not this app's filesystem.
                return mappedInstance == instance ? guestPath : nil
            case .macHomeShare(let guestPath):
                return guestPath
            case .unreachable:
                return nil
            }
        }
    }

    /// Where the picker should open, as a host path. Falls back to the mount
    /// root rather than nowhere when the requested folder has gone.
    public static func startDirectory(guestPath: String, mountPath: String?) -> String? {
        guard let mountPath, guestPath.hasPrefix("/") else { return mountPath }
        let joined = guestPath == "/" ? mountPath : mountPath + guestPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: joined, isDirectory: &isDirectory) else {
            return mountPath
        }
        return isDirectory.boolValue ? joined : (joined as NSString).deletingLastPathComponent
    }
}
