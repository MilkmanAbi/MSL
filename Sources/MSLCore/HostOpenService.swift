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
    }

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
        return HostOpenRequest(kind: kind, targets: targets, cwd: cwd)
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
    /// Hand the request back to Linux. The reason is only logged.
    case decline(String)

    public static func make(for request: HostOpenRequest, settings: MSLExperimentalSettings) -> HostOpenPlan {
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
                return .openWebURL(url)
            case "mailto":
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
            return .showInFiles(guestPath: path, select: request.kind == .show)
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
        let plan = HostOpenPlan.make(for: request, settings: MSLExperimentalSettingsStore.load())
        if case .decline(let reason) = plan {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: reason)
            handled = false
        } else if !SandboxPolicyStore.load(instance: instance).isOpen {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: "instance is sandboxed")
            handled = false
        } else if !underRateLimit() {
            ActivityLog.shared.record(.display, instance: instance, "Left to Linux", detail: "too many requests")
            handled = false
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
            var components = URLComponents()
            components.scheme = "msl"
            components.host = "files"
            components.queryItems = [
                URLQueryItem(name: "instance", value: instance),
                URLQueryItem(name: "path", value: guestPath),
            ] + (select ? [URLQueryItem(name: "select", value: "1")] : [])
            guard let url = components.url else { return false }
            return onMain {
                // No MSL.app registered for msl:// (never launched on this
                // Mac): the Linux file manager is better than nothing.
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
                ActivityLog.shared.record(.display, instance: self.instance, "Showed a folder in MSL Files", detail: guestPath)
                return NSWorkspace.shared.open(url)
            }
        case .composeMail(let draft):
            return compose(draft)
        }
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

    private func onMain(_ work: @escaping () -> Bool) -> Bool {
        if Thread.isMainThread { return work() }
        var result = false
        DispatchQueue.main.sync { result = work() }
        return result
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
