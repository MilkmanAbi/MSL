import Foundation

/// The byte formats mslps's three processes agree on: `mslpsd` in the
/// guest, `mslhd`'s `PeripheralBridge`, and the MSL Peripherals app. Kept in
/// one place, with tests, because a disagreement here does not crash - it
/// shows someone a sheared picture or plays noise.
///
/// Guest to Mac, on an input stream (camera, microphone), a control
/// message: `[type][length][application name]`. The guest sends it when a
/// Linux app starts or stops using the device, and that is what makes the
/// Mac ask the person. Mac to guest, camera frames are framed -
/// `'M' 'F' 1 0` + u32 LE length + YUYV - so a connection lost mid-frame can
/// never leave the two ends out of step. Microphone samples are raw 10 ms
/// chunks of 48 kHz stereo s16le, the same as sound out.
public enum PeripheralWire {
    // MARK: camera format, fixed for v1

    public static let cameraWidth = 1280
    public static let cameraHeight = 720
    public static var cameraFrameBytes: Int { cameraWidth * cameraHeight * 2 }

    // MARK: control messages

    public enum Control: Equatable, Sendable {
        /// A Linux application is using the device. The name is the
        /// process name the guest found holding it (e.g. "cheese").
        case inUse(application: String)
        case released
    }

    public static func encode(_ control: Control) -> [UInt8] {
        switch control {
        case .inUse(let application):
            let name = Array(application.utf8.prefix(255))
            return [1, UInt8(name.count)] + name
        case .released:
            return [2, 0]
        }
    }

    /// Reads control messages out of a byte stream as they arrive. Bytes
    /// come in whatever pieces the socket delivers, so a message split
    /// across two reads has to be held until it is whole.
    public struct ControlParser {
        private var pending: [UInt8] = []

        public init() {}

        /// Feeds new bytes; returns every message they complete. A type
        /// this build does not know is skipped by its length rather than
        /// ending the stream, so a newer guest never breaks an older Mac.
        public mutating func feed(_ bytes: [UInt8]) -> [Control] {
            pending += bytes
            var messages: [Control] = []
            while pending.count >= 2 {
                let length = Int(pending[1])
                guard pending.count >= 2 + length else { break }
                let body = Array(pending[2..<(2 + length)])
                switch pending[0] {
                case 1: messages.append(.inUse(application: String(decoding: body, as: UTF8.self)))
                case 2: messages.append(.released)
                default: break
                }
                pending.removeFirst(2 + length)
            }
            return messages
        }
    }

    // MARK: camera frames

    public static let frameHeaderBytes = 8

    public static func frameHeader(payloadBytes: Int) -> [UInt8] {
        let n = UInt32(payloadBytes)
        return [0x4D, 0x46, 1, 0,
                UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    }

    /// The payload length a header announces, or nil when the header is not
    /// one - which means the stream is out of step and has to be dropped.
    public static func payloadLength(ofFrameHeader header: [UInt8]) -> Int? {
        guard header.count == frameHeaderBytes, header[0] == 0x4D, header[1] == 0x46, header[2] == 1 else { return nil }
        return Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
    }

    // MARK: mslhd <-> MSL Peripherals

    /// What `mslhd` says first on a connection to the helper: which stream,
    /// for which instance. One line, so it reads in a debugger.
    public static func helperHello(stream: String, instance: String) -> [UInt8] {
        Array("\(stream) \(instance)\n".utf8)
    }

    public static func parseHelperHello(_ line: String) -> (stream: String, instance: String)? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Converts a `yuvs` pixel buffer (macOS's name for 4:2:2 Y0 Cb Y1 Cr,
    /// which IS V4L2's YUYV byte for byte) into a tight frame, dropping the
    /// row padding camera buffers carry. Reading by width instead of by
    /// stride shears the picture.
    public static func packedYUYV(from base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        let rowBytes = width * 2
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        out.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                memcpy(dst.baseAddress!.advanced(by: row * rowBytes), base.advanced(by: row * bytesPerRow), rowBytes)
            }
        }
        return out
    }
}
