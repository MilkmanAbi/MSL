// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Darwin
import Foundation

/// Reads what a tunnel agent prints, without ever blocking the daemon.
///
/// Three different ways of getting this wrong were in the first version of
/// this file's callers, and all three hang `mslhd` rather than failing:
///
/// 1. **`FileHandle.availableData` blocks.** It waits for data or EOF, so a
///    deadline checked in the loop around it is never reached while the
///    agent sits there saying nothing - which is exactly what a stalled ssh
///    does. A comment claiming "the read is bounded" does not bound it. The
///    pipe is set non-blocking here so the deadline is real.
///
/// 2. **Draining before terminating** has the same shape. In the failure
///    this was written to diagnose - a server refusing to bind the
///    forwarded port - ssh stays alive and quiet, so one last read to
///    collect the error waits forever.
///
/// 3. **Nobody reading after handoff.** A pipe holds about 64KB; a
///    long-lived agent that keeps printing fills it and then blocks inside
///    `write`, wedging the tunnel while looking perfectly healthy. So once
///    the address is known, this keeps draining in the background and holds
///    on to just the tail for diagnostics.
public final class TunnelOutput: @unchecked Sendable {
    private let pipe: Pipe
    private let lock = NSLock()
    private var buffer = ""
    private var discarding = false

    public init(_ pipe: Pipe) {
        self.pipe = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Everything read so far, newest at the end.
    public var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Reads until `match` finds something, the process exits, or the
    /// deadline passes - whichever comes first. Never longer.
    public func read<T>(until deadline: Date, process: Process,
                        onLine: (@Sendable (String) -> Void)? = nil,
                        match: (String) -> T?) -> T? {
        var reported = 0
        while true {
            let chunk = readAvailable()
            if !chunk.isEmpty {
                lock.lock()
                buffer += chunk
                // Bounded: an agent that prints for an hour must not grow
                // this without limit.
                if buffer.count > 16_384 { buffer = String(buffer.suffix(8_192)) }
                let snapshot = buffer
                lock.unlock()

                if let onLine {
                    let lines = snapshot.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines.dropFirst(reported) {
                        let text = line.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty { onLine(text) }
                    }
                    reported = lines.count
                }
                if let found = match(snapshot) { return found }
            }
            // Checked after the read, not before: a process that printed
            // the answer and exited in the same instant has still answered.
            if !process.isRunning {
                let rest = readAvailable()
                if !rest.isEmpty {
                    lock.lock(); buffer += rest; let snapshot = buffer; lock.unlock()
                    if let found = match(snapshot) { return found }
                }
                return nil
            }
            if Date() >= deadline { return nil }
            // Idle rather than spinning: non-blocking reads return at once,
            // and a tight loop would burn a core waiting for a relay.
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// One non-blocking read into the buffer.
    ///
    /// For callers that are waiting on something other than the agent's
    /// output - the self-hosted backend waits for a *port* to answer - and
    /// still need the transcript if it fails. Without this, that backend's
    /// `transcript` was always empty, so the specific diagnosis it exists to
    /// give ("the server refused to listen on that port") could never fire
    /// and every failure fell through to the generic sentence.
    public func pump() {
        let chunk = readAvailable()
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer += chunk
        if buffer.count > 16_384 { buffer = String(buffer.suffix(8_192)) }
        lock.unlock()
    }

    private func readAvailable() -> String {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var text = ""
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = scratch.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                text += String(decoding: scratch[0..<count], as: UTF8.self)
                continue
            }
            // 0 is EOF; -1 with EAGAIN just means nothing right now.
            break
        }
        return text
    }

    /// Keeps the pipe empty for the rest of the tunnel's life, holding only
    /// the tail. Without this the agent eventually blocks writing to a full
    /// pipe - a wedge that looks exactly like a healthy tunnel.
    public func startDiscarding() {
        lock.lock()
        guard !discarding else { lock.unlock(); return }
        discarding = true
        lock.unlock()

        let handle = pipe.fileHandleForReading
        // The handler needs blocking semantics; non-blocking was only for
        // the deadline above.
        let flags = fcntl(handle.fileDescriptor, F_GETFL, 0)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.buffer += String(decoding: data, as: UTF8.self)
            if self.buffer.count > 8_192 { self.buffer = String(self.buffer.suffix(4_096)) }
            self.lock.unlock()
        }
    }

    public func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}
