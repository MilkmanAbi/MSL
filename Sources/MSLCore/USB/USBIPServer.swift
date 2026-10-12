import Foundation

/// Serves one attached device to one guest over an already-connected
/// socket.
///
/// MSL never speaks USB/IP's connection phase: the guest's helper connects
/// to the Mac and writes the live fd straight into
/// `/sys/devices/platform/vhci_hcd.0/attach`, so `vhci_hcd` starts sending
/// `CMD_SUBMIT` immediately with no handshake. This loop therefore begins
/// by reading a 48-byte header, not by answering an import request.
///
/// One server per connection, one connection per device. The read loop is
/// synchronous and single-threaded; backends complete asynchronously and
/// their replies are serialised by `writeLock`, because a partial
/// interleaved write would desynchronise the stream permanently (the guest
/// would read a payload as a header and every URB after it would be
/// garbage).
public final class USBIPServer {
    private let fd: Int32
    private let backend: USBIPDeviceBackend
    private let logger: ((String) -> Void)?
    /// Per-URB tracing. Off by default - a busy device is thousands of
    /// URBs a second and logging each one changes the timing enough to
    /// matter. Turned on by `MSL_USBIP_TRACE` while bringing a device up.
    private let trace: ((String) -> Void)?
    private let writeLock = NSLock()
    /// URBs handed to the backend and not yet answered, so an `UNLINK` can
    /// ask the backend to drop them.
    private let pendingLock = NSLock()
    private var pending = Set<UInt32>()
    private var stopped = false

    public init(fd: Int32, backend: USBIPDeviceBackend, log: ((String) -> Void)? = nil) {
        self.fd = fd
        self.backend = backend
        self.logger = log
        self.trace = ProcessInfo.processInfo.environment["MSL_USBIP_TRACE"] != nil ? log : nil
    }

    /// Runs until the guest detaches or the socket breaks. Blocking - call
    /// it on its own thread.
    public func run() {
        logger?("serving \(backend.displayName)")
        var header = [UInt8](repeating: 0, count: usbipHeaderSize)
        while !stopped {
            guard readFull(&header, usbipHeaderSize) else { break }
            guard let request = header.withUnsafeBufferPointer({ buffer in
                USBIPRequest(header: buffer.baseAddress!)
            }) else {
                logger?("unrecognised PDU - the stream is out of sync, closing")
                break
            }

            switch request.command {
            case .submit:
                guard let full = readPayload(for: request) else { return finish() }
                trace?("CMD_SUBMIT seq=\(full.seqnum) ep=\(full.endpoint) dir=\(full.direction) len=\(full.transferBufferLength)"
                    + (full.controlSetup.map { " setup[\($0.description)]" } ?? ""))
                dispatch(full)
            case .unlink:
                // Answer the guest first, always: `vhci_hcd` will not
                // retire the URB until it sees a RET_UNLINK, and a backend
                // that cannot cancel would otherwise wedge it.
                backend.cancel(seqnum: request.unlinkSeqnum)
                pendingLock.lock()
                let wasPending = pending.remove(request.unlinkSeqnum) != nil
                pendingLock.unlock()
                send(.unlink(to: request, status: wasPending ? USBIPStatus.cancelled : USBIPStatus.success))
            case .returnSubmit, .returnUnlink:
                logger?("guest sent a reply command - closing")
                return finish()
            }
        }
        finish()
    }

    public func stop() {
        stopped = true
        shutdown(fd, SHUT_RDWR)
    }

    private func finish() {
        logger?("guest detached from \(backend.displayName)")
        backend.teardown()
    }

    private func dispatch(_ request: USBIPRequest) {
        pendingLock.lock()
        pending.insert(request.seqnum)
        pendingLock.unlock()
        backend.submit(request) { [weak self] reply in
            guard let self else { return }
            self.pendingLock.lock()
            let stillWanted = self.pending.remove(reply.seqnum) != nil
            self.pendingLock.unlock()
            // Dropped by an UNLINK while the backend was working on it:
            // the guest has already been told, and a second reply for the
            // same seqnum is a protocol violation.
            guard stillWanted else { return }
            self.send(reply)
        }
    }

    private func send(_ reply: USBIPReply) {
        let data = reply.encode()
        trace?("\(reply.command) seq=\(reply.seqnum) status=\(reply.status) payload=\(reply.payload.count) wire=\(data.count)")
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                stopped = true
                return
            }
        }
    }

    /// Reads an OUT transfer's payload, which follows the header with no
    /// length prefix of its own - `transfer_buffer_length` is the only
    /// thing that says how much there is.
    private func readPayload(for request: USBIPRequest) -> USBIPRequest? {
        var request = request
        if request.isIsochronous {
            // Isochronous needs per-packet descriptors after the payload.
            // Nothing MSL passes through uses them yet, and guessing at
            // the framing would desynchronise the stream, so refuse the
            // URB and keep the connection honest.
            logger?("isochronous URB on ep \(request.endpoint) - not supported, stalled")
        }
        guard request.direction == .out, request.transferBufferLength > 0 else { return request }
        let count = Int(request.transferBufferLength)
        var payload = [UInt8](repeating: 0, count: count)
        guard readFull(&payload, count) else { return nil }
        request.payload = Data(payload)
        return request
    }

    /// `read` on a socket returns short whenever it feels like it; every
    /// USB/IP field is fixed-width, so a short read has to be completed
    /// rather than treated as a message boundary.
    private func readFull(_ buffer: inout [UInt8], _ count: Int) -> Bool {
        var offset = 0
        return buffer.withUnsafeMutableBufferPointer { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let got = read(fd, base + offset, count - offset)
                if got > 0 { offset += got; continue }
                if got == 0 { return false }                 // guest closed
                if errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
