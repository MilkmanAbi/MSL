// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

/// Drives a headless guest boot over its serial console from the host side -
/// the core mechanism `bootstrap-guest` and `extract-guest-modules` both use
/// to script a live Alpine environment (install packages, format disks,
/// extract kernel modules) with no human typing into a VZVirtualMachineView
/// and no Docker/OrbStack dependency.
///
/// Wraps a `VZVirtioConsoleDeviceSerialPortConfiguration` attachment's pair
/// of pipes: `hostWriter` sends guest input, `hostReader`'s bytes accumulate
/// into a transcript that `waitFor`/`waitForAny` poll.
public final class SerialConsoleSession {
    public let attachment: VZSerialPortAttachment

    private let hostToGuest = Pipe()
    private let guestToHost = Pipe()
    private let hostWriter: FileHandle
    private let hostReader: FileHandle

    private var transcript = ""
    private let transcriptLock = NSLock()

    /// Set true to also print each transcript chunk to stderr as it arrives
    /// - useful for watching a run live, noisy for unattended use.
    public var echoToStderr = true

    public init() {
        hostWriter = hostToGuest.fileHandleForWriting
        hostReader = guestToHost.fileHandleForReading
        // VZFileHandleSerialPortAttachment: bytes written to hostToGuest's
        // write end are delivered to the guest console; bytes the guest
        // writes to its console are delivered to guestToHost's write end.
        attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuest.fileHandleForReading,
            fileHandleForWriting: guestToHost.fileHandleForWriting
        )

        hostReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            self.transcriptLock.lock()
            self.transcript += chunk
            self.transcriptLock.unlock()
            if self.echoToStderr {
                FileHandle.standardError.write(data)
            }
        }
    }

    public func sendLine(_ line: String) {
        hostWriter.write((line + "\n").data(using: .utf8)!)
    }

    public enum SessionError: Error, CustomStringConvertible {
        case timedOut(String)
        case stepFailed(String)
        public var description: String {
            switch self {
            case .timedOut(let what): return "timed out waiting for: \(what)"
            case .stepFailed(let what): return what
            }
        }
    }

    /// Whether `needle` has appeared on the guest's console so far.
    ///
    /// Public because a boot failure is often only explicable from the
    /// console: a guest whose kernel panics leaves the VM "running" as far
    /// as Virtualization.framework is concerned, so the console transcript
    /// is the only place the real reason exists.
    public func consoleContains(_ needle: String) -> Bool {
        transcriptContains(needle)
    }

    /// Everything the guest has written to the console so far.
    ///
    /// For callers that wait on a schedule of their own. `waitForAny` polls
    /// by spinning `RunLoop.current`, which returns immediately on a thread
    /// with no run-loop sources - so from a detached task it would busy-loop
    /// a whole core for its entire timeout.
    public func transcriptSnapshot() -> String {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return transcript
    }

    private func transcriptContains(_ needle: String) -> Bool {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return transcript.contains(needle)
    }

    /// Polls the transcript for `marker`, checking every 500ms.
    public func waitFor(_ marker: String, timeout: TimeInterval) throws {
        _ = try waitForAny([marker], timeout: timeout)
    }

    /// Like `waitFor`, but returns whichever of several markers shows up
    /// first - needed where the next input depends on which prompt appears
    /// (e.g. a login sequence that may or may not ask for a password).
    public func waitForAny(_ markers: [String], timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for marker in markers where transcriptContains(marker) { return marker }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        }
        throw SessionError.timedOut(markers.joined(separator: " | "))
    }

    /// Finds `marker`'s LAST occurrence in the transcript and parses the
    /// exit code echoed right after it (see `runStep`'s `exit=$?` suffix).
    /// Searching from the end matters: the command line we send is itself
    /// echoed back by the guest's tty before it executes, and that echoed
    /// line also contains the marker text - followed by the literal,
    /// unsubstituted "exit=$?". Searching forward matches that first and
    /// parses garbage; the real output line is always the last occurrence
    /// at the point this is called.
    public func exitCode(afterMarker marker: String) -> Int? {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        guard let markerRange = transcript.range(of: marker, options: .backwards) else { return nil }
        let after = transcript[markerRange.upperBound...]
        guard let exitRange = after.range(of: "exit=") else { return nil }
        let digits = after[exitRange.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Sends `command`, waits for it to finish (via a unique echoed marker),
    /// and verifies its exit code was 0. Never trust an echoed marker alone
    /// without checking the exit code - a first pass at this that only
    /// waited for an unconditional echo let a failed `mount` slip through
    /// silently, with the following command landing in the wrong place.
    public func runStep(_ command: String, marker: String, timeout: TimeInterval = 300) throws {
        sendLine(command)
        sendLine("echo \(marker) exit=$?")

        // Deliberately not waitFor(marker) followed by a single
        // exitCode(afterMarker:) check - for a command that completes
        // near-instantly (insmod, mkdir, ...), the *echo of the command
        // line itself* (which the guest's tty reflects back before
        // executing it, containing the same marker text followed by the
        // literal, unsubstituted "exit=$?") can satisfy a marker-presence
        // check before the real output ("MARKER exit=0") has arrived,
        // racing exitCode's backwards-search into parsing the unsubstituted
        // literal and returning nil - confirmed on a real run, intermittent
        // (masked whenever the real output happens to land first). Keep
        // polling until a real digit sequence parses, not just until the
        // marker text shows up somewhere.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let code = exitCode(afterMarker: marker) {
                guard code == 0 else {
                    throw SessionError.stepFailed("step failed (exit \(code)): \(command)")
                }
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        throw SessionError.timedOut(marker)
    }

    /// Logs into Alpine's live netboot environment. It lands on an
    /// interactive getty, not an auto-login shell ("localhost login: "),
    /// confirmed on first real boot. A naive "# " prompt marker is a bad
    /// idea: apk's progress bar renders lines like "# 24% ######### " during
    /// the boot-time repo fetch, which matches "# " within the first few
    /// seconds, long before any real shell exists - also confirmed on first
    /// real boot (it caused a command to get typed as the login username).
    /// Waits for the literal "login:" prompt instead - Alpine's live
    /// root/OpenRC startup prints other "login"-adjacent lines ("Creating
    /// user login records ... [ ok ]") but none contain "login:" except the
    /// real prompt. The live media root account has no password, but a
    /// getty may still show a "Password:" prompt before accepting an empty
    /// one - handles whichever happens.
    public func loginAsRoot(shellPrompt: String = ":~#", timeout: TimeInterval = 120) throws {
        try waitFor("login:", timeout: timeout)
        Thread.sleep(forTimeInterval: 0.5)
        sendLine("root")

        let afterLogin = try waitForAny(["Password:", shellPrompt], timeout: 20)
        if afterLogin == "Password:" {
            sendLine("")
            try waitFor(shellPrompt, timeout: 20)
        }
        Thread.sleep(forTimeInterval: 1) // let the shell's own startup output flush
    }
}
