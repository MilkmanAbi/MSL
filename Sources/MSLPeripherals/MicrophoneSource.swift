import AVFoundation
import Foundation
import MSLCore

/// The Mac's microphone - whichever input the person picked - as the samples
/// the guest's "MSL Microphone" expects: 48 kHz, stereo, signed 16-bit
/// little endian, interleaved. macOS is asked for exactly that, so nothing
/// is converted here.
///
/// Like the camera, it runs only while a Linux app is using it, so the
/// microphone indicator in the menu bar means what it says.
final class MicrophoneSource: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "msl.mslps.microphone")
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var deviceID: String?

    /// Called with whole-sample buffers of s16le stereo, on the capture queue.
    var onSamples: (([UInt8]) -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    func select(deviceID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceID = deviceID
            guard self.configured else { return }
            self.session.beginConfiguration()
            self.attachInput()
            self.session.commitConfiguration()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure() {
        session.beginConfiguration()
        attachInput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: PeripheralBridge.sampleRate,
            AVNumberOfChannelsKey: Int(PeripheralBridge.channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    private func attachInput() {
        if let input { session.removeInput(input) }
        input = nil
        let chosen = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let chosen, let newInput = try? AVCaptureDeviceInput(device: chosen),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
    }
}

extension MicrophoneSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let onSamples, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        // Whole stereo s16 samples only: a stray byte would shift every
        // sample after it into noise on the guest side.
        let usable = length - length % 4
        guard usable > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: usable)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: usable, destination: $0.baseAddress!)
        }
        if status == kCMBlockBufferNoErr { onSamples(bytes) }
    }
}
