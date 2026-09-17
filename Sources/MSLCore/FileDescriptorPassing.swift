// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FileDescriptorPassingError: Error {
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case noDescriptorReceived
}

/// Darwin's CMSG_SPACE/CMSG_LEN/CMSG_FIRSTHDR/CMSG_DATA are function-like C
/// macros - Swift doesn't import those at all ("function like macros not
/// supported"), so they're reimplemented here directly from <sys/socket.h>'s
/// actual definitions (each aligns to 4 bytes via __DARWIN_ALIGN32).
private func darwinAlign32(_ n: Int) -> Int { (n + 3) & ~3 }

private func cmsgSpace(_ payloadLen: Int) -> Int {
    darwinAlign32(MemoryLayout<cmsghdr>.size) + darwinAlign32(payloadLen)
}

private func cmsgLen(_ payloadLen: Int) -> Int {
    darwinAlign32(MemoryLayout<cmsghdr>.size) + payloadLen
}

private func cmsgFirstHdr(_ msg: UnsafePointer<msghdr>) -> UnsafeMutablePointer<cmsghdr>? {
    guard msg.pointee.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
          let control = msg.pointee.msg_control else { return nil }
    return control.assumingMemoryBound(to: cmsghdr.self)
}

private func cmsgDataPointer(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutablePointer<UInt8> {
    UnsafeMutableRawPointer(cmsg)
        .advanced(by: darwinAlign32(MemoryLayout<cmsghdr>.size))
        .assumingMemoryBound(to: UInt8.self)
}

/// SCM_RIGHTS file-descriptor passing over a connected AF_UNIX socket.
///
/// Used by mslhd to hand a raw vsock connection fd directly to msl, so
/// interactive shell traffic flows msl <-> guest without the daemon sitting
/// in the middle copying bytes - the whole point being leanness/speed once
/// a session is established.
public enum FileDescriptorPassing {

    /// Sends an open file descriptor to the peer on the other end of
    /// `socketFD`. `tag` is a single byte of ordinary payload since some
    /// platforms require non-empty regular payload alongside ancillary data.
    public static func send(fileDescriptor fdToSend: Int32, over socketFD: Int32, tag: UInt8 = 0) throws {
        var tagByte = tag
        let fdCopy = fdToSend
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size))
        var result: Int = -1

        withUnsafeMutablePointer(to: &tagByte) { tagPtr in
            var iov = iovec(iov_base: tagPtr, iov_len: 1)
            cmsgBuffer.withUnsafeMutableBytes { rawCmsg in
                var msg = msghdr()
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = rawCmsg.baseAddress
                    msg.msg_controllen = socklen_t(rawCmsg.count)

                    if let cmsg = cmsgFirstHdr(&msg) {
                        cmsg.pointee.cmsg_level = SOL_SOCKET
                        cmsg.pointee.cmsg_type = SCM_RIGHTS
                        cmsg.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                        cmsgDataPointer(cmsg).withMemoryRebound(to: Int32.self, capacity: 1) {
                            $0.pointee = fdCopy
                        }
                    }

                    result = sendmsg(socketFD, &msg, 0)
                }
            }
        }

        if result < 0 {
            throw FileDescriptorPassingError.sendFailed(errno)
        }
    }

    /// Receives a single file descriptor sent via `send(fileDescriptor:over:)`.
    public static func receive(from socketFD: Int32) throws -> Int32 {
        var tagByte: UInt8 = 0
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgSpace(MemoryLayout<Int32>.size))
        var receivedFD: Int32 = -1
        var result: Int = -1

        withUnsafeMutablePointer(to: &tagByte) { tagPtr in
            var iov = iovec(iov_base: tagPtr, iov_len: 1)
            cmsgBuffer.withUnsafeMutableBytes { rawCmsg in
                var msg = msghdr()
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = rawCmsg.baseAddress
                    msg.msg_controllen = socklen_t(rawCmsg.count)

                    result = recvmsg(socketFD, &msg, 0)

                    if result >= 0, let cmsg = cmsgFirstHdr(&msg),
                       cmsg.pointee.cmsg_level == SOL_SOCKET,
                       cmsg.pointee.cmsg_type == SCM_RIGHTS {
                        cmsgDataPointer(cmsg).withMemoryRebound(to: Int32.self, capacity: 1) {
                            receivedFD = $0.pointee
                        }
                    }
                }
            }
        }

        if result < 0 {
            throw FileDescriptorPassingError.receiveFailed(errno)
        }
        guard receivedFD >= 0 else {
            throw FileDescriptorPassingError.noDescriptorReceived
        }
        return receivedFD
    }
}
