# MSLUSBDriver — Phase 2 DriverKit extension

**Status: compiles, links, signs, and installs a real `.dext` bundle - all
from the command line, no Xcode project file needed.** Activation
currently blocked on one remaining step: system-extension developer mode
needs to be turned on (`sudo systemextensionsctl developer on` + reboot) -
see "What's actually verified" below for the exact error trail that led
here.

Originally written (and left, for a while) as an un-compilable sketch
because no Xcode was installed. Xcode 26.6, `iig`, and SIP-disabled
development mode became available mid-project - this directory is the
result of actually using them, not a rewrite of the sketch's assumptions.

## Build it yourself

```
cd Sources/MSLUSBDriver && ./build.sh          # -> .build-dext/MSLUSBDriver.dext
cd Sources/MSLUSBDriverHost && ./build.sh      # -> .build-app/MSLUSBDriverHost.app (dext embedded)
```

Both scripts are plain `sh`, calling `iig`, `clang++`, and `codesign`
directly - no `.xcodeproj` exists or is needed. Requires a full Xcode
install (`xcode-select -p` must point at `Xcode.app`, not just Command
Line Tools - the DriverKit platform/SDK and `iig` only ship with Xcode).

## What's actually verified (a real build+run log, not a plan)

1. **`iig` needs `-D__IIG=1`, undocumented in `iig --help`.** Without it,
   processing even Apple's own system `.iig` headers fails with parser
   errors on their `KERNEL`/`NATIVE`/`EXTENDS` annotation macros (which
   only resolve correctly when `__IIG` is defined). Found by reading
   Xcode's own build rule for this
   (`.../SWBApplePlatform.framework/.../Iig.xcspec`) rather than guessing -
   it's how Xcode itself invokes `iig` under the hood, flag for flag.
2. **The real generated dispatch shape doesn't match the original
   handoff doc's naive `override` sketch.** `iig` turns `Start`/`Stop` into
   RPC-dispatched methods that call into `Start_Impl`/`Stop_Impl` (via
   `<ClassName>_<Method>_Args` macros for the parameter list) - confirmed
   by actually generating `MSLUSBDriver.h` and reading it, not assumed.
   Calling the superclass's implementation from inside an `_Impl` override
   needs the `SUPERDISPATCH` macro (`OSMetaClass.h`) instead of a plain
   `super::Start(...)` call, since DriverKit dispatch goes through IORPC,
   not a normal C++ vtable. `IMPL`/`DEFN` (the macro-based shorthand some
   older sample code uses) are explicitly marked "discouraged" in Apple's
   own header comment in favor of writing `_Impl` methods directly, which
   is what `MSLUSBDriver.cpp` does.
3. **The entitlement key is `com.apple.developer.driverkit.transport.usb`**
   - verified directly against this SDK's headers
   (`IOKitKeys.h`'s `kIODriverKitUSBTransportEntitlementKey`), not the
   original doc's generic `com.apple.developer.driverkit.userclient-access`
   guess.
4. **A dext cannot be loaded standalone.** It must be embedded in a host
   app's `Contents/Library/SystemExtensions/` and activated via
   `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)`
   from that app (`Sources/MSLUSBDriverHost`) - there's no
   `kextload`-equivalent CLI path. `OSSystemExtensionManager`'s Objective-C
   `sharedManager` class property imports into Swift as plain `.shared`,
   confirmed by it actually compiling.
5. **The host app must live under `/Applications`.** A real activation
   attempt run from a project directory failed immediately with
   `OSSystemExtensionErrorDomain Code=3 "App containing System Extension
   to be activated must be in /Applications folder"`. Copying the same
   `.app` to `/Applications` and retrying moved the failure to a different,
   more specific error.
6. **Developer mode is the remaining blocker**, confirmed by reading
   `sysextd`'s own unified-log output during a real activation attempt
   (`log show --predicate 'process == "sysextd"'`), not guessed from
   Apple's docs: `"Failing to realize com.msl.MSLUSBDriver as the app
   requesting activation isn't in the /Applications folder and
   developer/groundhog mode isn't on"`. By the time this fired the app
   genuinely was already under `/Applications` (verified independently),
   so of that compound condition, developer mode being off is the part
   still failing. Needs `sudo systemextensionsctl developer on` (requires
   an interactive password, can't be run non-interactively) followed by a
   reboot - Apple's own tooling requires both SIP disabled *and* this
   developer-mode flag for a locally ad-hoc-signed dext (no Apple-issued
   DriverKit entitlement) to have any chance of loading.

## What's still not implemented

- **The actual bridge from this dext back to `msl-usbd`** (Phase 1, in
  userspace) across the dext/userspace boundary. Needs a dedicated
  `IOUserClient` this driver vends - real design work for whoever picks
  this up next with real hardware and a loaded extension to iterate
  against, not something worth guessing the shape of blind.
- **Dynamic device matching.** `Info.plist`'s `IOKitPersonalities` entry
  matches any `IOUSBHostDevice`, which is far too broad for a real driver -
  Phase 2 exists specifically to let a user pick an arbitrary
  system-driver-owned device at runtime, and there's no fixed vendor/
  product ID to hardcode. Needs either dynamic matching-dictionary
  generation or aggressive filtering in `Start_Impl`, gated on some future
  MSL-side device-selection flow that doesn't exist yet either.
- **Confirming the extension actually activates and detaches a real
  driver** once developer mode is on - needs a real USB device with an
  existing macOS driver (a webcam, a USB audio interface, etc.) to test
  against, same "no hardware in this environment" caveat as Phase 1's
  `msl-usbd open`.

## Why this is Phase 2, not Phase 1

Phase 1 (`Sources/msl-usbd`, fully working today with no DriverKit
involved) can only claim devices macOS has no existing system driver for -
`IOUSBHostDevice`'s userspace `init` (in `IOUSBHost.framework`, a
completely different framework from this DriverKit one despite the
identical class name) fails cleanly if a driver already owns the device.
This dext exists specifically to detach that existing driver first
(webcams, audio interfaces, USB NICs, HID devices) - see
`msl-platform.md`'s Phase 1/Phase 2 split, and
`Sources/MSLCore/USB/USBDeviceClaim.swift`'s doc comment for why Phase 1
doesn't need or want a separate device-class blocklist on top of this
natural boundary.
