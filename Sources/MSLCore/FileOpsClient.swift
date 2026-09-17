import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Talks to `fileopsd` over vsock. Opens a fresh connection per operation
/// (matching the daemon's one-shot-per-connection protocol - see
/// `Guest/init/fileopsd.c`'s doc comment), writes one length-prefixed
/// request frame, reads one length-prefixed response frame, and closes.
/// No connection reuse/pooling - vsock connect is cheap (a virtio ring
/// operation, not a real handshake), and this keeps concurrent requests
/// trivially independent (matching fileopsd's own fork-per-connection
/// model) with no request-ID multiplexing needed.
public final class FileOpsClient {
    private let manager: VMManager
    private let mayWake: () -> Bool

    /// `mayWake` is asked before every operation; when it says no, the
    /// operation fails instead of starting the guest. `VMManager` hands its
    /// WebDAV bridge one that turns false once the bridge is torn down, so a
    /// mount that outlives its VM can't wake a hibernated instance.
    public init(manager: VMManager, mayWake: @escaping () -> Bool = { true }) {
        self.manager = manager
        self.mayWake = mayWake
    }

    /// Lists a directory with LIST2 when the guest's `fileopsd` has it, and
    /// LIST otherwise. LIST2 is binary and length-prefixed, so a name
    /// containing a tab or a newline lists correctly instead of being
    /// skipped; images built before 2026-09-14 don't have it and say EINVAL.
    public func list(_ path: String) async throws -> [FileOpsProtocol.Entry] {
        if probeAllowed(.list2) {
            do {
                return try FileOpsProtocol.parseList2(try await perform(FileOpsProtocol.encodeList2(path: path))).entries
            } catch let error as FileOpsProtocol.FileOpsError where error.isUnsupportedOperation {
                markUnsupported(.list2)
            }
        }
        return try FileOpsProtocol.parseListResponse(try await perform(FileOpsProtocol.encodeList(path: path)))
    }

    /// Sets `path`'s permission bits. Returns `false` - without throwing -
    /// when the guest's `fileopsd` predates CHMOD, so a caller can take its
    /// fallback path; any other failure throws as usual.
    public func chmodIfSupported(_ path: String, mode: UInt32) async throws -> Bool {
        guard probeAllowed(.chmod) else { return false }
        do {
            _ = try await perform(FileOpsProtocol.encodeChmod(path: path, mode: mode))
            return true
        } catch let error as FileOpsProtocol.FileOpsError where error.isUnsupportedOperation {
            markUnsupported(.chmod)
            return false
        }
    }

    // MARK: - Capabilities

    /// Opcodes a guest image may not have. Unknown opcodes come back as
    /// EINVAL - that is the probe - and the answer is remembered so an old
    /// image doesn't pay a failed round trip on every listing.
    enum Capability: Hashable {
        case list2
        case chmod
    }

    /// Remembered only for a while, not forever: the instance behind this
    /// client can be stopped, have a newer image installed, and start again
    /// without mslhd restarting, and that image deserves to be asked again.
    private static let unsupportedMemory: TimeInterval = 10 * 60
    private let capabilityLock = NSLock()
    private var unsupportedUntil: [Capability: Date] = [:]

    private func probeAllowed(_ capability: Capability) -> Bool {
        capabilityLock.lock()
        defer { capabilityLock.unlock() }
        guard let until = unsupportedUntil[capability] else { return true }
        return until <= Date()
    }

    private func markUnsupported(_ capability: Capability) {
        capabilityLock.lock()
        unsupportedUntil[capability] = Date().addingTimeInterval(Self.unsupportedMemory)
        capabilityLock.unlock()
    }

    public func stat(_ path: String) async throws -> FileOpsProtocol.Entry {
        try FileOpsProtocol.parseStatResponse(try await perform(FileOpsProtocol.encodeStat(path: path)))
    }

    public func read(_ path: String, offset: UInt64, length: UInt32) async throws -> Data {
        Data(try await perform(FileOpsProtocol.encodeRead(path: path, offset: offset, length: length)))
    }

    public func write(_ path: String, offset: UInt64, data: Data) async throws {
        _ = try await perform(FileOpsProtocol.encodeWrite(path: path, offset: offset, data: data))
    }

    public func mkdir(_ path: String) async throws {
        _ = try await perform(FileOpsProtocol.encodeMkdir(path: path))
    }

    public func rename(_ src: String, to dst: String) async throws {
        _ = try await perform(FileOpsProtocol.encodeRename(src: src, dst: dst))
    }

    public func unlink(_ path: String) async throws {
        _ = try await perform(FileOpsProtocol.encodeUnlink(path: path))
    }

    /// Opens a fresh connection, sends one request frame, reads one
    /// response frame, and returns its payload (with the leading ok/err
    /// status byte stripped) - throwing `FileOpsProtocol.FileOpsError.
    /// remote` if the daemon reported an error.
    ///
    /// `ensureRunning()` first, unconditionally: the WebDAV mount (the only
    /// real caller of this, via `WebDAVServer`) stays mounted in Finder
    /// regardless of whether the guest is actually awake, and the daemon's
    /// auto-suspend-on-session-close (`DaemonServer`'s `sessionEnded`) only
    /// pauses the VM - it never touches the file sandbox. Confirmed live:
    /// without this, any Finder access after the shell session that started
    /// the instance had closed and it auto-suspended just silently 500'd
    /// (a paused VM refuses new vsock connects) instead of transparently
    /// waking it back up, the same way a new shell session already does via
    /// `DaemonServer.handleSession`. A no-op, fast path when already
    /// running - see `VMManager.ensureRunning`'s own early return.
    private func perform(_ requestPayload: [UInt8]) async throws -> [UInt8] {
        guard mayWake() else { throw VMManagerError.notRunning }
        try await manager.ensureRunning()
        let fd = try await manager.openFileOpsConnection()
        defer { manager.releaseConnection(fd: fd) }

        try Self.writeFrame(fd: fd, payload: requestPayload)
        let response = try Self.readFrame(fd: fd)
        guard let status = response.first else { throw FileOpsProtocol.FileOpsError.malformedResponse }
        let body = Array(response.dropFirst())
        if status == 0x00 {
            return body
        }
        throw FileOpsProtocol.FileOpsError.remote(errno: try FileOpsProtocol.parseErrorResponse(body))
    }

    private static func writeFrame(fd: Int32, payload: [UInt8]) throws {
        let len = UInt32(payload.count)
        let lenBuf: [UInt8] = [
            UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF),
        ]
        try writeFull(fd: fd, bytes: lenBuf)
        if !payload.isEmpty { try writeFull(fd: fd, bytes: payload) }
    }

    /// Largest response frame this will allocate for.
    ///
    /// `readFrame` otherwise takes a guest-supplied 32-bit length at face
    /// value and immediately allocates it, so a desynced or corrupted
    /// header could ask the host for a 4 GiB buffer. The largest legitimate
    /// response is a READ chunk (`WebDAVServer` uses 4 MiB) or a listing of
    /// a very large directory, so 64 MiB is far above anything real and far
    /// below anything dangerous.
    private static let maxFrameBytes: UInt32 = 64 * 1024 * 1024

    private static func readFrame(fd: Int32) throws -> [UInt8] {
        let lenBuf = try readFull(fd: fd, count: 4)
        let len = UInt32(lenBuf[0]) | (UInt32(lenBuf[1]) << 8) | (UInt32(lenBuf[2]) << 16) | (UInt32(lenBuf[3]) << 24)
        guard len > 0 else { return [] }
        guard len <= maxFrameBytes else { throw FileOpsProtocol.FileOpsError.frameTooLarge(len) }
        return try readFull(fd: fd, count: Int(len))
    }

    private static func writeFull(fd: Int32, bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBufferPointer { buf in
            while sent < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FileOpsProtocol.FileOpsError.connectionClosed
                }
                if n == 0 { throw FileOpsProtocol.FileOpsError.connectionClosed }
                sent += n
            }
        }
    }

    private static func readFull(fd: Int32, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        try buf.withUnsafeMutableBufferPointer { ptr in
            while got < count {
                let n = Darwin.read(fd, ptr.baseAddress! + got, count - got)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FileOpsProtocol.FileOpsError.connectionClosed
                }
                if n == 0 { throw FileOpsProtocol.FileOpsError.connectionClosed }
                got += n
            }
        }
        return buf
    }
}
