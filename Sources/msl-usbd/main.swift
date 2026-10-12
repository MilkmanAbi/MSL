import Foundation
import MSLCore

/*
 * msl-usbd
 *
 * Host-side USB daemon groundwork - Phase 1 per msl-platform.md: enumerate
 * and claim USB devices macOS has no existing system driver for (dev
 * boards, USB-serial adapters, custom hardware), using the modern
 * IOUSBHost.framework (not the legacy IOUSBLib the original design doc's
 * C samples were written against - see README for why that distinction
 * matters and what got verified about it).
 *
 * Not wired up to a guest yet (no USB/IP-over-vsock transport exists) -
 * this is a diagnostic CLI for the framework pieces themselves:
 *
 *   msl-usbd list                    list currently attached USB devices
 *   msl-usbd watch                   watch for arrivals/removals (Ctrl-C to stop)
 *   msl-usbd open <locationID hex>   claim a device and print its descriptor
 *
 * `list`/`watch` need no entitlement. `open` needs
 * `com.apple.vm.device-access` (see Resources/msl-usbd/) and, per Phase 1's
 * design, only succeeds for a device macOS has no system driver for
 * already - see USBDeviceClaim's doc comment.
 */

// `watch` is long-running and its output matters in real time - stdout is
// fully block-buffered (not line-buffered) whenever it isn't a tty (e.g.
// piped to a log file, or captured by a supervising process), which
// silently delayed every `print()` here until process exit. Confirmed on a
// real run: piped to a file and sent SIGTERM, the file stayed completely
// empty despite "watching for USB device changes..." having already
// printed successfully by then.
setbuf(stdout, nil)

/// Signal sources have to outlive the statement that made them, or they are
/// deallocated immediately and the handler never runs.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func usageAndExit() -> Never {
    FileHandle.standardError.write("""
usage: msl-usbd list
       msl-usbd watch
       msl-usbd open <locationID hex>
       msl-usbd serve-synthetic --tcp <port>
       msl-usbd serve-relay <device> --connect <socket>   (started by msl usb attach)
       msl-usbd serve <device> --tcp <port> [--capture]

""".data(using: .utf8)!)
    exit(1)
}

/// Serves one backend over a plain TCP listener, for development.
///
/// Production passthrough carries USB/IP over vsock from inside mslhd,
/// which owns the `VZVirtioSocketDevice` - but iterating on the wire
/// format that way means rebuilding and reinstalling the whole app for
/// every byte of the protocol. A guest can reach the Mac on its NAT
/// gateway, so this serves the identical `USBIPServer` over TCP instead
/// and keeps the edit-test loop to seconds.
func serveTCP(port: UInt16, makeBackend: @escaping () -> USBIPDeviceBackend) -> Never {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { perror("socket"); exit(1) }
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_ANY
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
    }
    guard bound == 0 else { perror("bind"); exit(1) }
    guard Darwin.listen(listener, 4) == 0 else { perror("listen"); exit(1) }
    print("listening on tcp/\(port) - attach from the guest with:")
    print("  msl-usbattach --tcp 192.168.64.1 \(port)")
    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { if errno == EINTR { continue }; perror("accept"); exit(1) }
        print("guest connected")
        // One device per connection, exactly as over vsock.
        let server = USBIPServer(fd: client, backend: makeBackend()) { print("[usbip] \($0)") }
        Thread {
            server.run()
            close(client)
            print("connection finished")
        }.start()
    }
}

func printDevice(_ device: USBDeviceInfo, prefix: String = "") {
    print("\(prefix)\(device)")
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "list":
    let devices = USBDeviceEnumerator.listDevices()
    if devices.isEmpty {
        print("no USB devices found")
    } else {
        devices.forEach { printDevice($0) }
    }

case "watch":
    print("watching for USB device changes (Ctrl-C to stop) ...")
    let watcher = try USBDeviceWatcher(
        onArrival: { printDevice($0, prefix: "+ arrived: ") },
        onRemoval: { printDevice($0, prefix: "- removed: ") }
    )
    _ = watcher // keep alive
    RunLoop.main.run()

case "open":
    guard args.count == 2, let locationID = UInt32(args[1], radix: 16) else { usageAndExit() }
    do {
        let claim = try USBDeviceClaim(locationID: locationID)
        print("claimed: \(claim.info)")
        print(claim.deviceDescriptorSummary)
        if let product = try claim.productString() {
            print("product string: \(product)")
        }
    } catch {
        FileHandle.standardError.write("msl-usbd: failed to claim device: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "serve-relay":
    // The privileged half of passthrough, started by `msl usb attach`
    // under sudo. It captures the device, then speaks USB/IP down a Unix
    // socket that ends in mslhd, which pumps it to the guest's vsock.
    //
    // Deliberately not given the guest's connection directly: mslhd has to
    // remain the owner of it, or it would not know an attachment existed
    // and would pause and then hibernate the guest underneath this process
    // - and nothing would close this socket when the guest stopped,
    // leaving the device captured and stranded.
    guard args.count >= 4, let connectIndex = args.firstIndex(of: "--connect"),
          connectIndex + 1 < args.count else { usageAndExit() }
    let socketPath = args[connectIndex + 1]
    let capture = !args.contains("--no-capture")
    if capture, geteuid() != 0 {
        FileHandle.standardError.write("""
        msl-usbd: taking a device from macOS needs root. Do not run this directly -
          `msl usb attach` starts it under sudo when it is needed.

        """.data(using: .utf8)!)
        exit(1)
    }

    // mslhd first, the device second. Capturing terminates macOS's own
    // driver, so doing it before the handshake means a password typed after
    // the handshake timed out would kick a driver off a device, fail to
    // connect, and put it straight back - a pointless forced unmount of
    // whatever was using it.
    guard let relayFD = USBRootRelay.connect(to: socketPath) else {
        FileHandle.standardError.write("""
        msl-usbd: mslhd isn't waiting at that socket any more - nothing was attached.
          The attach times out after two minutes at the password prompt; run it again.

        """.data(using: .utf8)!)
        exit(1)
    }

    let backend: USBIPDeviceBackend
    if args[1].lowercased() == "synthetic" {
        backend = SyntheticUSBDevice { print("[synthetic] \($0)") }
    } else {
        guard let locationID = UInt32(args[1], radix: 16),
              let found = USBDeviceEnumerator.findService(locationID: locationID) else {
            FileHandle.standardError.write("msl-usbd: no USB device at location \(args[1])\n".data(using: .utf8)!)
            exit(1)
        }
        do {
            backend = try HostUSBDevice(service: found.service, info: found.info,
                                        capture: capture) { print("[usb] \($0)") }
        } catch {
            FileHandle.standardError.write(
                "msl-usbd: could not open the device: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    print("serving \(backend.displayName)\(capture ? " (captured from macOS)" : "") - ^C to detach")

    // Ctrl-C has to release the device rather than drop it: without the
    // teardown the device stays captured and belongs to nobody until it is
    // physically replugged.
    let release = {
        backend.teardown()
        print("\n\(backend.displayName) released back to macOS")
    }
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { release(); exit(0) }
        source.resume()
        signalSources.append(source)
    }

    // Serving blocks; the signal sources above need the main queue, so the
    // USB/IP loop runs beside them.
    let relayServer = USBIPServer(fd: relayFD, backend: backend) { print("[usbip] \($0)") }
    Thread {
        relayServer.run()
        // mslhd closed the relay: the guest detached, or its instance
        // stopped. Either way this process is done.
        release()
        exit(0)
    }.start()
    dispatchMain()

case "serve":
    // Serves a real device over TCP. This exists so that passthrough can be
    // tested against hardware *now*: `msl usb attach --capture` needs root,
    // mslhd runs as the user, and the root helper that would bridge the two
    // is not written yet. Run this under `sudo` and attach from the guest
    // with `msl-usbattach --tcp 192.168.64.1 <port>`.
    guard args.count >= 3, args.contains("--tcp"),
          let tcpIndex = args.firstIndex(of: "--tcp"), tcpIndex + 1 < args.count,
          let port = UInt16(args[tcpIndex + 1]),
          let locationID = UInt32(args[1], radix: 16) else { usageAndExit() }
    let capture = args.contains("--capture")
    if capture, geteuid() != 0 {
        FileHandle.standardError.write("""
        msl-usbd: --capture needs root (IOUSBHostObjectInitOptionsDeviceCapture takes
          the entitlement OR root, and the entitlement is restricted). Re-run with sudo.

        """.data(using: .utf8)!)
        exit(1)
    }
    guard let found = USBDeviceEnumerator.findService(locationID: locationID) else {
        FileHandle.standardError.write("msl-usbd: no USB device at location \(args[1])\n".data(using: .utf8)!)
        exit(1)
    }
    print("serving \(found.info)\(capture ? " (captured from macOS)" : "")")
    // One backend for the process: capture terminates macOS's own drivers,
    // so opening the same device twice is not something to offer.
    let device: HostUSBDevice
    do {
        device = try HostUSBDevice(service: found.service, info: found.info,
                                   capture: capture) { print("[usb] \($0)") }
    } catch {
        FileHandle.standardError.write("""
        msl-usbd: could not open the device: \(error.localizedDescription)
        \(capture ? "" : "  macOS may already have a driver for it - try --capture under sudo.\n")
        """.data(using: .utf8)!)
        exit(1)
    }
    serveTCP(port: port) { device }

case "serve-synthetic":
    guard args.count == 3, args[1] == "--tcp", let port = UInt16(args[2]) else { usageAndExit() }
    serveTCP(port: port) { SyntheticUSBDevice { print("[synthetic] \($0)") } }

default:
    usageAndExit()
}
