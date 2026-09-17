# msl-usbd — USB passthrough, Phase 1

Host-side USB framework groundwork per `msl-platform.md`. Not wired to any
guest yet - no USB/IP-over-vsock transport exists (that's the natural next
step once CLI/guest-integration work resumes). This is the host-side
primitives: enumerate, watch, and claim USB devices via the modern
`IOUSBHost.framework`.

## What's real vs. sketched

**Enumeration and watching (`USBDeviceEnumerator`, `USBDeviceWatcher`) are
verified working on this machine** - `msl-usbd list`/`msl-usbd watch` run
and behave correctly (confirmed against `system_profiler SPUSBDataType`
and `ioreg -p IOUSB`, both showing zero downstream USB devices attached in
this environment - only the root XHCI controllers). Neither needs any
entitlement; they're plain IOKit registry reads.

**Claiming a device (`USBDeviceClaim`, `msl-usbd open`) is code-complete
and compiles against verified real API signatures, but has never been
exercised against actual hardware** - there's no USB device attached in
this environment to test with. Every method call was verified two ways:
against the actual `IOUSBHost.framework` headers on this machine, and by
letting the Swift compiler itself reveal the real signatures (see below) -
not copied from the original design doc's C sample, which was written
blind (no compiler, no headers checked) and undersells what's actually
available.

## The old design doc was wrong about Swift support

`msl-claudecode-handoff.md` says IOKit USB is "C/Objective-C territory - no
Swift bindings for the low-level IOKit USB APIs." That's true of the
*legacy* `IOUSBLib`, but **not** of the modern `IOUSBHost.framework` this
code actually uses - it's a separate, standalone framework (not nested
inside `IOKit.framework`), heavily `NS_REFINED_FOR_SWIFT`/
`NS_SWIFT_UNAVAILABLE` annotated throughout, clearly designed for direct
Swift use.

One real wrinkle worth knowing before touching this code: `NS_REFINED_FOR_SWIFT`
methods import with a **double-underscore-prefixed name** when no
hand-written Swift overlay exists to provide a friendlier one (confirmed
empirically - no such overlay ships for this framework on this SDK). The
"friendly" unprefixed name Swift shows in autocomplete/errors is a stub
marked `@available(*, unavailable, message: "Please use the refined for
Swift API")` - a steering message, not a real alternative. So:

- `IOUSBHostDevice(__ioService:options:queue:interestHandler:)`, not
  `IOUSBHostDevice(ioService:...)`
- `device.__send(_:data:bytesTransferred:completionTimeout:)`, not
  `device.send(...)`
- `device.__string(with:languageID:)`, not `device.string(withIndex:...)`

These were found by deliberately calling the wrong (unavailable) overload
and reading the compiler's own error + note output, which names the real
declaration verbatim - a fast, reliable way to discover the actual API
surface of any `NS_REFINED_FOR_SWIFT` framework without Xcode's
autocomplete. `deviceDescriptor` and other plain `@property` accessors
aren't affected - only methods.

## Entitlement gotcha: XML comments in `.entitlements` files

`codesign`'s embedded-entitlements parser (`AMFIUnserializeXML`) is
stricter than the plist format itself - `plutil -lint` can say a
`.entitlements` file is perfectly valid XML while `codesign` still rejects
it with `AMFIUnserializeXML: syntax error near line N`. Confirmed on a real
attempt: a long multi-paragraph `<!-- -->` comment block caused this
failure; trimming the comment down (matching the length/style of the
working `Resources/MSLApp/MSLApp.entitlements`) fixed it, and a version
with no comment at all also signed cleanly. The exact threshold wasn't
pinned down precisely (didn't seem worth the extra round-trips), but the
practical rule going forward: **keep comments in `.entitlements` files
short**, and if `codesign` ever reports a syntax error on a file
`plutil -lint` says is fine, suspect the comment length first.

## Phase 1 has no separate device blocklist, on purpose

`IOUSBHostDevice`'s own `init` throws if macOS's system driver already owns
the device - which is precisely the built-in keyboard/trackpad and
anything else with a loaded HID/audio/etc. driver. A blocklist on top of
that would either be redundant or actively wrong (blocking a legitimate
external USB keyboard someone actually wants to pass through, which the
natural claim-failure mechanism already prevents at Phase 1 regardless).
See `USBDeviceClaim`'s doc comment for the full reasoning, and
`Sources/MSLUSBDriver/` for Phase 2 (a DriverKit extension that *can*
detach an existing system driver - sketched but not buildable here, needs
Xcode).

## Usage

```
msl-usbd list                    # enumerate attached USB devices
msl-usbd watch                   # watch for arrivals/removals (Ctrl-C to stop)
msl-usbd open <locationID hex>   # claim a device, print its descriptor
```

`open` needs the `com.apple.vm.device-access` entitlement:

```
swift build -c release --product msl-usbd
codesign --force --sign - \
  --entitlements Resources/msl-usbd/msl-usbd.entitlements \
  .build/release/msl-usbd
```

Whether ad-hoc signing is *sufficient at runtime* for this entitlement
(the way it turned out to be for `com.apple.security.virtualization`) is
still unconfirmed - codesign accepts embedding it locally without a real
provisioning profile (verified), but that only proves the signature is
well-formed, not that AMFI/the kernel will actually grant the access at
runtime. That needs a real USB device to test `open` against.
