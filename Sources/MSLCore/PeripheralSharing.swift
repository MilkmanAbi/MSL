import Foundation

/// Which instances are being given the Mac's camera or microphone, right
/// now.
///
/// The rule this type exists to enforce: **a guest can never turn a device
/// on.** Sharing starts on the Mac, in MSL Peripherals, where the person can
/// see the camera light and the preview. Nothing in the guest writes here,
/// and `mslpsd` is only ever handed a stream that is already allowed.
///
/// Not remembered across launches on purpose. A camera that was on yesterday
/// is not consent for today, and the file exists so that MSL's own processes
/// agree with each other while it is on, not to persist a preference.
public struct PeripheralSharing: Codable, Equatable, Sendable {
    /// Instances whose windows can see the Mac's camera.
    public var camera: Set<String>
    /// Instances that can hear the Mac's microphone.
    public var microphone: Set<String>

    public init(camera: Set<String> = [], microphone: Set<String> = []) {
        self.camera = camera
        self.microphone = microphone
    }

    public enum Device: String, CaseIterable, Sendable {
        case camera
        case microphone

        public var label: String {
            switch self {
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            }
        }

        /// What macOS shows in its own permission prompt is not this text,
        /// but this is what MSL says first, so the prompt is never a
        /// surprise.
        public var explanation: String {
            switch self {
            case .camera:
                return "Linux apps in this instance will see the Mac's camera as an ordinary webcam. "
                     + "macOS will ask for camera access the first time."
            case .microphone:
                return "Linux apps in this instance will hear the Mac's microphone as an ordinary "
                     + "input device. macOS will ask for microphone access the first time."
            }
        }
    }

    public func isShared(_ device: Device, with instance: String) -> Bool {
        switch device {
        case .camera: return camera.contains(instance)
        case .microphone: return microphone.contains(instance)
        }
    }

    public mutating func setShared(_ shared: Bool, device: Device, with instance: String) {
        switch device {
        case .camera:
            if shared { camera.insert(instance) } else { camera.remove(instance) }
        case .microphone:
            if shared { microphone.insert(instance) } else { microphone.remove(instance) }
        }
    }

    public var isAnythingShared: Bool { !camera.isEmpty || !microphone.isEmpty }
}

/// Reads and writes the sharing state, and tells anyone watching when it
/// changes.
///
/// A file rather than `UserDefaults`, for the same reason as the rest of
/// MSL's shared state: `mslhd` and the helper app are different processes
/// and one of them is not a bundle, so a defaults domain would leave them
/// disagreeing about who is allowed to see a camera. That is not a
/// disagreement worth having.
public enum PeripheralSharingStore {
    public static var file: URL {
        MSLPaths.appSupport.appendingPathComponent("peripherals.json")
    }

    /// Where the helper app listens for frame requests from `mslhd`.
    ///
    /// The helper holds the camera and microphone, because macOS grants
    /// those to an application with a bundle and a name, never to a bare
    /// daemon. `mslhd` owns the guest's vsock. So the frames cross here.
    public static var socketPath: String {
        MSLPaths.appSupport.appendingPathComponent("mslps.sock").path
    }

    /// Posted when the file changes, so the daemon can drop a stream the
    /// moment someone switches it off rather than at the next launch.
    public static let didChange = Notification.Name("MSLPeripheralSharingDidChange")

    public static func load(from url: URL = file) -> PeripheralSharing {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PeripheralSharing.self, from: data)
        else { return PeripheralSharing() }
        return state
    }

    @discardableResult
    public static func save(_ state: PeripheralSharing, to url: URL = file) -> Bool {
        // MSLAP, per device kind and per instance: a policy can allow a
        // microphone while refusing the camera. Only instances GAINING
        // access are checked - removing a share is the safe direction and
        // is never refused, or a policy arriving after a share was granted
        // would trap it in place.
        var state = state
        if MSLAPGate.policy != nil {
            let current = load(from: url)
            for instance in state.camera.subtracting(current.camera)
            where !MSLAPGate.allows("peripherals.camera", instance: instance) {
                state.camera.remove(instance)
            }
            for instance in state.microphone.subtracting(current.microphone)
            where !MSLAPGate.allows("peripherals.microphone", instance: instance) {
                state.microphone.remove(instance)
            }
        }
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(state) else { return false }
        let written = (try? data.write(to: url, options: .atomic)) != nil
        if written { NotificationCenter.default.post(name: didChange, object: nil) }
        return written
    }

    /// Clears everything. Called when the helper app quits: sharing is a
    /// live state, and a camera left "on" in a file after the app that was
    /// showing its preview has gone is exactly the kind of lie this design
    /// is meant to avoid.
    public static func clear(to url: URL = file) {
        save(PeripheralSharing(), to: url)
    }

    @discardableResult
    public static func setShared(_ shared: Bool, device: PeripheralSharing.Device,
                                 with instance: String, in url: URL = file) -> Bool {
        var state = load(from: url)
        state.setShared(shared, device: device, with: instance)
        return save(state, to: url)
    }
}
