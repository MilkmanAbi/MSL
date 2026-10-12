# USB passthrough

Mac USB devices inside a Linux guest, over USB/IP on vsock. No paid Apple
entitlement, no image rebuild, no DriverKit extension.

```
Mac USB device → IOUSBHost (HostUSBDevice) → USBIPServer
  → vsock 5012 → [guest] msl-usbattach → /sys/.../vhci_hcd.0/attach
  → the guest's own USB stack
```

```
msl usb list                     # what is on the Mac, and who holds it
msl usb attach <device> [inst]   # give it to an instance; <device> is a
                                 #   location ID or vendor:product
msl usb detach <device> [inst]   # take it back; macOS picks it up again
msl usb test [instance]          # attach MSL's synthetic device
msl usb test [instance] --relay  # ...through the privileged path instead
msl usb relay <device> [inst]    # print a socket for a root helper, and exit
```

## Two tiers, and the person never types sudo

```
LOCATION   ID         macOS DRIVER    ATTACHED TO  DEVICE
00100000   1209:4d53  none - native   -            Some Weird Board
00200000   0403:6001  AppleUSBFTDI    Milk         FT232R USB UART
```

`msl usb attach` asks the daemon which tier a device needs *before* doing
anything, so the two cases feel different in the right way:

- **native** - nothing on the Mac has claimed it. mslhd opens it and serves
  it. No password, no helper, returns immediately. This is the case MSL is
  aimed at: hardware macOS has never heard of.
- **capture** - macOS has a driver on it. MSL says which driver, says the
  device goes back on detach, and then asks for a password with a prompt
  that says what it is for. Only `msl-usbd` runs as root, for as long as the
  attachment lasts; `^C` detaches (so does closing the window - the helper
  takes SIGHUP too).

Either tier **starts the instance if it is not running**. `usbAttach` and
`usbRelay` both declare `startsInstance`, because mslhd pauses a guest a few
seconds after its last session closes - so "is it running?" is nearly always
no, and an attach that refused would be useless. Handing a device to an
instance is a deliberate request for that instance to have it.

`msl usb attach` runs `sudo` itself, by **`execv`** rather than
`Process`. That is not a nicety: Foundation puts a spawned child in a new
process group, so `sudo` takes SIGTTIN the instant it reads the terminal and
stops dead - `stat T`, process group not the terminal's foreground group, and
a password prompt that never accepts anything. Replacing the process gives
`sudo` the terminal `msl` already had, and the signals, the terminal and the
exit status then all behave for free. `msl` has nothing to do afterwards: the
attachment lasts exactly as long as the helper.

### The helper must come from /Applications

`sudo` runs this, so whoever can write the binary gets root on the Mac - and
the obvious copy, `~/Library/Application Support/MSL/bin/msl-usbd`, is
**writable from inside a Linux guest**, because MSL mounts the Mac's home at
`/mnt/mac` read-write. Measured, from a guest, as the ordinary user:

```
whoami: abinaash (1001)
RESULT: the guest CAN write the bin directory
RESULT: msl-usbd itself is WRITABLE from the guest
```

Any Linux process could have replaced it and waited for somebody to attach a
claimed device. So `USBHelperLocator` runs the copy inside the installed
`MSL.app` - `root:admin`, with root-owned parents, and nothing mounts
`/Applications` into a guest - and it *verifies* that rather than assuming
it, because a `dist/` build is owned by the user like anything else.

The check allows group-writable for `wheel` and `admin` only, because
`/Applications` ships as `drwxrwxr-x root:admin` on every Mac and refusing
that would refuse the only trustworthy copy there is. **So this does not
defend against a local process already running as an administrator**, which
could replace the bundle. That is the trust model of `sudo`-ing anything
under `/Applications`, and ad-hoc signing leaves no Team ID to pin, so MSL
cannot improve on it - but it closes the guest hole, which is the one MSL
itself introduced.

`sudo msl ...` is refused outright, with an explanation. It cannot work:
every MSL path resolves through `NSHomeDirectory()`, which under sudo is
`/var/root` - so it would install a second set of tools there, fail to find
the daemon and report no instances. (It did exactly that once, which is how
this is known.)

### The root half never touches the guest

The privileged helper serves USB/IP down a **Unix socket that ends in
mslhd**, and mslhd pumps it to the guest's vsock. It would be simpler to let
the helper take the guest's connection directly, and it would be wrong:

- mslhd would not know an attachment existed, so the 3-second auto-pause and
  the 5-minute idle hibernate would both fire and the device would die in the
  guest.
- Nothing would close the helper's socket when the guest stopped, so the
  device would stay captured and belong to nobody until it was replugged.
- A root listener would be reachable by every other instance on the vmnet
  bridge.

Relaying keeps all the guards, the suspend survival and the teardown exactly
as they are for the native tier, and the helper simply reads EOF and releases
the device. `USBRootRelay` is the handshake: a one-shot listener in a 0700
directory, a path (not an fd - `sudo` closes inherited descriptors above
stderr), and a `getpeereid` check that the peer really is uid 0. Without that
check, anything this user can run could pretend to be a captured device and
feed arbitrary USB traffic into a guest.

## What is verified, and what is not

**Both transports are verified end to end**, native and privileged, using
`SyntheticUSBDevice` - descriptors answered from a table instead of from
hardware. `msl usb test` drives the native path and `msl usb test --relay`
drives the root path (the helper, the handshake socket, the uid check and the
pump), and a guest enumerates the device either way:

```
usb 1-1: new high-speed USB device number 5 using vhci_hcd
usb 1-1: New USB device found, idVendor=1209, idProduct=4d53, bcdDevice= 2.00
usb 1-1: Product: MSL Virtual Test Device
```

```
hub port sta spd dev      sockfd local_busid
hs  0000 006 003 00000001 000003 1-1        <- VDEV_ST_USED
```

That proves the vsock carriage, the `vhci_hcd` attach, the 48-byte
big-endian URB framing, the control-transfer path, descriptor
little-endianness, the host-initiated pairing, and - on the `--relay` run -
the root handshake and the pump. Two devices at once work (ports 0 and 1),
the whole thing survives a suspend/resume, and `msl usb detach` produces a
real `usb 1-1: USB disconnect` with the vhci port back to free on both
tiers.

**`shutdown`, not `close`.** Both serving paths work on a `dup` of the
guest's descriptor, and closing one descriptor leaves the socket open - so a
Mac-side detach reported success, released the device, and left `vhci_hcd`
listing it in `VDEV_ST_USED` with nothing behind it. `shutdown` acts on the
socket however many descriptors share it. The native tier was always right
by accident (`USBIPServer.stop()` shuts down); the relay tier was not.

**`HostUSBDevice` - the half that talks to real hardware - is not
verified.** No USB device has ever been attached to the machine this was
developed on; `ioreg -p IOUSB` shows only the two root XHCI controllers.
Every IOUSBHost call in it was checked against the real headers and against
the compiler, but nothing has answered one. Treat control transfers,
bulk/interrupt pipes and configuration changes as untested code.

It does intercept the control requests that must not reach the wire, the way
the kernel's own stub does in `tweak_special_requests()`: SET_ADDRESS (macOS
owns the address), SET_CONFIGURATION and SET_INTERFACE (IOUSBHost rebuilds
its pipes, and `selectAlternateSetting` invalidates every pipe it had handed
out - alternate settings are how DFU picks a flash region, so this one is in
the middle of every firmware write), and CLEAR_FEATURE(ENDPOINT_HALT)
(IOUSBHost tracks the stall itself, so forwarding it raw would leave its pipe
stalled after the hardware had moved on). A **port reset** is not
intercepted: usbip encodes it as a vendor convention rather than a standard
request, and guessing at the encoding was not worth it without a device to
check against - `device.reset()` is where it should go.

Three gaps in it are known rather than merely untested, and all want a real
device before they are worth fixing properly:

- **`cancel(seqnum:)` does nothing.** IOUSBHost aborts per *endpoint*, not
  per URB, so dropping one request would cancel unrelated transfers in
  flight. The server answers the guest's `CMD_UNLINK` itself and discards
  the late reply, so the protocol stays correct - but a pending IN read
  stays pending on the Mac. Every USB-serial `close()` unlinks a read, so
  that read can consume the device's next bytes and lose them after a
  reopen. In the target use case that is data loss, and the honest fix is
  per-endpoint aborts on unlink.
- **Bulk and interrupt transfers use timeout 0 (never).** Right for an
  interrupt endpoint that may legitimately wait minutes, and it is what
  leaves the stale read above.
- **No sticky re-attach.** A flasher resets its device and it re-enumerates,
  often with a different product ID; the interest handler then ends the
  attachment part-way through a write. Keeping the attach keyed on
  `locationID` and re-attaching on arrival - `USBDeviceWatcher` already
  reports arrivals - is what makes flashing survive that, and it is the next
  thing worth building for the hardware this is aimed at.

Two smaller things the capture tier gets right, both learned the dull way:
`serve-relay` connects to mslhd **before** opening the device, so a password
typed after the two-minute handshake timeout does not kick macOS's driver off
a device only to put it straight back; and when the plan's driver is mass
storage, `msl usb attach` says "eject it in Finder first" *before* the
password, because `.deviceCapture` on a mounted volume is a forced unmount
and "Disk not ejected properly" is the most alarming thing MSL could do
without warning.

## Entitlements: what was actually measured

The old version of this file left open whether ad-hoc signing is enough for
`com.apple.vm.device-access`, "the way it turned out to be for
`com.apple.security.virtualization`". It is not, and the failure is not a
polite one:

| Entitlement, ad-hoc signed | Result |
|---|---|
| `com.apple.security.virtualization` | works (MSL ships this) |
| `com.apple.vm.device-access` | **SIGKILL at exec** (exit 137) |
| `com.apple.developer.accessory-access.usb` | **SIGKILL at exec** (exit 137) |

`codesign` embeds either one happily and `codesign -vvv` calls the result
valid - the signature is well-formed, it is just not *entitled*, and the
kernel kills the process rather than denying the one API. So a restricted
entitlement cannot be worked around, and signing a binary with one makes it
strictly worse than not signing it at all.

### Why that does not matter

`IOUSBHostObjectInitOptionsDeviceCapture` - the option that takes a device
away from macOS's own driver - documents the way out, in
`IOUSBHostDefinitions.h`:

> Callers must have the "com.apple.vm.device-access" entitlement and the
> IOUSBHostDevice IOService object needs to have successfully been
> authorized by IOServiceAuthorize(). **If the caller has root privileges
> the entitlement and authorization is not needed.**

So there are two tiers, and MSL uses whichever it can get:

- **plain open** - no entitlement, no root. Should reach any device macOS
  has no driver bound to.
- **capture** - root. Should reach anything, including a device macOS has
  already claimed. On `destroy` the device is reset and macOS's drivers are
  re-registered, so it goes back to the Mac by itself.

**The no-root tier is narrower than it sounds.** An earlier draft of this
file said plain open covers "dev boards, USB-serial adapters, custom
hardware". That is wrong about the first two, which are the obvious
candidates: macOS ships drivers for all the common bridge chips -
`com.apple.DriverKit-AppleUSBFTDI.dext`,
`com.apple.DriverKit-AppleUSBCHCOM.dext` (CH34x),
`com.apple.DriverKit-AppleUSBSLCOM.dext` (CP210x),
`com.apple.DriverKit-AppleUSBPLCOM.dext` (Prolific), plus
`AppleUSBACM.kext` and `AppleUSBCDC.kext` for anything speaking CDC-ACM,
and `IOUSBMassStorageDriver.kext` for storage. So a typical Arduino, ESP32
or USB-serial cable is **already claimed at the interface level** and needs
capture, which needs root, which needs a helper that is not written yet.

Plain open is for genuinely unclaimed hardware: a raw vendor-specific
device, a WinUSB-style board, a programmer or dongle with no macOS driver.
`msl usb list` says which it is for a given device, so nobody has to guess.
Both tiers are **unverified against hardware** regardless - see above.

`USBDriverProbe` is what decides. It walks the device's children in the
IOService plane and counts a driver on an **interface** as a claim, not just
one on the device: a plain open of the device can succeed while macOS holds
its interfaces, and MSL would then attach a device whose endpoints never
work. `AppleUSBHostCompositeDevice` is excluded, because it publishes a
composite device's interfaces and steps aside - that exclusion is reasoning
about what the driver is for, not a measurement, and is the first thing to
re-check against real hardware. The pure `classify()` half is split from the
IOKit walk and unit-tested, since the walk needs hardware and the decision
does not.

mslhd runs as the user, not as root (it is a LaunchAgent -
`~/Library/LaunchAgents/com.msl.mslhd.plist`), which is why the capture tier
escalates into `msl-usbd` instead. See "Two tiers" above. Making it work needs a small root helper that the
pkg installs as a LaunchDaemon, with mslhd passing it the guest's vsock fd
over `SCM_RIGHTS` - mslhd owns the `VZVirtioSocketDevice` and macOS has no
host-side `AF_VSOCK`, so a root helper cannot reach the guest on its own.
That helper is **not written yet**, and it must check `getpeereid` so that
only the console user can ask a root service to pull hardware off the Mac.

### VZUSBPassthroughDevice is a dead end here

macOS 27 ships `VZUSBPassthroughDeviceConfiguration`, which would hand a
device to a VM with no USB/IP at all. It takes an `AAUSBAccessory`, and
`AAUSBAccessoryManager` needs `com.apple.developer.accessory-access.usb` -
restricted, per the table above. Unentitled, registering a listener fails
with `AAErrorDomain code=1, "Unable to communicate with service."`; ad-hoc
entitled, the process is killed. It also wants to run from "an ordinary
application, that is, one that appears in the Dock", because it presents a
consent picker. USB/IP over vsock is the architecture precisely because it
is not gated on any of this.

## The guest side needs nothing rebuilt

Every image MSL ships already has what this requires, and none of it is
loaded at boot:

- `vhci_hcd`, `usbip_core` as modules under
  `/lib/modules/6.18.54-0-lts/kernel/drivers/usb/usbip/`
- a writable `/sys/devices/platform/vhci_hcd.0/attach` with free ports
- a C compiler

`usbip`'s userspace tools are *not* present and are not needed.
`Guest/init/usbattach.c` is compiled in the guest on first use from the
copy inside MSL.app's `GuestKit`, exactly as `GuestShellUpgrade` delivers
`shellinit`.

### vhci_hcd accepts a vsock fd

This was the one real unknown, since `vhci_hcd`'s `attach` was written for
TCP. It does:

```
vhci_hcd vhci_hcd.0: pdev(0) rhport(0) sockfd(4)
vhci_hcd vhci_hcd.0: devid(1) speed(3) speed_str(high-speed)
vhci_hcd vhci_hcd.0: Device attached
```

Tested first in isolation with a vsock *loopback* pair inside one guest, so
the kernel's acceptance of the fd was established before any Mac-side
server existed.

## Why there is no connection phase

USB/IP's handshake (`OP_REQ_DEVLIST`, `OP_REQ_IMPORT`) exists so a client
can discover and import a device over a network it does not control. MSL
owns both ends: the guest helper connects and writes the already-connected
fd straight into `attach`, so `vhci_hcd` starts sending `CMD_SUBMIT`
immediately. Only the URB phase crosses the wire.

That is also why pairing is a queue rather than a handshake. An attach is
always host-initiated - the Mac promises a device to `USBBridge`, then tells
the guest to come and collect it - so a connection arriving on port 5012 is
always the answer to a request MSL just made. There is nowhere to put an
identifying preamble: `vhci_hcd` would read it as a URB header.

## Lifetime

A captured device must never outlive the guest holding it, or it belongs to
nobody until it is physically replugged.

- guest detaches, or the socket breaks → `USBIPServer` calls
  `backend.teardown()`
- instance stops → `USBBridge.stop()` tears down every live server and every
  device still waiting in the queue
- **hibernate** → the VM is rebuilt on restore, so attachments are released.
  The guest sees a clean `usb 1-1: USB disconnect`, the vhci ports return to
  free, and a fresh `msl usb attach` works immediately. Verified.
- **suspend/resume** → attachments are *kept*. `resumeAfterVMUp` runs on a
  plain resume as well as a cold boot, and on that path the socket device is
  the same object - so `startUSBBridge()` rebuilds only when the device
  really is new. Without that check an ordinary suspend released every
  passed-through device (measured: two attached test devices vanished, both
  ports back to free). This matters more than it looks: mslhd auto-pauses a
  guest a few seconds after the last session closes.

## msl-usbd

The diagnostic CLI for the host-side pieces, not shipped in MSL.app.

```
msl-usbd list                                 # enumerate
msl-usbd watch                                # arrivals and removals
msl-usbd open <locationID hex>                # claim one, print its descriptor
msl-usbd serve-relay <device> --connect <s>   # the privileged half (msl usb attach starts this)
msl-usbd serve <device> --tcp <port>          # serve over TCP, for development
msl-usbd serve-synthetic --tcp <port>         # ...with the synthetic device
```

It *is* shipped now - `build-app.sh` and `HostToolInstaller` both carry it,
because `msl usb attach` has to be able to start it under sudo. Deliberately
**not** in `entitledTools`: it is the one tool that runs as root, and signing
it with `com.apple.vm.device-access` would get it SIGKILLed at exec.

The `--tcp` modes exist for iterating on the wire format: production carries
USB/IP over vsock from inside mslhd, and rebuilding the whole app per byte of
protocol is unworkable. A guest can reach the Mac on its NAT gateway
(192.168.64.1), so the identical `USBIPServer` is served over TCP instead and
`msl-usbattach` takes `--tcp <host> <port>`. They are **not** the production
path - see "The root half never touches the guest" for why that matters.
`MSL_USBIP_TRACE=1` logs every URB.

## NS_REFINED_FOR_SWIFT, again

Worth keeping from the old notes, because it cost time twice. IOUSBHost is
heavily `NS_REFINED_FOR_SWIFT`, and with no Swift overlay those methods
import with a **double-underscore** name. The friendly name Swift suggests
is a stub marked `@available(*, unavailable)` - a steering message, not an
overload. Calling the wrong one and reading the compiler's error is the
fastest way to find the real declaration:

- `IOUSBHostDevice(__ioService:options:queue:interestHandler:)`
- `device.__enqueue(_:data:completionTimeout:completionHandler:)` - note
  *not* `__enqueueDeviceRequest`, which is what the Objective-C selector
  says
- `device.__configure(withValue:matchInterfaces:)`, taking `Int`
- `interface.copyPipe(withAddress:)` and
  `pipe.enqueueIORequest(with:completionTimeout:completionHandler:)` are
  *not* refined - they take `error:` and so import as throwing
- `kIOUSBPipeStalled` no longer exists in the SDK (it lived in IOKit's
  legacy `USB.h`); IOUSBHost still reports the value, so `HostUSBDevice`
  spells out `iokit_usb_err(0x60)` = `0xe0004060`

## Entitlements files: keep comments short

`codesign`'s embedded-entitlements parser (`AMFIUnserializeXML`) is
stricter than the plist format. `plutil -lint` can pass a file that
`codesign` rejects with `AMFIUnserializeXML: syntax error near line N`; a
long multi-paragraph comment caused exactly that, and trimming it fixed it.
