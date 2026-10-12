// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Darwin
import Foundation

/// Forwards a port on this Mac to a port in a guest.
///
/// Written rather than shelled out to because there is nothing on a stock
/// macOS that does it: `tailscale serve --tcp` only targets localhost,
/// `socat` is not installed, and `ssh -L` would need an SSH session to the
/// Mac itself. It is about a hundred lines of plain sockets, and it is the
/// only moving part of the Tailscale backend.
public final class PortForwarder: @unchecked Sendable {
    public let listenPort: UInt16
    public let targetHost: String
    public let targetPort: UInt16

    /// Which of the Mac's addresses to listen on.
    ///
    /// Tailscale's backend needs every interface, because the point there
    /// is to be reachable over the tailnet. `msl forward` needs loopback
    /// only: it is a convenience for the person at this Mac, and binding it
    /// everywhere would silently put a guest's development server on the
    /// café wifi. So the caller says, and the default keeps the original
    /// behaviour for the backend that was here first.
    public enum Reachability: Sendable {
        case everyInterface
        case thisMacOnly

        var address: in_addr_t {
            switch self {
            case .everyInterface: return INADDR_ANY
            case .thisMacOnly: return 0x7f00_0001 // 127.0.0.1
            }
        }
    }
    public let reachability: Reachability

    /// Looked up per connection rather than kept, because a guest's DHCP
    /// address can move while the forward is up - it changes across a
    /// reboot of the instance, and `targetHost` would then point at
    /// nothing, or worse at whichever instance took the lease.
    private let resolveHost: (@Sendable () -> String?)?

    private var listenerFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    /// Said out loud when a connection cannot be completed. A forward that
    /// accepts and then resets looks identical to a firewall from the
    /// outside, and the reason is only ever visible here.
    private let log: @Sendable (String) -> Void

    public init(listenPort: UInt16, targetHost: String, targetPort: UInt16,
                reachability: Reachability = .everyInterface,
                resolveHost: (@Sendable () -> String?)? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.reachability = reachability
        self.resolveHost = resolveHost
        self.log = log
    }

    /// Where a connection should go right now.
    private var currentTargetHost: String {
        resolveHost?() ?? targetHost
    }

    public enum ForwardError: Error, CustomStringConvertible {
        case cannotListen(Int32)
        public var description: String {
            switch self {
            case .cannotListen(let code):
                return code == EADDRINUSE ? "that port is already in use"
                                          : "the port could not be opened (errno \(code))"
            }
        }
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ForwardError.cannotListen(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Without this, writing to a peer that has gone kills the whole
        // daemon with SIGPIPE rather than failing one copy loop.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listenPort.bigEndian
        // See `Reachability`. Every interface for Tailscale (its own
        // network is the boundary, and what is behind the port is key-only
        // SSH either way); loopback for `msl forward`.
        address.sin_addr.s_addr = reachability.address.bigEndian

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ForwardError.cannotListen(code)
        }
        lock.lock(); listenerFD = fd; running = true; lock.unlock()

        Thread { [weak self] in self?.acceptLoop(fd) }.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock(); let alive = running; lock.unlock()
            guard alive else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                // A closed listener ends the loop; a transient error does
                // not - ECONNABORTED here would otherwise stop forwarding
                // for good after one odd connection.
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            Thread { [weak self] in self?.handle(client) }.start()
        }
    }

    private func handle(_ client: Int32) {
        guard let upstream = connectToTarget() else {
            // **EHOSTUNREACH here is almost always macOS, not the network.**
            // Local Network privacy denies a process the local subnet by
            // returning "no route to host" rather than a permission error,
            // which sends you looking at routing and firewalls for an hour.
            // Proved by the other half of the evidence: `nc` from a shell
            // reached the same guest at the same moment, so the route exists
            // and this process specifically was refused.
            //
            // The relay backend never hits this because `ssh` does its own
            // connecting; this is the first place mslhd itself opens a
            // connection to the guest's LAN address.
            let code = errno
            if code == EHOSTUNREACH || code == EPERM || code == EACCES {
                log("macOS is blocking MSL from reaching \(currentTargetHost) on the local network. "
                    + "Open System Settings > Privacy & Security > Local Network, turn MSL on, "
                    + "then publish again.")
            } else {
                log("accepted a connection but couldn't reach \(currentTargetHost):\(targetPort) "
                    + "(errno \(code)) - the guest may have stopped")
            }
            close(client)
            return
        }
        // One thread each way, and whichever direction ends first closes
        // both - a half-open forward leaks a socket per connection.
        let done = DispatchSemaphore(value: 0)
        Thread { Self.copy(from: client, to: upstream); done.signal() }.start()
        Self.copy(from: upstream, to: client)
        shutdown(client, SHUT_RDWR)
        shutdown(upstream, SHUT_RDWR)
        _ = done.wait(timeout: .now() + 5)
        close(client)
        close(upstream)
    }

    private func connectToTarget() -> Int32? {
        let host = currentTargetHost
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(targetPort), &hints, &info) == 0,
              let resolved = info else { return nil }
        defer { freeaddrinfo(info) }
        let fd = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype,
                        resolved.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let sent = buffer.withUnsafeBytes {
                    write(destination, $0.baseAddress!.advanced(by: written), count - written)
                }
                guard sent > 0 else { return }
                written += sent
            }
        }
    }

    /// Whether this process can open a connection to the guest at all.
    ///
    /// Separate from the forwarding path so the answer can be given when
    /// publishing rather than when somebody's first `ssh` is reset.
    public static func canReach(host: String, port: UInt16, timeout: TimeInterval = 4) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info
        else { return false }
        defer { freeaddrinfo(info) }
        let fd = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype,
                        resolved.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    deinit { stop() }
}
