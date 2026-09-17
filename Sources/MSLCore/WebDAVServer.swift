import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal WebDAV server (raw POSIX sockets, hand-rolled HTTP/1.1) exposing
/// one guest instance's filesystem - via `FileOpsClient`/`fileopsd` over
/// vsock - as a WebDAV share on 127.0.0.1. `VMManager`'s owner mounts this
/// with `mount_webdav` so Finder can browse straight into the guest - the
/// "Linux -> Finder" half of the MSL Sandbox (the other half, `mac_home`
/// via virtiofs, needed none of this - see README's "MSL Sandbox" section).
///
/// Deliberately not FSKit/a kext, per the original design call: this is
/// exactly enough WebDAV surface for macOS's own `mount_webdav` client -
/// PROPFIND (depth 0/1), GET, HEAD, PUT, MKCOL, DELETE, MOVE, LOCK, UNLOCK,
/// OPTIONS. No chunked request bodies (`Transfer-Encoding: chunked`) -
/// `mount_webdav`'s PUT always sends a `Content-Length`, confirmed against
/// real requests during development.
///
/// LOCK/UNLOCK are real methods here, unlike the rest of the spec's "no
/// locking required" - confirmed live (`man mount_webdav`, then reproduced):
/// a server that never advertises the LOCK method is treated as WebDAV
/// Class 1, and `mount_webdav` silently forces the entire mount `rdonly`
/// rather than ever attempting a write. Advertising Class 2 (`DAV: 1,2`)
/// and answering LOCK/UNLOCK is required just to get write access at all -
/// nothing here actually arbitrates concurrent locks (there's exactly one
/// local mount, one Finder, no other writer to conflict with), so LOCK
/// always grants a fresh token and UNLOCK always succeeds. If this ever
/// needs to serve more than one concurrent client, this is the first thing
/// that would need real tracking.
public final class WebDAVServer {
    private let fileOpsClient: FileOpsClient
    private let guestRoot: String
    private let bindAddress: String

    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private var shouldStop = false

    /// `guestRoot` is the guest-absolute path this server's `/` maps to.
    /// `VMManager` always passes `/` (the whole guest filesystem, matching
    /// real WSL's `\\wsl$\<Distro>\` share - see its own doc comment on
    /// `startFileSandbox`); kept as a parameter rather than hardcoded since
    /// nothing else here assumes a specific root, and it's genuinely useful
    /// for testing against a narrower subtree.
    ///
    /// `bindAddress` defaults to the canonical loopback address, which is
    /// also what `VMManager` always passes - unlike Linux, macOS's `lo0`
    /// doesn't treat the rest of `127.0.0.0/8` as usable without an
    /// explicit, root-requiring `ifconfig lo0 alias` first (confirmed via a
    /// live `EADDRNOTAVAIL` when a derived-per-instance address was tried
    /// here instead - see `VMManager.webdavLoopbackAddress`'s doc comment).
    /// Parameterized anyway rather than hardcoded, since nothing else here
    /// assumes a specific address.
    /// Which instance this bridge serves. Only used to file traffic-monitor
    /// events under the right instance - the bridge itself never needs it.
    private let instanceName: String?

    public init(fileOpsClient: FileOpsClient, guestRoot: String = "/", bindAddress: String = "127.0.0.1",
                instanceName: String? = nil) {
        self.instanceName = instanceName
        self.fileOpsClient = fileOpsClient
        self.guestRoot = guestRoot
        self.bindAddress = bindAddress
    }

    /// Binds `bindAddress` on an ephemeral port, starts accepting
    /// connections on a background thread (one further thread per accepted
    /// connection - this is a local loopback server handling a handful of
    /// concurrent Finder/`mount_webdav` requests, not internet-facing, so a
    /// thread-per-connection model is simple and plenty), and returns the
    /// bound port.
    public func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WebDAVServerError.socketFailed(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral - the caller reads back the real port below
        addr.sin_addr.s_addr = inet_addr(bindAddress)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { close(fd); throw WebDAVServerError.bindFailed(errno) }
        guard listen(fd, 16) == 0 else { close(fd); throw WebDAVServerError.listenFailed(errno) }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLen) }
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.msl.webdav.accept"
        thread.start()
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Closes the listen socket - the accept loop notices on its next
    /// `accept()` call and exits. Already-open connection threads finish
    /// their in-flight request and close normally (each connection is
    /// handled synchronously start-to-finish, so there's nothing to cancel
    /// mid-flight).
    ///
    /// `shutdown` before `close`: on Darwin, closing a socket that another
    /// thread is blocked in `accept()` on does not wake that thread, and the
    /// blocked call keeps the socket listening. A "stopped" server went on
    /// accepting and serving - and its requests started VMs - until
    /// something connected (found 2026-09-14, when one booted an
    /// unregistered Arch VM long after the instance was removed).
    public func stop() {
        stateLock.lock()
        shouldStop = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            let stop = shouldStop
            stateLock.unlock()
            if stop || fd < 0 { return }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 { continue }
            // A connection that raced `stop()` is refused, not served.
            stateLock.lock()
            let stoppedMeanwhile = shouldStop
            stateLock.unlock()
            if stoppedMeanwhile {
                close(clientFD)
                return
            }
            let thread = Thread { [weak self] in self?.handle(clientFD: clientFD) }
            thread.start()
        }
    }

    // MARK: - Connection handling

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        guard let request = HTTPMessage.readRequest(fd: clientFD) else { return }
        let response = respond(to: request)
        response.write(fd: clientFD)
    }

    private static let allowedMethods = "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL, MOVE, LOCK, UNLOCK"

    private func respond(to request: HTTPMessage) -> HTTPResponse {
        let guestPath = resolveGuestPath(request.path)
        // Method + path is the useful granularity. Logging per chunk would
        // turn one large copy into thousands of identical rows - the same
        // shape of mistake as the X11 snapshot dumper that reached 38 GB.
        ActivityLog.shared.record(.file, instance: instanceName,
                                  "\(request.method) \(guestPath)")
        switch request.method {
        case "OPTIONS":
            return HTTPResponse(status: 200, statusText: "OK", headers: [
                "DAV": "1,2",
                "Allow": Self.allowedMethods,
                "MS-Author-Via": "DAV",
            ])
        case "PROPFIND":
            return handlePropfind(request: request, guestPath: guestPath)
        case "GET":
            return handleGet(guestPath: guestPath, includeBody: true)
        case "HEAD":
            return handleGet(guestPath: guestPath, includeBody: false)
        case "PUT":
            return handlePut(guestPath: guestPath, body: request.body)
        case "MKCOL":
            return handleMkcol(guestPath: guestPath)
        case "DELETE":
            return handleDelete(guestPath: guestPath)
        case "MOVE":
            return handleMove(request: request, guestPath: guestPath)
        case "LOCK":
            return handleLock()
        case "UNLOCK":
            return HTTPResponse(status: 204, statusText: "No Content")
        default:
            return HTTPResponse(status: 405, statusText: "Method Not Allowed", headers: ["Allow": Self.allowedMethods])
        }
    }

    /// Always grants a fresh token - see the type doc comment on why no
    /// real lock tracking exists here.
    private func handleLock() -> HTTPResponse {
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
          <D:lockdiscovery>
            <D:activelock>
              <D:locktype><D:write/></D:locktype>
              <D:lockscope><D:exclusive/></D:lockscope>
              <D:depth>0</D:depth>
              <D:timeout>Second-600</D:timeout>
              <D:locktoken><D:href>\(token)</D:href></D:locktoken>
            </D:activelock>
          </D:lockdiscovery>
        </D:prop>
        """
        return HTTPResponse(status: 200, statusText: "OK", headers: [
            "Content-Type": "application/xml; charset=\"utf-8\"",
            "Lock-Token": "<\(token)>",
        ], body: Data(xml.utf8))
    }

    /// Maps a WebDAV request path (always relative to this server's own
    /// root, e.g. `/foo/bar.txt`) onto an absolute guest path under
    /// `guestRoot`. Response `href`s echo the *request* path back unchanged
    /// (see `handlePropfind`) - `guestRoot` never leaks into anything the
    /// client sees, it's purely a server-side base.
    private func resolveGuestPath(_ requestPath: String) -> String {
        var relative = Substring(requestPath)
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        if relative.isEmpty { return guestRoot }
        // guestRoot == "/" is now the default (see VMManager.
        // startFileSandbox) - avoid "//foo" from the naive join below.
        // Harmless on Linux in practice (a leading "//" collapses to "/"),
        // but not worth relying on when avoiding it is one line.
        if guestRoot == "/" { return "/" + relative }
        return guestRoot + "/" + relative
    }

    // MARK: - PROPFIND

    private func handlePropfind(request: HTTPMessage, guestPath: String) -> HTTPResponse {
        let depth = request.headers["depth"] ?? "1"
        let statResult = sync({ try await self.fileOpsClient.stat(guestPath) })
        guard case .success(let entry) = statResult else {
            return errorResponse(statResult)
        }

        let selfHref = request.path.isEmpty ? "/" : request.path
        let selfName = (guestPath as NSString).lastPathComponent
        var body = [xmlPropfindEntry(href: selfHref, name: selfName, entry: entry)]

        if entry.isDirectory && depth != "0" {
            // A failed listing is an *error*, not an empty directory.
            //
            // This used to be `if case .success`, so any failure fell
            // through and produced a 207 with only the directory itself in
            // it - which Finder renders as an empty folder. A folder full of
            // files showing as empty, with no error anywhere, is the worst
            // outcome available here: it looks like data loss. Matches the
            // `stat` guard above, which already got this right.
            let listResult = sync({ try await self.fileOpsClient.list(guestPath) })
            guard case .success(let children) = listResult else {
                return errorResponse(listResult)
            }
            let base = selfHref.hasSuffix("/") ? selfHref : selfHref + "/"
            for child in children {
                let href = base + (percentEncodePathSegment(child.name))
                body.append(xmlPropfindEntry(href: href, name: child.name, entry: child))
            }
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(body.joined(separator: "\n"))
        </D:multistatus>
        """
        return HTTPResponse(status: 207, statusText: "Multi-Status", headers: ["Content-Type": "application/xml; charset=\"utf-8\""], body: Data(xml.utf8))
    }

    private func xmlPropfindEntry(href: String, name: String, entry: FileOpsProtocol.Entry) -> String {
        let displayName = xmlEscape(name)
        let lastModified = Self.rfc1123Formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime)))
        let resourceType = entry.isDirectory ? "<D:collection/>" : ""
        let contentLength = entry.isDirectory ? "" : "<D:getcontentlength>\(entry.size)</D:getcontentlength>"
        return """
          <D:response>
            <D:href>\(xmlEscape(href))</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>\(displayName)</D:displayname>
                <D:resourcetype>\(resourceType)</D:resourcetype>
                \(contentLength)
                <D:getlastmodified>\(lastModified)</D:getlastmodified>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        """
    }

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    // MARK: - GET / HEAD

    /// Fixed-size chunked reads rather than one `fileOpsClient.read` call
    /// for the whole file - `fileopsd`'s frame size is capped at 16MiB
    /// (`MAX_FRAME` in `fileopsd.c`), so anything larger than that needs
    /// multiple requests regardless. `handle_read`'s `pread` loop returns
    /// however much was actually available at EOF (see its doc comment),
    /// which is what `chunk.isEmpty` below relies on to stop.
    private func handleGet(guestPath: String, includeBody: Bool) -> HTTPResponse {
        let statResult = sync({ try await self.fileOpsClient.stat(guestPath) })
        guard case .success(let entry) = statResult else { return errorResponse(statResult) }
        if entry.isDirectory {
            return HTTPResponse(status: 200, statusText: "OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data())
        }
        guard includeBody else {
            return HTTPResponse(status: 200, statusText: "OK", headers: ["Content-Type": "application/octet-stream", "Content-Length": "\(entry.size)"])
        }

        var data = Data()
        data.reserveCapacity(Int(entry.size))
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 4 * 1024 * 1024
        while offset < entry.size {
            let toRead = UInt32(min(UInt64(chunkSize), entry.size - offset))
            let readResult = sync({ try await self.fileOpsClient.read(guestPath, offset: offset, length: toRead) })
            guard case .success(let chunk) = readResult else { return errorResponse(readResult) }
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += UInt64(chunk.count)
        }
        return HTTPResponse(status: 200, statusText: "OK", headers: ["Content-Type": "application/octet-stream"], body: data)
    }

    // MARK: - PUT

    /// How a PUT body gets onto the guest.
    ///
    /// Not a free choice between the two - each is wrong where the other is
    /// right, which is why this is a decision and not a policy:
    ///
    /// - `inPlace` writes straight to the destination. Offset 0 truncates
    ///   (per the wire protocol), every subsequent chunk doesn't, so a
    ///   multi-chunk write lands as one contiguous file rather than N
    ///   separate truncating writes. It *preserves an existing file's
    ///   permissions*, because `fileopsd` opens with `O_CREAT` and the mode
    ///   argument only applies when the file is actually created.
    /// - `viaTemporary` writes a sibling temp file and renames it over the
    ///   destination, so a failure part-way through leaves the destination
    ///   untouched. But `rename` replaces the inode, and `fileopsd` has no
    ///   CHMOD opcode, so it *loses the destination's permissions*.
    ///
    /// See `putStrategy` for which one applies when.
    enum PutStrategy: Equatable {
        case inPlace
        case viaTemporary(tempPath: String)
    }

    /// Whether the destination already exists, as far as a STAT could tell.
    enum PutDestination: Equatable {
        case absent
        case present
    }

    /// Picks a strategy. Pure, and the only place the trade-off is decided.
    ///
    /// The rule is "temp-and-rename only when there are no permissions to
    /// lose", which lands on exactly one case: a **new** file whose body
    /// needs more than one write.
    ///
    /// - A body that fits in one chunk is already effectively atomic -
    ///   `fileopsd` reads the whole frame before it writes anything, so a
    ///   transfer that dies mid-flight never becomes a partial file. Nothing
    ///   to fix, and in-place keeps the mode.
    /// - Overwriting an existing file stays in place *on purpose*. Temp and
    ///   rename would drop that file's mode on every single save - a script
    ///   silently losing `+x` each time you edit it is a far worse bug than
    ///   a rare mid-transfer failure that at least reports itself. Restoring
    ///   the mode needs a CHMOD opcode in `fileopsd`; it's written up in
    ///   IMAGE-REBUILD-SG.md, and until an image ships with it this branch
    ///   is the correct one.
    /// - Creating a new large file is the case worth fixing: there is no
    ///   mode to preserve, and the failure it prevents is the indefensible
    ///   one - a half-written file sitting under its final name looking
    ///   exactly like a copy that succeeded.
    static func putStrategy(bodyCount: Int,
                            chunkSize: Int,
                            destination: PutDestination,
                            tempPath: @autoclosure () -> String) -> PutStrategy {
        guard bodyCount > chunkSize else { return .inPlace }
        guard destination == .absent else { return .inPlace }
        return .viaTemporary(tempPath: tempPath())
    }

    /// A sibling of the destination, because `rename(2)` cannot cross
    /// filesystems and the guest's `/tmp` may well be a different one.
    ///
    /// Dot-prefixed so a temp that outlives a crash stays out of the way,
    /// and named from a UUID rather than from the destination so the name is
    /// both collision-free across concurrent PUTs and a fixed 29 bytes -
    /// appending to a long basename could push it past `NAME_MAX`.
    static func temporaryPutPath(for guestPath: String, uuid: String) -> String {
        let directory = guestPath.hasSuffix("/")
            ? String(guestPath.dropLast())
            : guestPath
        let parent = directory.lastIndex(of: "/").map { String(directory[directory.startIndex..<$0]) } ?? ""
        return "\(parent)/.msl-put-\(uuid).tmp"
    }

    /// Whether it's worth trying to delete the temp file after a failure.
    ///
    /// Only when the failure came *from the guest* - an errno means the
    /// connection is alive and the temp really is sitting there. A timeout
    /// or a closed connection means the transport is gone, so the unlink
    /// cannot succeed either; attempting it would just burn another full
    /// `operationTimeout` before Finder gets told anything.
    static func shouldCleanUpTemporary(after error: Error) -> Bool {
        if case FileOpsProtocol.FileOpsError.remote = error { return true }
        return false
    }

    private func handlePut(guestPath: String, body: Data) -> HTTPResponse {
        let chunkSize = 4 * 1024 * 1024

        if body.isEmpty {
            let result = sync({ try await self.fileOpsClient.write(guestPath, offset: 0, data: Data()) })
            if case .failure = result { return errorResponse(result) }
            return HTTPResponse(status: 201, statusText: "Created")
        }

        // Only ask about the destination when the answer can change the
        // outcome - a single-chunk body is written in place either way, and
        // a STAT per small save is a round trip for nothing.
        var destination: PutDestination = .present
        if body.count > chunkSize {
            let statResult = sync({ try await self.fileOpsClient.stat(guestPath) })
            switch statResult {
            case .success:
                destination = .present
            case .failure(let error):
                // Only ENOENT means "nothing there to protect". Any other
                // failure - EACCES, a timeout - is not a green light for
                // either path, so report it rather than guessing.
                //
                // (`fileopsd`'s STAT follows symlinks, so a *dangling*
                // symlink reads as absent and gets replaced by a regular
                // file rather than written through. Rare enough, and
                // visible, unlike the failure this branch exists for.)
                guard case FileOpsProtocol.FileOpsError.remote(let code) = error, code == ENOENT else {
                    return errorResponse(statResult)
                }
                destination = .absent
            }
        }

        let strategy = Self.putStrategy(bodyCount: body.count,
                                        chunkSize: chunkSize,
                                        destination: destination,
                                        tempPath: Self.temporaryPutPath(for: guestPath,
                                                                        uuid: UUID().uuidString))

        switch strategy {
        case .inPlace:
            if let failure = writeChunks(body, to: guestPath, chunkSize: chunkSize) {
                return errorResponse(failure)
            }
        case .viaTemporary(let tempPath):
            if let failure = writeChunks(body, to: tempPath, chunkSize: chunkSize) {
                cleanUpTemporary(tempPath, after: failure)
                return errorResponse(failure)
            }
            let renameResult = sync({ try await self.fileOpsClient.rename(tempPath, to: guestPath) })
            if case .failure = renameResult {
                cleanUpTemporary(tempPath, after: renameResult)
                return errorResponse(renameResult)
            }
        }
        return HTTPResponse(status: 201, statusText: "Created")
    }

    /// Writes the whole body to `path`, returning the failing result (for
    /// `errorResponse`) or nil on success.
    private func writeChunks(_ body: Data, to path: String, chunkSize: Int) -> Result<Void, Error>? {
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunkSize, body.count)
            let chunk = body.subdata(in: offset..<end)
            let result = sync({ try await self.fileOpsClient.write(path, offset: UInt64(offset), data: chunk) })
            if case .failure = result { return result }
            offset = end
        }
        return nil
    }

    /// Best-effort - a leftover temp is untidy, but it is hidden, and there
    /// is nothing useful to tell Finder about a failed cleanup that it isn't
    /// already being told about the failure that caused it.
    private func cleanUpTemporary<T>(_ tempPath: String, after failure: Result<T, Error>) {
        guard case .failure(let error) = failure, Self.shouldCleanUpTemporary(after: error) else { return }
        _ = sync({ try await self.fileOpsClient.unlink(tempPath) })
    }

    // MARK: - MKCOL / DELETE / MOVE

    private func handleMkcol(guestPath: String) -> HTTPResponse {
        let result = sync({ try await self.fileOpsClient.mkdir(guestPath) })
        if case .failure = result { return errorResponse(result) }
        return HTTPResponse(status: 201, statusText: "Created")
    }

    /// `fileopsd`'s UNLINK dispatches to `rmdir`/`unlink` on the guest side
    /// depending on what the path actually is - a directory delete only
    /// succeeds there if it's already empty (no recursive delete). Good
    /// enough for the MVP acceptance bar (single-file/empty-dir operations
    /// from Finder); a non-empty directory delete surfaces as a normal
    /// Finder error (409, mapped from `ENOTEMPTY` below) rather than
    /// silently doing something unexpected.
    private func handleDelete(guestPath: String) -> HTTPResponse {
        let result = sync({ try await self.fileOpsClient.unlink(guestPath) })
        if case .failure = result { return errorResponse(result) }
        return HTTPResponse(status: 204, statusText: "No Content")
    }

    private func handleMove(request: HTTPMessage, guestPath: String) -> HTTPResponse {
        guard let destinationHeader = request.headers["destination"] else {
            return HTTPResponse(status: 400, statusText: "Bad Request")
        }
        let destGuestPath = resolveGuestPath(destinationRequestPath(from: destinationHeader))
        let result = sync({ try await self.fileOpsClient.rename(guestPath, to: destGuestPath) })
        if case .failure = result { return errorResponse(result) }
        return HTTPResponse(status: 204, statusText: "No Content")
    }

    /// `Destination` is a full URL (`http://127.0.0.1:PORT/path...`), not a
    /// bare path - only same-server MOVEs are possible here (there's only
    /// one server), so just the path component is needed.
    private func destinationRequestPath(from header: String) -> String {
        if let url = URL(string: header) {
            return url.path.removingPercentEncoding ?? url.path
        }
        return header.removingPercentEncoding ?? header
    }

    // MARK: - Errors

    private func errorResponse<T>(_ result: Result<T, Error>) -> HTTPResponse {
        guard case .failure(let error) = result else { return HTTPResponse(status: 500, statusText: "Internal Server Error") }
        if case FileOpsProtocol.FileOpsError.remote(let code) = error {
            switch code {
            case ENOENT: return HTTPResponse(status: 404, statusText: "Not Found")
            case EACCES, EPERM: return HTTPResponse(status: 403, statusText: "Forbidden")
            case EEXIST: return HTTPResponse(status: 405, statusText: "Method Not Allowed")
            case ENOTEMPTY: return HTTPResponse(status: 409, statusText: "Conflict")
            default: return HTTPResponse(status: 500, statusText: "Internal Server Error")
            }
        }
        // A timeout is specifically "the thing behind me didn't answer",
        // which is what 504 means - and Finder reports it more usefully
        // than a blanket 500.
        if case WebDAVServerError.timedOut = error {
            return HTTPResponse(status: 504, statusText: "Gateway Timeout")
        }
        return HTTPResponse(status: 500, statusText: "Internal Server Error")
    }

    /// Bridges an async `FileOpsClient` call onto the plain OS thread
    /// `handle(clientFD:)` runs on (started via `Thread {}`, one per
    /// connection - see `acceptLoop`). Safe to block here specifically
    /// because this thread is NOT the Swift concurrency cooperative pool
    /// and NOT `VMManager`'s own `vmQueue` - it's an ordinary thread with
    /// nothing else waiting on it, so blocking on a semaphore while the
    /// `Task` runs to completion elsewhere cannot deadlock. Contrast with
    /// the documented gotcha in `VMManager`/`HANDOFF.md`: blocking *inside*
    /// a `VZVirtioSocketListenerDelegate` callback hangs the process,
    /// because that callback fires on a queue the framework itself needs
    /// pumped - this thread has no such obligation to anything.
    /// How long any single guest operation may take before this gives up.
    ///
    /// Bounded on purpose. `semaphore.wait()` with no deadline blocks this
    /// connection thread forever if the guest never answers - a VM part-way
    /// through resuming, a wedged `fileopsd`, a vsock that went away - and
    /// what the user sees is Finder beachballing on a folder with no way
    /// out but force-quitting it. Failing after 30s gives Finder a real
    /// error it can show and recover from.
    ///
    /// Generous rather than tight: `ensureRunning()` inside `FileOpsClient`
    /// may legitimately be *booting a virtual machine* on the first access
    /// after an auto-suspend, which is seconds, not milliseconds.
    private static let operationTimeout: DispatchTimeInterval = .seconds(30)

    private func sync<T>(_ operation: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        // Written by the Task, read here only after the semaphore is
        // signalled (or never, on timeout) - the lock keeps that honest
        // now that a timeout means both sides can touch it.
        let lock = NSLock()
        var result: Result<T, Error> = .failure(WebDAVServerError.internalBridgeFailure)
        Task {
            let outcome: Result<T, Error>
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            lock.lock(); result = outcome; lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.operationTimeout) == .success else {
            // The Task is left running - it cannot be cancelled from here
            // and abandoning it is safe: it writes under the lock and
            // signals a semaphore nothing is waiting on any more.
            return .failure(WebDAVServerError.timedOut)
        }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func percentEncodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

public enum WebDAVServerError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case internalBridgeFailure
    case timedOut

    public var description: String {
        switch self {
        case .socketFailed(let e): return "socket() failed (errno \(e))"
        case .bindFailed(let e): return "bind() failed (errno \(e))"
        case .listenFailed(let e): return "listen() failed (errno \(e))"
        case .internalBridgeFailure: return "internal async bridge failure"
        case .timedOut: return "the guest didn't answer in time"
        }
    }
}

// MARK: - HTTP/1.1 wire types

/// A parsed HTTP request. Header keys are lowercased at parse time so
/// lookups (`headers["depth"]`, `headers["destination"]`) don't need to
/// worry about client casing.
struct HTTPMessage {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Reads exactly one request off `fd`: headers first (buffered until
    /// the blank-line terminator is seen), then exactly `Content-Length`
    /// body bytes if present. No `Transfer-Encoding: chunked` support - see
    /// `WebDAVServer`'s doc comment.
    static func readRequest(fd: Int32) -> HTTPMessage? {
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 16384)
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            let n = readBuf.withUnsafeMutableBytes { ptr in Darwin.read(fd, ptr.baseAddress, ptr.count) }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: readBuf[0..<n])
            headerEnd = buffer.range(of: terminator)
            if buffer.count > 1 << 20 { return nil } // pathological header block - bail
        }
        guard let end = headerEnd else { return nil }

        guard let headerText = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let rawPath = String(requestLine[1])
        let path = rawPath.removingPercentEncoding ?? rawPath

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = Data(buffer[end.upperBound...])
        if let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText), contentLength > body.count {
            while body.count < contentLength {
                let want = min(readBuf.count, contentLength - body.count)
                let n = readBuf.withUnsafeMutableBytes { ptr in Darwin.read(fd, ptr.baseAddress, want) }
                guard n > 0 else { break }
                body.append(contentsOf: readBuf[0..<n])
            }
        }

        return HTTPMessage(method: method, path: path, headers: headers, body: body)
    }
}

struct HTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String] = [:]
    var body: Data = Data()

    func write(fd: Int32) {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        allHeaders["Connection"] = "close"
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        data.withUnsafeBytes { ptr in
            var sent = 0
            let base = ptr.baseAddress!
            while sent < ptr.count {
                let n = Darwin.write(fd, base + sent, ptr.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
