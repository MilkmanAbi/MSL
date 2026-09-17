import AppKit
import MSLCore

// One Linux application, one macOS process, one Dock tile.
//
// This binary is never run under this name in practice: `X11AppRouter`
// copies it to `~/Library/Caches/MSL/AppShims/<AppName>` and starts THAT,
// because an unbundled executable takes its user-visible name - Dock tile,
// Cmd-Tab, `NSRunningApplication.localizedName()` - from its filename.
// Every copy is this same code; only the path differs.
//
// `mslhd` accepts the vsock connection, reads far enough to learn the app's
// `WM_CLASS`, and hands the live descriptor here over `SCM_RIGHTS` along
// with the bytes it had to consume to find out. From that point this
// process is the X11 server for that one application: its own `X11State`,
// its own windows, its own Dock integration.
let arguments = CommandLine.arguments
guard arguments.count >= 5, arguments[1] == "--msl-app-host", arguments[3] == "--host-slot",
      let hostSlot = UInt32(arguments[4])
else {
    FileHandle.standardError.write("usage: \(arguments.first ?? "mslgui") --msl-app-host <socket-path> --host-slot <n>\n".data(using: .utf8)!)
    exit(2)
}

// `hostSlot` keeps this host's X11 resource IDs from colliding with any
// other host's - see `X11State.seedClientIndex(hostSlot:)`.
// Optional and trailing, so an app shim started by an older build (which
// passes no such flag) still works - see `X11AppRouter.spawn`. Without it
// this process cannot answer "am I sandboxed?", and `X11InputGate` fails
// open rather than guessing.
var instanceName: String?
if let flag = arguments.firstIndex(of: "--instance"), flag + 1 < arguments.count {
    instanceName = arguments[flag + 1]
}

// A write to an X11 connection the guest has closed - an app that exited,
// a connection that did not survive sleep - raises SIGPIPE, whose default
// action kills this process outright with no log line. The write's EPIPE
// is handled where it happens (`X11Connection.writeFull`).
signal(SIGPIPE, SIG_IGN)

let host = X11AppHost(socketPath: arguments[2], hostSlot: hostSlot, instance: instanceName)
guard host.start() else {
    FileHandle.standardError.write("mslgui: could not listen on \(arguments[2])\n".data(using: .utf8)!)
    exit(1)
}

// `.accessory` to begin with, exactly as `mslhd` is: a host that has not
// mapped a window yet must not put a tile in the Dock. `X11DockIntegration`
// promotes the process to `.regular` on the first real top-level window and
// demotes it again when the last one goes - so the tile's lifetime matches
// the app's windows, not the process's.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
