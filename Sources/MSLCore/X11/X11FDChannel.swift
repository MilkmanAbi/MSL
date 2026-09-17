import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Hands a live socket from `mslhd` to a per-app host process, together
/// with the bytes `X11AppSniffer` already read off it.
///
/// A file descriptor is per-process, so "route this X11 client to the Krita
/// process" cannot be done by passing a number - the kernel has to install
/// the descriptor in the target process, which is what `SCM_RIGHTS` over a
/// unix-domain socket is for. `mslhd` keeps owning the vsock device (it is
/// the only thing Virtualization.framework hands out a handle for); it just
/// stops being the thing that *interprets* each connection.
///
/// One message per handoff: the replay prefix as a length-prefixed payload,
/// with the descriptor attached as ancillary data on the same `sendmsg`.
enum X11FDChannel {
    /// Darwin's `CMSG_ALIGN` - 4-byte alignment (`__DARWIN_ALIGN32`), not
    /// the pointer-sized alignment some platforms use. The `CMSG_*` macros
    /// are C macros and so are not visible to Swift at all; getting this
    /// wrong produces a control message the kernel silently ignores, i.e. a
    /// handoff where the descriptor just never arrives.
    private static func cmsgAlign(_ n: Int) -> Int { (n + 3) & ~3 }
    private static var cmsgHeaderSize: Int { cmsgAlign(MemoryLayout<cmsghdr>.size) }
    private static func cmsgSpace(_ n: Int) -> Int { cmsgHeaderSize + cmsgAlign(n) }
    private static func cmsgLen(_ n: Int) -> Int { cmsgHeaderSize + n }

    // MARK: - Sending (mslhd side)

    /// Connects to `socketPath` and hands `fd` over with `payload`.
    /// Returns `false` if nothing is listening there - the caller's cue to
    /// start the host process and try again.
    static func send(fd: Int32, payload: [UInt8], toSocketPath socketPath: String) -> Bool {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        // Length first so the receiver knows how much prefix to expect;
        // big-endian because this is a wire format, however local.
        var header = [UInt8]()
        let count = UInt32(payload.count)
        header.append(UInt8((count >> 24) & 0xFF))
        header.append(UInt8((count >> 16) & 0xFF))
        header.append(UInt8((count >> 8) & 0xFF))
        header.append(UInt8(count & 0xFF))

        var descriptor = fd
        var control = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size))
        var iovecBuffer = header
        var sent = false
        iovecBuffer.withUnsafeMutableBufferPointer { iovBuf in
            control.withUnsafeMutableBufferPointer { ctlBuf in
                var iov = iovec(iov_base: iovBuf.baseAddress, iov_len: iovBuf.count)
                var msg = msghdr()
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress)
                msg.msg_controllen = socklen_t(ctlBuf.count)
                let cmsg = ctlBuf.baseAddress!.withMemoryRebound(to: cmsghdr.self, capacity: 1) { $0 }
                cmsg.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                let dataPtr = UnsafeMutableRawPointer(ctlBuf.baseAddress!).advanced(by: cmsgHeaderSize)
                dataPtr.copyMemory(from: &descriptor, byteCount: MemoryLayout<Int32>.size)
                sent = sendmsg(sock, &msg, 0) == iovBuf.count
            }
        }
        guard sent else { return false }
        return writeAll(sock, payload)
    }

    // MARK: - Receiving (per-app host side)

    /// Creates (replacing any stale one) and listens on `socketPath`.
    static func listen(atSocketPath socketPath: String) -> Int32? {
        unlink(socketPath)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(sock); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(sock, 16) == 0 else { close(sock); return nil }
        return sock
    }

    /// Blocks until one handoff arrives. Returns the installed descriptor
    /// and the replay prefix that came with it.
    static func accept(on listeningFD: Int32) -> (fd: Int32, payload: [UInt8])? {
        let client = Darwin.accept(listeningFD, nil, nil)
        guard client >= 0 else { return nil }
        defer { close(client) } // the CONTROL channel; the passed descriptor outlives it

        var headerBuffer = [UInt8](repeating: 0, count: 4)
        var control = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size))
        var received: Int32 = -1
        var byteCount = 0

        headerBuffer.withUnsafeMutableBufferPointer { iovBuf in
            control.withUnsafeMutableBufferPointer { ctlBuf in
                var iov = iovec(iov_base: iovBuf.baseAddress, iov_len: iovBuf.count)
                var msg = msghdr()
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress)
                msg.msg_controllen = socklen_t(ctlBuf.count)
                byteCount = recvmsg(client, &msg, 0)
                guard byteCount == 4, msg.msg_controllen >= socklen_t(cmsgLen(MemoryLayout<Int32>.size)) else { return }
                let cmsg = ctlBuf.baseAddress!.withMemoryRebound(to: cmsghdr.self, capacity: 1) { $0 }
                guard cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS else { return }
                let dataPtr = UnsafeRawPointer(ctlBuf.baseAddress!).advanced(by: cmsgHeaderSize)
                received = dataPtr.load(as: Int32.self)
            }
        }
        guard received >= 0 else { return nil }

        let payloadCount = Int(UInt32(headerBuffer[0]) << 24 | UInt32(headerBuffer[1]) << 16
            | UInt32(headerBuffer[2]) << 8 | UInt32(headerBuffer[3]))
        var payload = [UInt8]()
        if payloadCount > 0 {
            payload = [UInt8](repeating: 0, count: payloadCount)
            var got = 0
            let ok = payload.withUnsafeMutableBytes { ptr -> Bool in
                let base = ptr.baseAddress!
                while got < payloadCount {
                    let n = read(client, base + got, payloadCount - got)
                    if n <= 0 { return false }
                    got += n
                }
                return true
            }
            guard ok else { close(received); return nil }
        }
        return (received, payload)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        var sent = 0
        return bytes.withUnsafeBytes { ptr -> Bool in
            let base = ptr.baseAddress!
            while sent < bytes.count {
                let n = write(fd, base + sent, bytes.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
