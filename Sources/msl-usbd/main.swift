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

func usageAndExit() -> Never {
    FileHandle.standardError.write("usage: msl-usbd list | watch | open <locationID hex>\n".data(using: .utf8)!)
    exit(1)
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

default:
    usageAndExit()
}
