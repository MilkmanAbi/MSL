import AVFoundation
import CoreVideo
import Foundation
import MSLCore

/// The Mac's camera - whichever one the person picked - captured and handed
/// over in the format a Linux `v4l2loopback` device serves.
///
/// Frames leave here as YUYV 1280x720, the one format every V4L2 application
/// (Cheese, Discord, ROS2's `v4l2_camera`) understands without negotiating.
/// macOS is asked for exactly that - `yuvs` is YUYV byte for byte, and the
/// capture output scales to 1280x720 itself - so a frame costs one copy to
/// drop row padding and no pixel arithmetic. A camera that cannot give
/// `yuvs` falls back to NV12 and `CameraSourceConversion`.
///
/// It captures only while something is using it. A session left running
/// keeps the camera light on with nothing looking through it, which is
/// exactly the behaviour that makes people distrust an application.
public final class CameraSource: NSObject {
    public static let width = PeripheralWire.cameraWidth
    public static let height = PeripheralWire.cameraHeight

    public let session = AVCaptureSession()

    /// The live preview in MSL Peripherals' window.
    ///
    /// Owned here, and attached to the session on the capture queue before
    /// it starts - never created by the view. `AVCaptureVideoPreviewLayer(
    /// session:)` adds a connection to the session, and building it on the
    /// main thread while this queue was inside `startRunning` crashed the
    /// app: "collection was mutated while being enumerated", every time
    /// sharing was allowed with the window still alive (hidden SwiftUI views
    /// still update). Everything that touches the session graph now happens
    /// on one serial queue.
    public let previewLayer = AVCaptureVideoPreviewLayer()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "msl.mslps.camera")
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var deviceID: String?
    private var packedYUYV = true

    /// Called for every frame, already YUYV 1280x720, on the capture queue.
    public var onFrame: (([UInt8]) -> Void)?

    public override init() {
        super.init()
    }

    /// Every camera macOS can see right now: built in, USB, Continuity.
    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    /// Switches cameras, live if it is running. nil means the system
    /// default.
    public func select(deviceID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceID = deviceID
            guard self.configured else { return }
            self.session.beginConfiguration()
            self.attachInput()
            self.session.commitConfiguration()
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    public var isRunning: Bool { session.isRunning }

    private func configure() {
        session.beginConfiguration()
        // 720p when the camera offers it; anything else is scaled by the
        // output below, so a USB camera without a 720p mode still works.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        attachInput()

        let yuvs = kCVPixelFormatType_422YpCbCr8_yuvs
        packedYUYV = output.availableVideoPixelFormatTypes.contains(yuvs)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                packedYUYV ? yuvs : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        previewLayer.session = session
        configured = true
    }

    /// Replaces the input with the chosen camera. Inside a configuration
    /// block, so switching never tears the session down.
    private func attachInput() {
        if let input { session.removeInput(input) }
        input = nil
        let chosen = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let chosen, let newInput = try? AVCaptureDeviceInput(device: chosen),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let onFrame, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // The guest's device is one size. A frame of any other size would
        // be refused there and cost a reconnect, so it is not sent.
        guard width == Self.width, height == Self.height else { return }

        if CVPixelBufferGetPlaneCount(pixelBuffer) == 0 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            onFrame(PeripheralWire.packedYUYV(from: base, width: width, height: height,
                                              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)))
            return
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let luma = [UInt8](UnsafeBufferPointer(start: lumaBase.assumingMemoryBound(to: UInt8.self),
                                               count: lumaStride * height))
        let chroma = [UInt8](UnsafeBufferPointer(start: chromaBase.assumingMemoryBound(to: UInt8.self),
                                                 count: chromaStride * (height / 2)))
        onFrame(CameraSourceConversion.yuyv(fromNV12: luma, chroma: chroma,
                                            width: width, height: height,
                                            lumaStride: lumaStride, chromaStride: chromaStride))
    }
}
