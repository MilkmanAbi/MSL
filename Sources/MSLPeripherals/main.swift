import AVFoundation
import MSLCore
import SwiftUI

/// MSL Peripherals: the small Mac application that lends the Mac's camera
/// and microphone to Linux applications.
///
/// **Why it is a separate app at all.** macOS grants camera and microphone
/// access to an application - one with a bundle, a name and a usage
/// description it shows the person. `mslhd` is a background daemon with no
/// bundle, so it cannot be granted either, and should not be: a daemon that
/// could quietly hold the camera is precisely what nobody wants running on
/// their Mac.
///
/// **Why the person decides, not Linux.** Every guest always has an "MSL
/// Camera" and an "MSL Microphone" - a placeholder picture and silence -
/// because an app that finds a device which never answers hangs, while one
/// that finds a working device showing "off" behaves. When a Linux app
/// starts using either, this app is told which app it is and asks the
/// person. Real frames flow only after they say yes, and only while that
/// app is actually using the device, so the camera light and the
/// microphone indicator mean what they say. A guest can ask; it can never
/// switch anything on.
/// Plain AppKit, not SwiftUI's `App`: this app's one window has to appear
/// by itself when a Linux app asks for a device and go away once answered,
/// which SwiftUI's scenes cannot do after being closed - and a SwiftUI app
/// with no window scene opens an empty Settings window of its own at launch.
@main
enum MSLPeripheralsMain {
    static func main() {
        // No window restoration. After a crash, macOS asks "reopen windows?"
        // before the app finishes launching, and while that sits there the
        // Linux app that asked for the camera waits on a helper that is not
        // listening yet. Nothing in this window is worth restoring.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true,
                                                  "NSQuitAlwaysKeepsWindows": false])
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.mainMenu = makeMainMenu()
            app.run()
        }
    }

    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MSL Peripherals",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MSL Peripherals", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MSL Peripherals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = PeripheralsModel()
    private var window: NSWindow?

    /// This app is what streams the camera and the microphone, so closing
    /// its window must not stop them. It stays in the Dock; clicking it
    /// brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic: ask macOS for camera access with no UI at all, write
        // what came back to /tmp/msl-peripherals-probe.txt, and quit. The
        // way to see who TCC thinks is asking without clicking anything: a
        // correct identity gets an answer, a wrong one gets the app killed
        // with "no usage description". It is how the missing strings on the
        // enclosing MSL.app were found.
        if CommandLine.arguments.contains("--probe-tcc") {
            let out = URL(fileURLWithPath: "/tmp/msl-peripherals-probe.txt")
            func note(_ line: String) {
                let text = "\(Date()) pid=\(getpid()) \(Bundle.main.bundlePath): \(line)\n"
                if let h = try? FileHandle(forWritingTo: out) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
                else { try? text.write(to: out, atomically: true, encoding: .utf8) }
            }
            note("status before=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) - requesting")
            AVCaptureDevice.requestAccess(for: .video) { granted in note("granted=\(granted)") }
            return
        }
        model.showWindow = { [weak self] in self?.showWindow() }
        model.hideWindow = { [weak self] in self?.window?.orderOut(nil) }
        // Opened by mslhd for a Linux app's request (`--on-request`): the
        // window appears with that request in it, when the request arrives -
        // not before, empty.
        if !CommandLine.arguments.contains("--on-request") { showWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutDown()
        // Sharing is a live state, not a saved preference. Leaving "camera
        // on" in a file after this app has gone would be a lie, and the
        // daemon would go on believing it.
        PeripheralSharingStore.clear()
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "MSL Peripherals"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PeripheralsView(model: model)
                .frame(minWidth: 460, minHeight: 420))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A device macOS can see, for the pickers.
struct DeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Which instances the camera and microphone should reach right now, read
/// from the capture queues. Locked rather than main-actor: frames arrive on
/// AVFoundation's queues and must not wait on the UI.
final class CaptureTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var camera: Set<String> = []
    private var microphone: Set<String> = []

    func set(_ instances: Set<String>, for device: PeripheralSharing.Device) {
        lock.lock(); defer { lock.unlock() }
        if device == .camera { camera = instances } else { microphone = instances }
    }

    func get(_ device: PeripheralSharing.Device) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return device == .camera ? camera : microphone
    }
}

/// A Linux app waiting for an answer about a device.
struct PeripheralRequest: Identifiable, Equatable {
    let device: PeripheralSharing.Device
    let instance: String
    let application: String
    var id: String { "\(device.rawValue) \(instance)" }
}

@MainActor
final class PeripheralsModel: ObservableObject {
    @Published private(set) var instances: [String] = []
    @Published var sharing = PeripheralSharingStore.load()
    @Published private(set) var cameraAuthorised = false
    @Published private(set) var microphoneAuthorised = false
    @Published var problem: String?

    /// Which Linux app is using each device, per instance, as the guest
    /// reports it. Empty means nothing is.
    @Published private(set) var usage: [PeripheralSharing.Device: [String: String]] = [:]
    @Published private(set) var cameras: [DeviceChoice] = []
    @Published private(set) var microphones: [DeviceChoice] = []
    @Published var selectedCamera: String? {
        didSet { UserDefaults.standard.set(selectedCamera, forKey: "selectedCamera"); camera.select(deviceID: selectedCamera) }
    }
    @Published var selectedMicrophone: String? {
        didSet { UserDefaults.standard.set(selectedMicrophone, forKey: "selectedMicrophone"); microphone.select(deviceID: selectedMicrophone) }
    }
    @Published private(set) var cameraRunning = false
    /// Linux apps waiting for an answer, oldest first. Shown at the top of
    /// the window, which comes forward by itself when one arrives.
    @Published private(set) var requests: [PeripheralRequest] = []

    /// Set by the app delegate, which owns the window.
    var showWindow: (() -> Void)?
    var hideWindow: (() -> Void)?

    let camera = CameraSource()
    let microphone = MicrophoneSource()
    private let server = PeripheralServer()
    private let targets = CaptureTargets()

    init() {
        reloadInstances()
        refreshAuthorisation()
        // Never inherit sharing from a previous run.
        PeripheralSharingStore.clear()
        sharing = PeripheralSharing()

        reloadDevices()
        // The chosen device is a preference, not consent, so it IS
        // remembered - unlike sharing.
        selectedCamera = UserDefaults.standard.string(forKey: "selectedCamera")
        selectedMicrophone = UserDefaults.standard.string(forKey: "selectedMicrophone")
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadDevices() }
            }
        }

        let server = self.server, targets = self.targets
        camera.onFrame = { frame in server.sendFrame(frame, to: targets.get(.camera)) }
        microphone.onSamples = { pcm in server.sendSamples(pcm, to: targets.get(.microphone)) }
        server.onUsageChanged = { [weak self] device, instance, application in
            self?.usageChanged(device, instance: instance, application: application)
        }
        server.start()
    }

    func shutDown() { server.stop() }

    func reloadInstances() {
        let registry = InstanceRegistry(path: URL(fileURLWithPath: DaemonProtocol.defaultInstanceRegistryPath()))
        instances = registry.list().sorted()
    }

    /// A USB camera or microphone plugged in or pulled out shows up here
    /// at once. If the one in use disappears, the system default takes
    /// over rather than the picture freezing on a device that is gone.
    func reloadDevices() {
        cameras = CameraSource.availableDevices().map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        microphones = MicrophoneSource.availableDevices().map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        if let chosen = selectedCamera, !cameras.contains(where: { $0.id == chosen }) { selectedCamera = nil }
        if let chosen = selectedMicrophone, !microphones.contains(where: { $0.id == chosen }) { selectedMicrophone = nil }
    }

    func isShared(_ device: PeripheralSharing.Device, _ instance: String) -> Bool {
        sharing.isShared(device, with: instance)
    }

    func application(using device: PeripheralSharing.Device, in instance: String) -> String? {
        usage[device]?[instance]
    }

    /// Turning a device on asks macOS first, and only writes the shared
    /// state once it has actually been granted. Writing it first would tell
    /// the daemon a camera was available that this app cannot open.
    func setShared(_ shared: Bool, device: PeripheralSharing.Device, instance: String) {
        guard shared else {
            apply(false, device: device, instance: instance)
            return
        }
        let mediaType: AVMediaType = device == .camera ? .video : .audio
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            apply(true, device: device, instance: instance)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshAuthorisation()
                    if granted {
                        self.apply(true, device: device, instance: instance)
                    } else {
                        self.problem = "\(device.label) access was declined, so nothing is being shared."
                    }
                }
            }
        case .denied, .restricted:
            problem = "\(device.label) access is off for MSL Peripherals in System Settings, "
                    + "under Privacy & Security."
        @unknown default:
            problem = "macOS would not say whether \(device.label.lowercased()) access is allowed."
        }
    }

    private func apply(_ shared: Bool, device: PeripheralSharing.Device, instance: String) {
        problem = nil
        sharing.setShared(shared, device: device, with: instance)
        PeripheralSharingStore.save(sharing)
        refreshAuthorisation()
        refreshCapture()
    }

    /// A Linux app started or stopped using a device. Starting one that
    /// has not been allowed is what asks the person - in this window, which
    /// comes forward with the request in it - unless they turned on "Omit
    /// MSL Peripherals prompt for media devices", in which case it is
    /// allowed straight away (macOS's own permission is still asked once).
    private func usageChanged(_ device: PeripheralSharing.Device, instance: String, application: String?) {
        var perInstance = usage[device] ?? [:]
        perInstance[instance] = application
        usage[device] = perInstance

        let id = "\(device.rawValue) \(instance)"
        if let application, !sharing.isShared(device, with: instance) {
            if MSLExperimentalSettingsStore.load().omitPeripheralsPrompt {
                setShared(true, device: device, instance: instance)
            } else {
                requests.removeAll { $0.id == id }
                requests.append(PeripheralRequest(device: device, instance: instance, application: application))
                showWindow?()
            }
        } else if application == nil {
            // The app gave up before anyone answered: nothing left to ask.
            let hadRequest = requests.contains { $0.id == id }
            requests.removeAll { $0.id == id }
            if hadRequest && requests.isEmpty { hideWindow?() }
        }
        refreshCapture()
    }

    /// The person's answer. The window goes away as soon as nothing is left
    /// to answer, and only then does macOS ask for its own permission (the
    /// first time) - so the choice of device always comes first.
    func answer(_ request: PeripheralRequest, allow: Bool) {
        requests.removeAll { $0.id == request.id }
        if requests.isEmpty { hideWindow?() }
        guard allow, application(using: request.device, in: request.instance) != nil else { return }
        setShared(true, device: request.device, instance: request.instance)
    }

    /// Each device runs only while an instance that is allowed to use it
    /// has an app actually using it. Allowed-but-idle keeps the light off.
    private func refreshCapture() {
        for device in PeripheralSharing.Device.allCases {
            let allowed = device == .camera ? sharing.camera : sharing.microphone
            let using = Set((usage[device] ?? [:]).keys)
            let live = allowed.intersection(using)
            targets.set(live, for: device)
            if device == .camera {
                if live.isEmpty { camera.stop() } else { camera.start() }
                cameraRunning = !live.isEmpty
            } else {
                if live.isEmpty { microphone.stop() } else { microphone.start() }
            }
        }
    }

    private func refreshAuthorisation() {
        cameraAuthorised = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneAuthorised = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

struct PeripheralsView: View {
    @ObservedObject var model: PeripheralsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ForEach(model.requests) { request in
                RequestCard(model: model, request: request)
            }

            if model.instances.isEmpty {
                ContentUnavailableView("No instances yet",
                                       systemImage: "shippingbox",
                                       description: Text("Create a Linux instance in MSL first."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.instances, id: \.self) { instance in
                    InstanceRow(model: model, instance: instance)
                }
                .listStyle(.inset)
            }

            sources

            if model.cameraRunning {
                CameraPreview(source: model.camera)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Label("Live", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            } else {
                Label(model.sharing.camera.isEmpty
                        ? "The camera is off. Linux sees a placeholder."
                        : "Allowed. The camera turns on when a Linux app uses it.",
                      systemImage: "video.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Linux always has a camera and a microphone; they stay blank until you allow them here. Closing this window keeps sharing going; quitting MSL Peripherals stops it. A Linux app can ask, but never turn a device on by itself.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { model.reloadInstances() }
    }

    /// Which of this Mac's devices Linux gets. Updates live when a USB
    /// camera or microphone is plugged in or pulled out. Sound going the
    /// other way needs no choice: it plays wherever this Mac's output is
    /// set.
    private var sources: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Camera", selection: $model.selectedCamera) {
                    Text("System default").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Microphone", selection: $model.selectedMicrophone) {
                    Text("System default").tag(String?.none)
                    ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("Sound from Linux plays through this Mac's current output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label("Sources", systemImage: "slider.horizontal.3")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MSL Peripherals").font(.title2).bold()
                Text("Lend this Mac's camera and microphone to a Linux instance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// "cheese in Milk wants your camera": which app, which instance, and
/// which of this Mac's devices it would get - chosen here, before anything
/// is shared. Linux is not kept waiting meanwhile: its camera and
/// microphone exist already and are only blank.
private struct RequestCard: View {
    @ObservedObject var model: PeripheralsModel
    let request: PeripheralRequest

    private var noun: String { request.device == .camera ? "camera" : "microphone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.device == .camera ? "video.fill" : "mic.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\u{201C}\(request.application)\u{201D} in \(request.instance) wants your \(noun)")
                        .font(.headline)
                    Text("Linux sees a blank \(noun) until you allow it. Choose which one it gets.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if request.device == .camera {
                Picker("Camera", selection: $model.selectedCamera) {
                    Text("System default").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
            } else {
                Picker("Microphone", selection: $model.selectedMicrophone) {
                    Text("System default").tag(String?.none)
                    ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            HStack {
                Spacer()
                Button("Don\u{2019}t Allow") { model.answer(request, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.answer(request, allow: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.tint.opacity(0.35)))
    }
}

private struct InstanceRow: View {
    @ObservedObject var model: PeripheralsModel
    let instance: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(instance).font(.headline)
            ForEach(PeripheralSharing.Device.allCases, id: \.self) { device in
                HStack {
                    Toggle(device.label, isOn: Binding(
                        get: { model.isShared(device, instance) },
                        set: { model.setShared($0, device: device, instance: instance) }))
                    .help(device.explanation)
                    Spacer()
                    if let app = model.application(using: device, in: instance) {
                        Label("\(app) is using it", systemImage: model.isShared(device, instance) ? "dot.radiowaves.left.and.right" : "hand.raised")
                            .font(.caption)
                            .foregroundStyle(model.isShared(device, instance) ? .green : .orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The preview is not decoration. It is how someone knows, at a glance,
/// exactly what a Linux application can see right now.
struct CameraPreview: NSViewRepresentable {
    let source: CameraSource

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        // The source's own layer, already attached to the session on the
        // capture queue. Creating one here would add a connection to the
        // session from the main thread - see `CameraSource.previewLayer`.
        let layer = source.previewLayer
        layer.removeFromSuperlayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
