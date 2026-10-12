import AppKit
import Foundation

/// Copy and paste between Linux apps and the Mac.
///
/// **Why this has to exist at all.** X11 selections are peer to peer: no
/// data lives in the server, only which window owns a selection atom, and
/// the owner is asked for the bytes on demand. That works inside one
/// `X11State` - and since MSL gives every Linux app its own host process
/// (see `X11AppRouter`), every app is its own `X11State`. Two Linux apps
/// literally cannot see each other's selections. `NSPasteboard` is the
/// broker that fixes that, and bridging through it buys copy and paste with
/// real Mac apps at the same time.
///
/// **Both directions, and what each one costs.**
/// - *Guest copies*: when a client claims `CLIPBOARD`, this asks it for the
///   text immediately and puts it on `NSPasteboard`. Eager rather than lazy:
///   a lazy `NSPasteboard` provider would have to block the Mac's main
///   thread on a round trip to a Linux app that may be busy or gone.
/// - *Mac copies*: a poll on `NSPasteboard.changeCount` (there is no change
///   notification in AppKit; every clipboard manager on macOS polls). When
///   it moves, this host claims `CLIPBOARD` on the Mac's behalf and answers
///   conversion requests itself.
///
/// **`CLIPBOARD` only, deliberately.** `PRIMARY` - X11's select-with-the-
/// mouse, paste-with-middle-click selection - changes on every drag through
/// text. Mirroring it onto the Mac's single pasteboard would overwrite
/// whatever someone had copied, constantly, just because a Linux app's text
/// got selected. `xterm` and old Motif apps copy through `PRIMARY` alone
/// and are not covered by this; that is the known cost.
final class X11Clipboard {
    /// A window the server owns, used as the requestor when MSL asks a
    /// client for its selection. Safe by construction: client resource IDs
    /// are `clientIndex << 21` with `clientIndex >= 1`, so everything below
    /// `0x0020_0000` belongs to nobody.
    static let requestorWindowID: UInt32 = 0x0000_0100
    /// The window MSL claims selections with, standing in for the Mac.
    static let macOwnerWindowID: UInt32 = 0x0000_0101
    /// Long enough that a client re-asserting ownership (GTK does this on
    /// focus changes) doesn't start a new round trip each time, short
    /// enough that a real second copy is never missed.
    static let reclaimDebounce: TimeInterval = 0.2
    /// A client that never answers must not wedge the bridge forever.
    static let conversionTimeout: TimeInterval = 2.0
    private static let pollInterval: TimeInterval = 0.5

    private let lock = NSLock()
    /// Injectable so tests never touch the real pasteboard: a test that
    /// clobbers whatever the person running it had copied is a test that
    /// gets deleted.
    private let pasteboard: NSPasteboard
    private weak var state: X11State?
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = 0
    /// What the Mac holds, when the Mac is the owner. `nil` means a Linux
    /// client owns the clipboard and MSL should stay out of the way.
    private var macPayload: MacPayload?
    private var pending: Pending?

    /// What the Mac's clipboard holds, in the forms a Linux app can ask for.
    ///
    /// More than one at a time on purpose: a copy is often text *and* a
    /// picture of that text, and a Linux app should get whichever it asks
    /// for rather than whichever MSL guessed at.
    struct MacPayload: Equatable {
        var text: String?
        /// PNG bytes. PNG rather than TIFF because `image/png` is the target
        /// every Linux toolkit offers and understands; TIFF is what
        /// `NSPasteboard` hands out and almost nothing on Linux reads.
        var png: [UInt8]?
        /// Files, as paths **the guest can open**. Already translated, and
        /// anything the guest cannot reach has already been dropped.
        var files: [String] = []

        init(text: String? = nil, png: [UInt8]? = nil, files: [String] = []) {
            self.text = text
            self.png = png
            self.files = files
        }

        var isEmpty: Bool { text == nil && png == nil && files.isEmpty }
    }

    struct Pending {
        let owner: UInt32
        var target: UInt32
        var started: Date
        var triedFallback: Bool
        /// Targets still to ask this owner for, after the current one.
        ///
        /// A selection can be converted to one target per request, so
        /// collecting both the text and the image of a copy takes two round
        /// trips. They queue here and the answers accumulate in `collected`,
        /// which is published once the queue drains.
        var wanted: [UInt32] = []
        var collected = MacPayload()
        /// True while waiting for the `TARGETS` list rather than a value.
        var askingTargets = false
        /// Set once the owner has answered with `INCR`, meaning the value
        /// is too large for one property and arrives in chunks.
        var incrActive = false
        /// Chunks so far. Bounded by `maxIncrBytes`.
        var incrBytes: [UInt8] = []
        /// The type the CHUNKS carry, which is the real target - the INCR
        /// property's own type is just `INCR`.
        var incrType: UInt32 = 0
    }

    /// What the caller must do after handing over a property.
    ///
    /// The bridge cannot do this itself: deleting the property and telling
    /// the owner are X11 operations on a connection, and `X11Clipboard`
    /// deliberately owns no connection.
    enum ConversionOutcome: Equatable {
        /// Nothing further. The value (if any) has been published.
        case done
        /// Ask the same owner for another target. Either the `TARGETS` list
        /// just came back and this is the first thing worth asking for, or a
        /// value arrived and the copy has more parts to collect.
        case askAgain(target: UInt32)
        /// An INCR transfer is in progress. Delete the property and send
        /// the owner a `PropertyNotify(Delete)` - that is the signal it
        /// waits for before writing the next chunk, so without it the
        /// transfer stalls after the first one.
        ///
        /// `next` is a target still to ask for once the series has ended,
        /// so a large text copy that also carries an image does not lose the
        /// image. Both things are owed to the owner and the acknowledgement
        /// cannot simply be replaced by the next request.
        case needsIncrAck(next: UInt32?)
    }

    /// A ceiling on an INCR transfer, so a client cannot make this process
    /// grow without bound one chunk at a time. 32 MB is far past any
    /// plausible clipboard text and far short of a problem.
    static let maxIncrBytes = 32 * 1024 * 1024

    /// Whether the bridge does anything at all.
    ///
    /// Read once, when the host's server state is built, so a host behaves
    /// consistently for its whole life - the same rule the other
    /// experiments follow ("applies to apps opened after turning it on").
    /// Turned off, nothing here claims a selection, answers a conversion or
    /// polls the pasteboard, and a Linux app's clipboard stays entirely its
    /// own.
    private let enabled: Bool

    init(pasteboard: NSPasteboard = .general,
         enabled: Bool = MSLExperimentalSettingsStore.load().guestClipboard) {
        self.pasteboard = pasteboard
        self.enabled = enabled
    }

    func attach(to state: X11State) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    // MARK: - Atoms
    //
    // Interned lazily against the host's own table, because atom values are
    // per-server and this server's are handed out at runtime.

    func clipboardAtom() -> UInt32 { state?.internAtom("CLIPBOARD", onlyIfExists: false) ?? 0 }
    func utf8Atom() -> UInt32 { state?.internAtom("UTF8_STRING", onlyIfExists: false) ?? 0 }
    func targetsAtom() -> UInt32 { state?.internAtom("TARGETS", onlyIfExists: false) ?? 0 }
    func timestampAtom() -> UInt32 { state?.internAtom("TIMESTAMP", onlyIfExists: false) ?? 0 }
    func textAtom() -> UInt32 { state?.internAtom("TEXT", onlyIfExists: false) ?? 0 }
    func imagePNGAtom() -> UInt32 { state?.internAtom("image/png", onlyIfExists: false) ?? 0 }
    /// The two ways a Linux desktop says "these files are on the clipboard".
    /// `text/uri-list` is the freedesktop standard; GNOME's file manager and
    /// everything that copied it read `x-special/gnome-copied-files`, whose
    /// value is the word `copy` or `cut`, a newline, then the URIs.
    func uriListAtom() -> UInt32 { state?.internAtom("text/uri-list", onlyIfExists: false) ?? 0 }
    func gnomeCopiedAtom() -> UInt32 {
        state?.internAtom("x-special/gnome-copied-files", onlyIfExists: false) ?? 0
    }
    /// Predefined atom 4, the type a `TARGETS` reply carries.
    static let atomAtom: UInt32 = 4
    /// Predefined atom 31, Latin-1 text. Every toolkit still offers it.
    static let stringAtom: UInt32 = 31
    /// Where a client is asked to put the answer.
    func propertyAtom() -> UInt32 { state?.internAtom("MSL_CLIPBOARD", onlyIfExists: false) ?? 0 }
    func incrAtom() -> UInt32 { state?.internAtom("INCR", onlyIfExists: false) ?? 0 }

    // MARK: - Guest copies, Mac pastes

    /// Whether a fresh `SetSelectionOwner(CLIPBOARD)` is worth a round trip,
    /// and with which target.
    ///
    /// Returns `nil` when the claim is MSL's own (that would be a loop), or
    /// when the same owner re-claimed moments ago - GTK re-asserts ownership
    /// on focus changes, and every one of those would otherwise cost a
    /// request storm.
    func targetForGuestClaim(owner: UInt32, now: Date = Date()) -> UInt32? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard owner != Self.macOwnerWindowID, owner != 0 else { return nil }
        if let pending, pending.owner == owner, now.timeIntervalSince(pending.started) < Self.reclaimDebounce {
            return nil
        }
        // A Linux client owns it now, so whatever the Mac had is stale.
        macPayload = nil
        // **Ask what it has before asking for it.** Going straight for
        // UTF8_STRING was fine while text was all this bridged, but it
        // cannot find an image, and asking for `image/png` speculatively
        // would make every plain-text copy pay for a refusal. `TARGETS` is
        // the ICCCM way to find out, and it costs one round trip that the
        // debounce above already keeps rare.
        let target = state?.internAtom("TARGETS", onlyIfExists: false) ?? 0
        pending = Pending(owner: owner, target: target, started: now, triedFallback: false)
        pending?.askingTargets = true
        return target
    }

    /// What to ask for, given what the owner says it can produce.
    ///
    /// Text first so that a copy which is both text and a picture of text
    /// keeps its text, and the image is collected after it. Anything the
    /// owner did not offer is not asked for.
    func wantedTargets(fromOffered offered: [UInt32]) -> [UInt32] {
        let utf8 = utf8Atom(), png = imagePNGAtom()
        var wanted: [UInt32] = []
        if offered.contains(utf8) { wanted.append(utf8) }
        else if offered.contains(Self.stringAtom) { wanted.append(Self.stringAtom) }
        if offered.contains(png) { wanted.append(png) }
        return wanted
    }

    /// The answer arrived as a property on MSL's requestor window.
    ///
    /// Three cases, and the middle one is why this returns an outcome
    /// rather than just the text:
    ///
    /// - An ordinary value: decode, publish, done.
    /// - **`INCR`**: the value is too large for a single property, so
    ///   ICCCM says the owner answers with type `INCR`, format 32, holding
    ///   a lower bound on the size, and then sends the data in chunks. The
    ///   old `guard format == 8` in `decode` rejected that handshake
    ///   outright, `pending` had already been cleared, and nothing
    ///   retried - so **a large copy out of a Linux app silently did
    ///   nothing**. GTK uses INCR for any sizeable text.
    /// - A chunk of an INCR transfer in progress: accumulate. A
    ///   zero-length chunk is the end marker.
    @discardableResult
    func receivedConversion(type: UInt32, format: UInt8, data: [UInt8]) -> ConversionOutcome {
        guard enabled else { return .done }

        // The `TARGETS` list, which is a menu rather than a value: it says
        // what this owner can produce, and the answer decides what to ask
        // for next.
        lock.lock()
        if pending?.askingTargets == true, type == Self.atomAtom, format == 32 {
            let offered = Self.atomList(data)
            var wanted = wantedTargets(fromOffered: offered)
            pending?.askingTargets = false
            guard !wanted.isEmpty else {
                // An owner that offers nothing MSL can use. Fall back to
                // plain text rather than giving up: some clients answer
                // UTF8_STRING perfectly well without listing it.
                pending?.target = utf8Atom()
                let target = utf8Atom()
                lock.unlock()
                return .askAgain(target: target)
            }
            let first = wanted.removeFirst()
            pending?.wanted = wanted
            pending?.target = first
            lock.unlock()
            return .askAgain(target: first)
        }
        lock.unlock()

        lock.lock()
        let incrStart = type == incrAtom() && format == 32
        if incrStart, pending != nil {
            pending?.incrActive = true
            pending?.incrBytes = []
            pending?.incrType = 0
            lock.unlock()
            return .needsIncrAck(next: nil)
        }
        if pending?.incrActive == true {
            if data.isEmpty {
                // End of the series. Decode what accumulated, with the
                // type the CHUNKS carried rather than `INCR`.
                let bytes = pending?.incrBytes ?? []
                let chunkType = pending?.incrType ?? type
                pending?.incrActive = false
                pending?.incrBytes = []
                lock.unlock()
                return .needsIncrAck(next: store(type: chunkType, bytes: bytes))
            }
            if pending?.incrType == 0 { pending?.incrType = type }
            let total = (pending?.incrBytes.count ?? 0) + data.count
            if total > Self.maxIncrBytes {
                pending = nil // refuse rather than grow without bound
                lock.unlock()
                return .needsIncrAck(next: nil)
            }
            pending?.incrBytes.append(contentsOf: data)
            lock.unlock()
            return .needsIncrAck(next: nil)
        }
        lock.unlock()

        // `pending` is cleared AFTER the decode, not before. Clearing it
        // first made the two failure modes asymmetric for no reason: a
        // client that *refused* a target got retried with `STRING` via
        // `fallbackTarget`, while a client that answered with bytes we
        // could not read was treated as final - and `fallbackTarget`
        // opens with `guard var current = pending`, so there was nothing
        // left for it to retry with.
        guard format == 8, !data.isEmpty else { return .done }
        if let next = store(type: type, bytes: data) { return .askAgain(target: next) }
        return .done
    }

    /// Files one converted value away and says what to ask for next.
    ///
    /// Returns the next target when the copy has more parts to collect, and
    /// `nil` once it is complete - at which point the whole payload goes to
    /// the Mac's pasteboard in one write, so an app pasting it sees the text
    /// and the image together rather than whichever arrived last.
    private func store(type: UInt32, bytes: [UInt8]) -> UInt32? {
        lock.lock()
        guard pending != nil else { lock.unlock(); return nil }
        if type == imagePNGAtom() {
            pending?.collected.png = bytes
        } else if let text = Self.decode(type: type, format: 8, data: bytes, utf8Atom: utf8Atom()) {
            pending?.collected.text = text
        }
        if let next = pending?.wanted.first {
            pending?.wanted.removeFirst()
            pending?.target = next
            pending?.started = Date()
            lock.unlock()
            return next
        }
        let payload = pending?.collected ?? MacPayload()
        pending = nil
        lock.unlock()
        if !payload.isEmpty { publishToMac(payload) }
        return nil
    }

    /// A `TARGETS` reply is a list of 32-bit atoms.
    static func atomList(_ data: [UInt8]) -> [UInt32] {
        stride(from: 0, to: data.count - 3, by: 4).map {
            UInt32(data[$0]) | UInt32(data[$0 + 1]) << 8
                | UInt32(data[$0 + 2]) << 16 | UInt32(data[$0 + 3]) << 24
        }
    }

    /// Bytes to text, by the target the client answered with.
    static func decode(type: UInt32, format: UInt8, data: [UInt8], utf8Atom: UInt32) -> String? {
        guard format == 8, !data.isEmpty else { return nil }
        if type == utf8Atom { return String(bytes: data, encoding: .utf8) }
        if type == stringAtom { return String(bytes: data, encoding: .isoLatin1) }
        // An unknown target that is still plausibly text (TEXT,
        // COMPOUND_TEXT): try UTF-8, then Latin-1, which between them cover
        // everything the toolkits actually send.
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1)
    }

    /// The owner said it cannot convert to that target. Returns the next
    /// target worth asking for, or `nil` to give up.
    ///
    /// Without this the bridge would hang on a failed conversion: a refusal
    /// arrives as a `SelectionNotify` with no property and no `ChangeProperty`
    /// at all, so there is nothing else to notice it by.
    func fallbackTarget(now: Date = Date()) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        guard var current = pending, !current.triedFallback else {
            pending = nil
            return nil
        }
        current.triedFallback = true
        current.target = Self.stringAtom
        current.started = now
        pending = current
        return Self.stringAtom
    }

    /// Drops a conversion nobody ever answered.
    func expirePending(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if let pending, now.timeIntervalSince(pending.started) > Self.conversionTimeout {
            self.pending = nil
        }
    }

    /// Which client MSL is waiting on, for retrying with another target.
    var pendingOwner: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return pending?.owner
    }

    var hasPendingConversion: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil
    }

    // MARK: - Mac copies, guest pastes

    /// What the Mac holds for a Linux client, when the Mac owns the
    /// clipboard. `nil` means it does not.
    func payloadForGuest() -> MacPayload? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return macPayload
    }

    /// The text the Mac holds, if any. Kept for callers that only want text.
    func textForGuest() -> String? { payloadForGuest()?.text }

    /// The targets MSL offers for what the Mac holds, in the order toolkits
    /// prefer them.
    ///
    /// Built from the payload rather than fixed: offering `image/png` for a
    /// copy that has no image makes every toolkit ask for it and get a
    /// refusal, and offering the text targets for an image-only copy makes a
    /// text field paste nothing when it could have pasted nothing more
    /// honestly by not being offered at all.
    func offeredTargets() -> [UInt32] {
        let payload = payloadForGuest() ?? MacPayload()
        var targets = [targetsAtom(), timestampAtom()]
        if !payload.files.isEmpty { targets += [uriListAtom(), gnomeCopiedAtom()] }
        if payload.text != nil { targets += [utf8Atom(), Self.stringAtom, textAtom()] }
        if payload.png != nil { targets.append(imagePNGAtom()) }
        return targets.filter { $0 != 0 }
    }

    /// The `text/uri-list` body: one `file://` URI per line, CRLF, as the
    /// spec says. Percent-encoded, or a path with a space in it arrives as
    /// two URIs.
    static func uriList(_ guestPaths: [String]) -> [UInt8] {
        let uris = guestPaths.map { path -> String in
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "file://" + escaped
        }
        return Array((uris.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// GNOME's variant: an action, then the same URIs.
    ///
    /// **Always `copy`, never `cut`.** A cut would have the Linux side
    /// delete the Mac's original after a successful paste, and nothing that
    /// crosses this boundary should be able to remove a file on the other
    /// side of it - least of all as a side effect of a paste that might
    /// half-succeed.
    static func gnomeCopiedFiles(_ guestPaths: [String]) -> [UInt8] {
        let uris = guestPaths.map { path -> String in
            "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        }
        return Array((["copy"] + uris).joined(separator: "\n").utf8)
    }

    /// Bytes for a requested target, or `nil` if MSL cannot produce it.
    func data(for target: UInt32) -> (type: UInt32, format: UInt8, data: [UInt8])? {
        let payload = payloadForGuest() ?? MacPayload()
        if target == imagePNGAtom(), let png = payload.png {
            return (imagePNGAtom(), 8, png)
        }
        if !payload.files.isEmpty {
            if target == uriListAtom() {
                return (uriListAtom(), 8, Self.uriList(payload.files))
            }
            if target == gnomeCopiedAtom() {
                return (gnomeCopiedAtom(), 8, Self.gnomeCopiedFiles(payload.files))
            }
        }
        guard let text = payload.text else { return nil }
        if target == utf8Atom() || target == textAtom() || target == 0 {
            return (utf8Atom(), 8, Array(text.utf8))
        }
        if target == Self.stringAtom {
            // Latin-1 or nothing: a client that asked for STRING cannot be
            // handed UTF-8 bytes and left to guess.
            guard let latin1 = text.data(using: .isoLatin1) else { return nil }
            return (Self.stringAtom, 8, Array(latin1))
        }
        return nil
    }

    // MARK: - Watching the Mac's pasteboard

    /// Polling starts with the first client and stops with the last: an idle
    /// host sitting out its exit timer has nothing to watch for.
    func connectionCountChanged(to count: Int) {
        guard enabled else { return }
        lock.lock()
        let running = timer != nil
        lock.unlock()
        if count > 0, !running { startPolling() } else if count == 0, running { stopPolling() }
    }

    private func startPolling() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        source.setEventHandler { [weak self] in self?.pollPasteboard() }
        lock.lock()
        lastChangeCount = pasteboard.changeCount
        timer = source
        lock.unlock()
        // Whatever is on the pasteboard right now counts as the Mac's, not
        // as "already seen". An app started after the copy would otherwise
        // never claim it, and pasting into the first Linux window you open
        // would quietly do nothing - the copy happened before this process
        // existed. A host with no clients yet owns nothing, so there is
        // nothing to take it from.
        adoptCurrentPasteboard()
        source.resume()
    }

    /// Claims whatever is already on the pasteboard.
    func adoptCurrentPasteboard() {
        guard enabled, let payload = readPasteboard() else { return }
        claimForMac(payload)
    }

    /// What the Mac's pasteboard holds, in the forms Linux can use.
    ///
    /// **Concealed items are skipped.** Password managers mark what they put
    /// on the pasteboard with `org.nspasteboard.ConcealedType` precisely so
    /// that clipboard tools leave it alone, and a bridge that copies every
    /// password into a Linux VM is not one anybody should have on by
    /// default.
    func readPasteboard() -> MacPayload? {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pasteboard.availableType(from: [concealed]) != nil { return nil }
        var payload = MacPayload()
        if let text = pasteboard.string(forType: .string), !text.isEmpty { payload.text = text }
        payload.files = guestPathsOnPasteboard()

        // **Files win over the image, and that is not a preference.**
        // Copying a file in Finder puts the file's *icon* on the pasteboard
        // as TIFF alongside the file URL. Offering `image/png` whenever an
        // image is present would mean pasting a copied document into GIMP
        // produced a picture of a Finder icon - which looks like the bridge
        // working and is entirely wrong.
        if payload.files.isEmpty { payload.png = pasteboardPNG() }
        return payload.isEmpty ? nil : payload
    }

    /// File URLs on the pasteboard, as paths the guest can open.
    ///
    /// **Only what the guest can actually reach.** The Mac's home directory
    /// is mounted in every guest at `/mnt/mac` (fixed, written into the
    /// guest's fstab at build time), so anything under the home translates
    /// with no lookup at all. A file on an external disk or in another
    /// user's home has no guest equivalent and is dropped rather than
    /// handed over as a path that silently does not exist.
    private func guestPathsOnPasteboard() -> [String] {
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !items.isEmpty
        else { return [] }
        return items.filter(\.isFileURL).compactMap { url in
            switch GuestPathMapper.map(hostPath: url.path, guestMounts: []) {
            case .macHomeShare(let guestPath): return guestPath
            // A guest's own mount would need its path, which this process
            // does not have - see the note in `README 25`. Those are dropped.
            case .guestFilesystem, .unreachable: return nil
            }
        }
    }

    /// The pasteboard's image as PNG bytes.
    ///
    /// `NSPasteboard` hands out TIFF, which almost nothing on Linux reads,
    /// so it is re-encoded once here rather than by every client.
    private func pasteboardPNG() -> [UInt8]? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return Array(png) }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              !png.isEmpty
        else { return nil }
        return Array(png)
    }

    private func stopPolling() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    private func pollPasteboard() {
        expirePending()
        let count = pasteboard.changeCount
        lock.lock()
        let seen = lastChangeCount
        lock.unlock()
        guard count != seen else { return }
        lock.lock()
        lastChangeCount = count
        lock.unlock()
        guard let payload = readPasteboard() else { return }
        claimForMac(payload)
    }

    /// Takes `CLIPBOARD` on the Mac's behalf and tells the previous owner it
    /// lost it, which is what ICCCM requires and what stops a toolkit from
    /// believing it still owns a selection it does not.
    func claimForMac(_ payload: MacPayload) {
        guard let state else { return }
        lock.lock()
        macPayload = payload
        lock.unlock()
        let selection = clipboardAtom()
        let previous = state.selectionOwner(selection)
        // Stamped, like any other claim: a `TIMESTAMP` conversion against
        // a Mac-owned selection has to answer with a real acquisition
        // time, not zero.
        let time = X11Connection.x11Now
        state.setSelectionOwner(selection, owner: Self.macOwnerWindowID, time: time)
        if previous != 0, previous != Self.macOwnerWindowID {
            state.connection(forWindow: previous)?.deliverSelectionClear(owner: previous, selection: selection)
        }
        // A copy on the Mac is an ownership change like any other, so every
        // XFIXES watcher hears it too. This is the half that makes the
        // extension worth having here: without it a Linux clipboard manager
        // or a GTK app's paste menu only ever learns about copies made
        // inside Linux, and the Mac's clipboard appears to it as nothing
        // happening at all.
        for connection in state.allConnections() {
            connection.deliverXFixesSelectionNotify(
                selection: selection, owner: Self.macOwnerWindowID,
                subtype: X11XFixesSelectionEvent.setSelectionOwner,
                mask: X11XFixesSelectionEvent.setSelectionOwnerMask,
                selectionTime: time)
        }
    }

    /// Puts what a Linux app copied on the Mac's pasteboard without then
    /// reading it back as a Mac-side copy: the change count MSL's own write
    /// produces is recorded as already seen.
    ///
    /// Every representation goes on **one** `NSPasteboardItem`, so a Mac app
    /// takes whichever it prefers - Preview the image, a text field the
    /// text - rather than MSL having to guess which one the copy "was".
    private func publishToMac(_ payload: MacPayload) {
        let apply = { [weak self] in
            guard let self else { return }
            self.pasteboard.clearContents()
            let item = NSPasteboardItem()
            if let text = payload.text { item.setString(text, forType: .string) }
            if let png = payload.png { item.setData(Data(png), forType: .png) }
            self.pasteboard.writeObjects([item])
            self.lock.lock()
            self.lastChangeCount = self.pasteboard.changeCount
            self.macPayload = nil
            self.lock.unlock()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
}
