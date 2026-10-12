import Foundation
import XCTest
@testable import MSLCore

/// A real `X11Connection` on a socketpair, driven over the wire.
///
/// Firefox died on its first `GetKeyboardControl`: the handler built a
/// 26-byte fixed part, and `sendReply`'s layout check took down the whole
/// app host. Nothing caught it because no test ever sent that request. This
/// sweeps every request that has no body and expects a reply, and checks
/// the framing a client relies on: a reply (not an error), and exactly
/// `32 + 4 * length` bytes.
final class X11LiveReplyTests: XCTestCase {
    private var client: Int32 = -1

    override func setUp() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        client = fds[0]
        let serverFD = fds[1]
        let state = X11State()
        state.seedClientIndex(hostSlot: 60)
        let index = state.nextClientIndex()
        Thread { X11Connection(fd: serverFD, clientIndex: index, state: state, prefix: [], instance: nil).run() }.start()
        // Setup: little endian, protocol 11.0, no auth.
        send([0x6C, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let head = receive(8)
        XCTAssertEqual(head.first, 1, "setup accepted")
        let extra = Int(head[6]) | Int(head[7]) << 8
        _ = receive(extra * 4)
    }

    override func tearDown() { close(client) }

    func testEveryBodylessQueryGetsAWellFramedReply() {
        let queries: [(UInt8, String)] = [
            (43, "GetInputFocus"), (44, "QueryKeymap"), (52, "GetFontPath"), (99, "ListExtensions"),
            (103, "GetKeyboardControl"), (106, "GetPointerControl"), (108, "GetScreenSaver"),
            (110, "ListHosts"), (117, "GetPointerMapping"), (119, "GetModifierMapping"),
        ]
        for (opcode, name) in queries {
            send([opcode, 0, 1, 0])
            let reply = nextReplyOrError()
            XCTAssertEqual(reply.first, 1, "\(name) must answer with a reply, got \(reply.first.map(String.init) ?? "nothing")")
        }
        // Still alive and in step: one more round trip after the sweep.
        send([43, 0, 1, 0])
        XCTAssertEqual(nextReplyOrError().first, 1, "the connection survived every reply")
    }

    /// RANDR queries real clients assume always work. Each used to be
    /// BadImplementation (Firefox's glxtest logged GetProviders' as an X
    /// error on every launch). Bodies are zeros: the handlers answer the
    /// one screen whatever id is asked about.
    func testRandRQueriesGetWellFramedReplies() {
        let randr: UInt8 = 154
        let queries: [(UInt8, Int, String)] = [
            (0, 2, "QueryVersion"), (5, 1, "GetScreenInfo"), (6, 1, "GetScreenSizeRange"),
            (8, 1, "GetScreenResources"), (10, 1, "ListOutputProperties"), (15, 6, "GetOutputProperty"),
            (22, 1, "GetCrtcGammaSize"), (23, 1, "GetCrtcGamma"), (25, 1, "GetScreenResourcesCurrent"),
            (27, 1, "GetCrtcTransform"), (28, 1, "GetPanning"), (31, 1, "GetOutputPrimary"),
            (32, 1, "GetProviders"), (42, 2, "GetMonitors"),
        ]
        for (minor, bodyWords, name) in queries {
            send([randr, minor, UInt8(1 + bodyWords), 0] + [UInt8](repeating: 0, count: bodyWords * 4))
            let reply = nextReplyOrError()
            XCTAssertEqual(reply.first, 1, "RANDR \(name) (minor \(minor)) must reply, got \(reply.first.map(String.init) ?? "nothing")")
        }
        send([43, 0, 1, 0])
        XCTAssertEqual(nextReplyOrError().first, 1, "still in step after the RANDR sweep")
    }

    /// XI1 ListInputDevices: GTK2 aborted at startup on BadImplementation.
    /// Two core devices, the device infos and names inside a padded reply.
    func testXI1ListInputDevicesListsTheCoreDevices() {
        send([152, 2, 1, 0])
        let reply = nextReplyOrError()
        XCTAssertEqual(reply.first, 1, "must be a reply, not an error")
        XCTAssertEqual(reply[1], 2, "RepType = X_ListInputDevices")
        XCTAssertEqual(reply[8], 4, "core pointer + keyboard, MSL Mouse, MSL Touchpad")
        XCTAssertEqual((reply.count - 32) % 4, 0)
        let text = String(decoding: reply[32...], as: UTF8.self)
        XCTAssertTrue(text.contains("Virtual core pointer") && text.contains("Virtual core keyboard"))
        send([43, 0, 1, 0])
        XCTAssertEqual(nextReplyOrError().first, 1, "still in step")
    }

    /// XIQueryDevice walked the way libXi and xcb do: every class's length
    /// must land exactly on the next, and the reply must be consumed to the
    /// byte. ScrollClass (type 3) only for XI >= 2.1 clients, GestureClass
    /// (type 9) only for >= 2.4, and only on the MSL slaves / touchpad.
    func testXIQueryDeviceClassesFollowNegotiatedVersion() {
        func classes(afterVersion minor: UInt16) -> [UInt16: [UInt16]] {
            send([152, 47, 2, 0, 2, 0, UInt8(minor), 0]) // XIQueryVersion 2.minor
            XCTAssertEqual(nextReplyOrError().first, 1)
            send([152, 48, 2, 0, 0, 0, 0, 0]) // XIQueryDevice(XIAllDevices)
            let r = nextReplyOrError()
            XCTAssertEqual(r.first, 1)
            let n = Int(r[8]) | Int(r[9]) << 8
            var off = 32
            var out: [UInt16: [UInt16]] = [:]
            func u16(_ o: Int) -> Int { Int(r[o]) | Int(r[o + 1]) << 8 }
            for _ in 0..<n {
                let id = UInt16(u16(off)), ncls = u16(off + 6), nameLen = u16(off + 8)
                off += 12 + ((nameLen + 3) & ~3)
                var types: [UInt16] = []
                for _ in 0..<ncls {
                    types.append(UInt16(u16(off)))
                    off += u16(off + 2) * 4
                }
                out[id] = types
            }
            XCTAssertEqual(off, r.count, "every class length adds up to the reply")
            return out
        }
        // One client negotiates once; fresh state per version via separate sockets
        // is not needed here - the server re-answers with the latest agreement.
        let v20 = classes(afterVersion: 0)
        XCTAssertFalse(v20.values.contains { $0.contains(3) }, "no ScrollClass for an XI 2.0 client")
        let v21 = classes(afterVersion: 1)
        XCTAssertEqual(v21[6]?.filter { $0 == 3 }.count, 2, "MSL Mouse: vertical + horizontal ScrollClass")
        XCTAssertEqual(v21[2]?.filter { $0 == 3 }.count, 2, "the master carries its slave's scroll classes")
        XCTAssertFalse(v21[7]?.contains(9) ?? true, "no GestureClass below 2.4")
        let v24 = classes(afterVersion: 4)
        XCTAssertTrue(v24[7]?.contains(9) ?? false, "MSL Touchpad has a GestureClass at 2.4")
        XCTAssertFalse(v24[6]?.contains(9) ?? true, "the mouse does not")
        XCTAssertEqual(Set(v24.keys), [2, 3, 4, 5, 6, 7])
    }

    /// Every XInput minor, XI1 through XI 2.4, answers with a reply, a
    /// specific error or nothing - never BadImplementation, which Xlib's
    /// default handler turns into an exit (Blender died on minor 6,
    /// SelectExtensionEvent). Replies must also keep the stream in step.
    func testEveryXInputMinorIsAnsweredWithoutBadImplementation() {
        var implementationErrors: [UInt8] = []
        var seq = 0 // this test's connection is fresh: its first request is 1
        for minor: UInt8 in 1...61 {
            // Six zero words: every request's fixed part fits, device 0.
            send([152, minor, 7, 0] + [UInt8](repeating: 0, count: 24))
            send([43, 0, 1, 0]) // GetInputFocus, to know when the XInput answer is in
            seq += 2
            while true {
                let packet = nextReplyOrError()
                guard packet.count >= 32 else { XCTFail("minor \(minor): stream ended"); return }
                let packetSeq = Int(packet[2]) | Int(packet[3]) << 8
                if packet[0] == 0, packetSeq == seq - 1, packet[1] == 17 { implementationErrors.append(minor) }
                if packetSeq == seq { break }
            }
        }
        XCTAssertEqual(implementationErrors, [], "minors answered BadImplementation")
    }

    /// GLX's two config replies, whose framing is easy to get subtly wrong
    /// and which fail silently when you do: `GetVisualConfigs` must lead
    /// with exactly 18 properties per config, and `GetFBConfigs`'
    /// `numAttribs` counts PAIRS (Mesa reads `numAttribs * 2` words), so an
    /// off-by-two there decodes every config as garbage rather than erroring.
    func testGLXConfigRepliesAreFramedAsMesaReadsThem() {
        let glx: UInt8 = 159
        send([glx, 14, 2, 0, 0, 0, 0, 0]) // GetVisualConfigs(screen 0)
        var reply = nextReplyOrError()
        XCTAssertEqual(reply.first, 1, "GetVisualConfigs replies")
        func u32(_ r: [UInt8], _ o: Int) -> Int {
            Int(r[o]) | Int(r[o + 1]) << 8 | Int(r[o + 2]) << 16 | Int(r[o + 3]) << 24
        }
        let visualCount = u32(reply, 8), properties = u32(reply, 12)
        XCTAssertEqual(properties, 18, "18 fixed properties, no tagged extras")
        XCTAssertEqual(reply.count, 32 + visualCount * properties * 4, "length matches the counts")

        send([glx, 21, 2, 0, 0, 0, 0, 0]) // GetFBConfigs(screen 0)
        reply = nextReplyOrError()
        XCTAssertEqual(reply.first, 1, "GetFBConfigs replies")
        let configs = u32(reply, 8), pairs = u32(reply, 12)
        XCTAssertGreaterThan(configs, 0)
        XCTAssertEqual(reply.count, 32 + configs * pairs * 8, "numAttribs is a PAIR count")
        // Every config must name a real visual and carry an id.
        var sawFBConfigID = false, sawVisualID = false
        for k in stride(from: 32, to: 32 + pairs * 8, by: 8) {
            if u32(reply, k) == 0x8013 { sawFBConfigID = true }
            if u32(reply, k) == 0x800B { sawVisualID = true }
            XCTAssertNotEqual(u32(reply, k), 0x800C, "GLX_SCREEN is not a valid fbconfig attribute")
        }
        XCTAssertTrue(sawFBConfigID && sawVisualID, "each config carries GLX_FBCONFIG_ID and GLX_VISUAL_ID")
        send([43, 0, 1, 0])
        XCTAssertEqual(nextReplyOrError().first, 1, "still in step")
    }

    /// The exact layout Firefox depends on: 44 bytes of fields, reply
    /// length 5, global auto-repeat in the detail byte.
    func testGetKeyboardControlLayout() {
        send([103, 0, 1, 0])
        let reply = nextReplyOrError()
        XCTAssertEqual(reply.count, 52)
        XCTAssertEqual(reply.first, 1)
        XCTAssertEqual(reply[1], 1, "global auto-repeat on")
        XCTAssertEqual(Int(reply[4]) | Int(reply[5]) << 8, 5, "reply length in 4-byte units")
    }

    // MARK: plumbing (the handshake hops to the main thread, so every wait
    // pumps the main run loop instead of blocking it)

    private func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    private func receive(_ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        let flags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(5)
        while out.count < count, Date() < deadline {
            var buf = [UInt8](repeating: 0, count: count - out.count)
            let n = buf.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n > 0 { out += buf.prefix(n) } else { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        return out
    }

    /// Skips events; returns the whole next reply (or error) packet.
    private func nextReplyOrError() -> [UInt8] {
        while true {
            let head = receive(32)
            guard head.count == 32 else { return head }
            if head[0] == 1 {
                let words = Int(head[4]) | Int(head[5]) << 8 | Int(head[6]) << 16 | Int(head[7]) << 24
                return head + receive(words * 4)
            }
            if head[0] == 0 { return head }
            if head[0] & 0x7F == 35 { // GenericEvent: 32 + 4 * length
                let words = Int(head[4]) | Int(head[5]) << 8 | Int(head[6]) << 16 | Int(head[7]) << 24
                _ = receive(words * 4)
            }
        }
    }
}
