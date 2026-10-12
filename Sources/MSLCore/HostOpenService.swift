import AppKit
import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

/// One request from the guest's `msl_open.py`: a JSON line.
public struct HostOpenRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A web or `mailto:` link.
        case url
        /// Folders to show.
        case dir
        /// Files or folders to reveal inside their parent folder.
        case show
        /// A file chooser: the app wants the person to pick something.
        /// Unlike the others this one has an *answer*, so it replies with
        /// the chosen guest paths rather than "ok".
        case pick
    }

    /// `pick` only: open, save or directory.
    public var pickMode: HostFilePickRequest.Mode = .open
    /// `pick` only: the name a Save panel starts with.
    public var suggestedName: String = ""
    /// `pick` only: whether more than one file may be chosen.
    public var allowsMultiple: Bool = false
    /// `pick` only: the app's own dialog title.
    public var title: String = ""

    public var kind: Kind
    public var targets: [String]
    /// The requesting process's working directory, for relative paths.
    public var cwd: String

    public init(kind: Kind, targets: [String], cwd: String = "/") {
        self.kind = kind
        self.targets = targets
        self.cwd = cwd
    }

    /// Requests are small; anything past this is not one.
    static let maxLineBytes = 64 * 1024

    public static func parse(_ line: Data) -> HostOpenRequest? {
        guard line.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let targets = object["targets"] as? [String],
              !targets.isEmpty, targets.count <= 64
        else { return nil }
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
        var request = HostOpenRequest(kind: kind, targets: targets, cwd: cwd)
        if kind == .pick {
            request.pickMode = (object["mode"] as? String)
                .flatMap(HostFilePickRequest.Mode.init(rawValue:)) ?? .open
            // A name, not a path: a guest that could set the panel's
            // directory through this field could walk it anywhere.
            request.suggestedName = (object["name"] as? String)
                .map { ($0 as NSString).lastPathComponent } ?? ""
            request.allowsMultiple = object["multiple"] as? Bool ?? false
            request.title = (object["title"] as? String)?.prefix(200).description ?? ""
        }
        return request
    }
}

/// A draft email built from a `mailto:` link.
public struct HostMailDraft: Equatable, Sendable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject = ""
    public var body = ""
    /// Guest paths, as `xdg-email --attach` sends them (`attach=` or
    /// `attachment=`, a `file://` URI or a plain path).
    public var attachments: [String] = []
    /// The link with the attachments taken out - what a mail app is given
    /// when the attachments cannot come with it.
    public var linkWithoutAttachments: URL?
}

/// What the Mac does with a request. Decided without touching the system,
/// so every rule here is unit-tested.
public enum HostOpenPlan: Equatable, Sendable {
    case openWebURL(URL)
    case composeMail(HostMailDraft)
    /// A guest path to show in MSL Files; `select` reveals it in its folder.
    case showInFiles(guestPath: String, select: Bool)
    /// Show the Mac's file panel and answer with what was chosen.
    case pickFiles(HostFilePickRequest)
    /// Hand the request back to Linux. The reason is only logged.
    case decline(String)

    /// `instance` is what MSLAP scopes against. It is an argument rather
    /// than read from somewhere global because this is a pure function and
    /// is tested as one; `nil` means "do not apply a policy", which is what
    /// the decision tests want.
    ///
    /// **MSLAP is checked here, not only in the settings store.** The
    /// switches that turn these integrations on are gated when they CHANGE
    /// (`MSLExperimentalSettingsStore.save`), and that is the wrong half on
    /// its own: a Mac where `openLinksOnMac` was already on would go on
    /// opening links after a policy denied `integrations.linksToMac`,
    /// because nothing ever moved the switch again. The refusal has to sit
    /// where the action happens, and this is that place for all three.
    /// `allows` is the policy check, taking a capability key. It is a
    /// parameter so this stays a pure function and the three refusals can
    /// be tested without a live policy on the machine - a test seam inside
    /// `MSLAPGate` itself would be a way to turn the real gate off, which
    /// is not a trade worth making for test convenience. The default is
    /// the real gate, and `HostOpenService` uses the default.
    public static func make(for request: HostOpenRequest, settings: MSLExperimentalSettings,
                            instance: String? = nil,
                            allows: ((String) -> Bool)? = nil) -> HostOpenPlan {
        /// Allowed when there is no instance to scope against - see above.
        func permits(_ capability: String) -> Bool {
            if let allows { return allows(capability) }
            guard let instance else { return true }
            return MSLAPGate.allows(capability, instance: instance)
        }
        switch request.kind {
        case .url:
            guard settings.openLinksOnMac else { return .decline("links open in Linux (turned off)") }
            let target = request.targets[0]
            guard target.utf8.count <= 16 * 1024,
                  let url = URL(string: target),
                  let scheme = url.scheme?.lowercased()
            else { return .decline("not a link") }
            switch scheme {
            case "http", "https":
                // A host is required: `http:foo` is not somewhere a browser
                // can go, and passing it along only produces an error page.
                guard let host = url.host, !host.isEmpty else { return .decline("link has no host") }
                guard permits("integrations.linksToMac") else {
                    return .decline("the MSL Admin Portal does not allow links to open on the Mac")
                }
                return .openWebURL(url)
            case "mailto":
                // Separable from links after all. The guest handler is one
                // `.desktop` entry claiming http, https AND mailto - which
                // is why the catalogue used to say denying one removed the
                // other - but nothing about that forces the MAC side to
                // treat them alike, and this switch is already branching
                // on the scheme. So `integrations.mailToMac` is refused on
                // its own, and a web link from the same handler still
                // opens.
                guard permits("integrations.mailToMac") else {
                    return .decline("the MSL Admin Portal does not allow mail to open on the Mac")
                }
                return mailDraft(from: target).map { .composeMail($0) } ?? .decline("malformed mailto link")
            default:
                // Deliberately a short allowlist. A guest that could make
                // the Mac open any URL could open `file:`, `x-apple.` or an
                // app's own scheme - the guest is not trusted with that.
                return .decline("\(scheme): links stay in Linux")
            }
        case .dir, .show:
            guard settings.preferMSLFiles else { return .decline("folders open in Linux (turned off)") }
            guard let path = guestPath(from: request.targets[0], cwd: request.cwd) else {
                return .decline("not a local path")
            }
            // Showing a guest folder IS browsing guest files, so it answers
            // to `sharing.files` and not to `sharing.filePicker` - the
            // picker below is the other case, and they are deliberately
            // separate capabilities even though one switch turns both on.
            guard permits("sharing.files") else {
                return .decline("the MSL Admin Portal does not allow guest files to be browsed on the Mac")
            }
            return .showInFiles(guestPath: path, select: request.kind == .show)
        case .pick:
            // The same switch as folders: the person asked for one setting
            // covering "MSL Files handles this", and a file chooser is the
            // other half of it. Declining sends the app back to its own
            // Linux dialog, which is what the toggle promises.
            guard settings.preferMSLFiles else { return .decline("file dialogs stay in Linux (turned off)") }
            guard permits("sharing.filePicker") else {
                return .decline("the MSL Admin Portal does not allow MSL Files to be the file picker")
            }
            let start = guestPath(from: request.targets[0], cwd: request.cwd) ?? "/"
            return .pickFiles(HostFilePickRequest(mode: request.pickMode,
                                                  startGuestPath: start,
                                                  suggestedName: request.suggestedName,
                                                  allowsMultiple: request.allowsMultiple,
                                                  title: request.title))
        }
    }

    /// A guest filesystem path from a `file://` URI or a path, relative
    /// ones resolved against `cwd`, with `.` and `..` removed. `nil` for
    /// any other URI scheme - `sftp://` and friends are not in the guest's
    /// filesystem, so MSL Files cannot show them.
    public static func guestPath(from target: String, cwd: String) -> String? {
        var raw = target
        if let schemeEnd = target.range(of: "://") {
            guard target[..<schemeEnd.lowerBound].lowercased() == "file",
                  let url = URL(string: target), url.host == nil || url.host == "" || url.host == "localhost"
            else { return nil }
            raw = url.path
        } else if target.contains("\0") {
            return nil
        }
        guard !raw.isEmpty else { return nil }
        let absolute = raw.hasPrefix("/") ? raw : cwd + "/" + raw
        var parts: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func mailDraft(from link: String) -> HostMailDraft? {
        guard var components = URLComponents(string: link), components.scheme?.lowercased() == "mailto" else {
            return nil
        }
        var draft = HostMailDraft()
        func addresses(_ value: String) -> [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        draft.to = addresses(components.path)
        var kept: [URLQueryItem] = []
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "attach", "attachment":
                if !value.isEmpty { draft.attachments.append(value) }
                continue
            case "to": draft.to += addresses(value)
            case "cc": draft.cc += addresses(value)
            case "bcc": draft.bcc += addresses(value)
            case "subject": draft.subject = value
            case "body": draft.body = value
            default: break
            }
            kept.append(item)
        }
        components.queryItems = kept.isEmpty ? nil : kept
        draft.linkWithoutAttachments = components.url
        return draft
    }
}

/// Listens on the guest's vsock for `msl_open.py` and carries out
/// `HostOpenPlan`s: links to the Mac's browser, mail to its mail app,
/// folders to MSL Files.
///
/// Started whenever the VM is running (`VMManager.resumeAfterVMUp`), not
/// only while a GUI app is, because a request can arrive from any app MSL
/// launched. Settings are read per request, so the Experimental Features
/// toggles take effect without relaunching anything.
///
/// A sandboxed instance is always declined: any closed MSL Sandbox gate
/// means the guest is not meant to reach out of its box, and making the
/// Mac open things for it would be a way out.
public final class HostOpenService: NSObject {
    private let socketDevice: VZVirtioSocketDevice
    private let instance: String
    private let mountPath: () -> String?
    private let readGuestFile: (String, Int) throws -> Data
    private var listener: VZVirtioSocketListener?

    private let rateLock = NSLock()
    private var recent: [Date] = []
    static let rateLimit = 10
    static let rateWindow: TimeInterval = 10

    static let maxAttachments = 10
    static let maxAttachmentBytes = 50 * 1024 * 1024

    /// `readGuestFile(path, maxBytes)` is the fallback for attachments when
    /// the guest isn't mounted on the Mac.
    public init(socketDevice: VZVirtioSocketDevice, instance: String,
                mountPath: @escaping () -> String?,
                readGuestFile: @escaping (String, Int) throws -> Data) {
        self.socketDevice = socketDevice
        self.instance = instance
        self.mountPath = mountPath
        self.readGuestFile = readGuestFile
        super.init()
    }

    public func start() {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: GuestIntegration.hostOpenPort)
        self.listener = listener
    }

    /// See `DisplayBridge.stop()` - the framework has no way to unregister.
    public func stop() {
        listener?.delegate = nil
        listener = nil
    }

    private func underRateLimit() -> Bool {
        rateLock.lock()
        defer { rateLock.unlock() }
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) > Self.rateWindow }
        guard recent.count < Self.rateLimit else { return false }
        recent.append(now)
        return true
    }

    private func handle(fd: Int32) {
        guard let line = Self.readLine(fd: fd), let request = HostOpenRequest.parse(line) else {
            Self.reply(fd: fd, "declined")
            return
        }
        let handled: Bool
        let plan = HostOpenPlan.make(for: request, settings: MSLExperimentalSettingsStore.load(),
                                     instance: instance)
        if case .decline(let reason) = plan {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: reason)
            handled = false
        } else if !SandboxPolicyStore.load(instance: instance).isOpen {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: "instance is sandboxed")
            handled = false
        } else if !underRateLimit() {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: "too many requests")
            handled = false
        } else if case .pickFiles(let pick) = plan {
            // The one request with an answer, and the one MSL cannot serve
            // on its own: `mslhd` has no windows, so **MSL Files** shows the
            // picker (see `READMES/24-FILE-PICKER.md`). The request is parked
            // under a token, MSL Files is opened on it, and this thread waits
            // for the answer to come back over the daemon socket.
            let instance = self.instance
            let token = PendingFilePicks.shared.register(pick, instance: instance)
            // **Never block main to launch it.** `NSWorkspace.open(_:)` is
            // synchronous and can take seconds, and this process's main
            // thread also serves the X11 bridge - holding it there froze
            // every Linux app and their hosts exited with "Exiting due to
            // channel error" (measured 2026-09-29, Firefox died on Save As).
            // The asynchronous form hands off and returns immediately;
            // whether MSL Files actually arrived is answered by the claim
            // deadline below, which is a better signal anyway.
            // **Nothing here may touch main synchronously.** This process's
            // main thread also serves the X11 bridge, so a slow call on it
            // freezes every Linux app and their hosts exit with "Exiting due
            // to channel error" - measured twice on 2026-09-29, first with
            // `NSWorkspace.open(_:)` and again with
            // `urlForApplication(toOpen:)`. Both are LaunchServices calls
            // and both can take seconds.
            //
            // So: no "is it installed?" probe either. Ask it to open and let
            // the claim deadline answer that question - if MSL Files is not
            // there, nothing claims the pick and it declines, which is the
            // same outcome for a fraction of the risk.
            guard let url = MSLFilesIdentity.pickURL(token: token) else {
                // MSL Files is not installed. Its own Linux dialog is a far
                // better answer than nothing.
                PendingFilePicks.shared.complete(token: token, outcome: .unavailable)
                _ = PendingFilePicks.shared.wait(token: token)
                Self.reply(fd: fd, "declined")
                return
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            }
            switch PendingFilePicks.shared.wait(token: token) {
            case .picked(let paths):
                ActivityLog.shared.record(.display, instance: instance,
                                          "Chose \(paths.count) file(s) on the Mac", detail: paths.first ?? "")
                Self.reply(fd: fd, Self.pickReply(paths))
            case .cancelled:
                // A decision, not a failure: answering "declined" here would
                // make the app open its own dialog immediately afterwards,
                // which reads as the dialog refusing to close.
                ActivityLog.shared.record(.display, instance: instance, "File dialog cancelled", detail: "")
                Self.reply(fd: fd, Self.pickReply([]))
            case .unavailable:
                ActivityLog.shared.record(.display, instance: instance, "Left to Linux",
                                          detail: "MSL Files did not answer")
                Self.reply(fd: fd, "declined")
            }
            return
        } else {
            handled = perform(plan)
        }
        Self.reply(fd: fd, handled ? "ok" : "declined")
    }

    private func perform(_ plan: HostOpenPlan) -> Bool {
        switch plan {
        case .decline:
            return false
        case .openWebURL(let url):
            ActivityLog.shared.record(.display, instance: instance, "Opened a link on the Mac", detail: url.host ?? "")
            return onMain { NSWorkspace.shared.open(url) }
        case .showInFiles(let guestPath, let select):
            guard mountPath() != nil else { return false }
            let instance = self.instance
            return onMain {
                // MSL Files' own scheme first - it's a separate app now, and
                // going straight to it avoids launching MSL just to forward.
                // Then `msl://`, for an install that predates the split. With
                // neither registered (never launched on this Mac), the Linux
                // file manager is better than nothing.
                for scheme in [MSLFilesIdentity.urlScheme, MSLFilesIdentity.legacyScheme] {
                    guard let url = MSLFilesIdentity.revealURL(scheme: scheme, instance: instance,
                                                               guestPath: guestPath, select: select),
                          NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { continue }
                    ActivityLog.shared.record(.display, instance: instance, "Showed a folder in MSL Files", detail: guestPath)
                    return NSWorkspace.shared.open(url)
                }
                return false
            }
        case .composeMail(let draft):
            return compose(draft)
        case .pickFiles:
            // Answered in `handle`, which can reply with the chosen paths -
            // this returns only "did something happen".
            return false
        }
    }

    /// A pick's answer: one JSON line, so the guest can tell "cancelled"
    /// (an empty list) from "declined" (the plain word, meaning fall back to
    /// the Linux dialog). Those must not be confused: cancelling is a
    /// decision the person made, and re-showing a Linux dialog after it
    /// would be the app ignoring them.
    static func pickReply(_ guestPaths: [String]) -> String {
        let object: [String: Any] = ["result": "picked", "paths": guestPaths]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "declined" }
        return text
    }

    private func compose(_ draft: HostMailDraft) -> Bool {
        let files = draft.attachments.prefix(Self.maxAttachments).compactMap { copyAttachment($0) }
        ActivityLog.shared.record(.display, instance: instance, "Wrote an email on the Mac",
                                  detail: files.isEmpty ? "" : "\(files.count) attachment(s)")
        return onMain {
            // The compose service is Apple Mail's. With another default mail
            // app (a browser registered for mailto:, Outlook) it accepts the
            // items and nothing appears - seen live with Edge as the
            // default. Those get the link, and the files beside it.
            let mailApp = draft.linkWithoutAttachments.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            let defaultIsAppleMail = mailApp.flatMap { Bundle(url: $0)?.bundleIdentifier } == "com.apple.mail"
            if !files.isEmpty, defaultIsAppleMail, let service = NSSharingService(named: .composeEmail) {
                service.recipients = draft.to
                service.subject = draft.subject
                var items: [Any] = draft.body.isEmpty ? [] : [draft.body]
                items += files
                if service.canPerform(withItems: items) {
                    service.perform(withItems: items)
                    return true
                }
            }
            guard let link = draft.linkWithoutAttachments else { return false }
            let opened = NSWorkspace.shared.open(link)
            // The mail app got the message but not the files; show them so
            // they can be dragged in.
            if opened, !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
            return opened
        }
    }

    /// Copies one attachment out of the guest into
    /// `~/Library/Caches/MSL/Mail Attachments/<uuid>/`, keeping its name.
    private func copyAttachment(_ target: String) -> URL? {
        guard let guestPath = HostOpenPlan.guestPath(from: target, cwd: "/"), guestPath != "/" else { return nil }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MSL/Mail Attachments/\(UUID().uuidString)", isDirectory: true)
        let name = (guestPath as NSString).lastPathComponent
        let destination = directory.appendingPathComponent(name.isEmpty ? "attachment" : name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let mount = mountPath() {
                let source = URL(fileURLWithPath: mount + guestPath)
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxAttachmentBytes else { return nil }
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try readGuestFile(guestPath, Self.maxAttachmentBytes).write(to: destination)
            }
            return destination
        } catch {
            ActivityLog.shared.record(.display, instance: instance, "Couldn't attach a file", detail: "\(guestPath): \(error)")
            return nil
        }
    }

    private func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func readLine(fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < HostOpenRequest.maxLineBytes {
            let n = read(fd, &byte, 1)
            guard n == 1 else { return data.isEmpty ? nil : data }
            if byte == UInt8(ascii: "\n") { return data }
            data.append(byte)
        }
        return nil
    }

    private static func reply(fd: Int32, _ text: String) {
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

extension HostOpenService: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // Never block in the delegate callback - see `DisplayBridge`.
        Thread { [weak self] in
            withExtendedLifetime(connection) {
                self?.handle(fd: connection.fileDescriptor)
            }
        }.start()
        return true
    }
}
