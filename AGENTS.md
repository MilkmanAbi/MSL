# AGENTS.md

Notes for AI coding agents working in this repository. Humans are welcome to read them too.

## What this is

MSL runs Linux distributions on macOS in lightweight virtual machines (Apple's Virtualization framework) and tries to make them feel native. Swift Package Manager project, Apple silicon, macOS 14 or later. The user guide is `MSL-HELP.md`; the design notes and history are in `docs/`.

## Layout

| Path | What |
|---|---|
| `Sources/MSLCore/` | Shared library: VM manager, daemon protocol, storage, installer, sandbox, help guide content |
| `Sources/MSLCore/X11/`, `Sources/MSLCore/X11InputGate.swift`, `Sources/mslgui/` | mslgd, the X11 server, and its per-app host process |
| `Sources/MSLApp/` | The SwiftUI Mac app, including MSL Files |
| `Sources/msl/` | The `msl` command line tool |
| `Sources/mslhd/` | The background service that runs every VM |
| `Sources/msl-applauncher/` | The launcher inside generated Linux app bundles |
| `Guest/init/` | C daemons that run inside Linux (shell, file ops, traffic, memory, X11 tunnel) |
| `Linux-Side/` | Guest kit and image build scripts; several files are symlinks into `Guest/init` and `Sources` |
| `Tests/MSLCoreTests/` | Unit tests, all against `MSLCore` |
| `Scripts/` | `build-app.sh`, `build-installer.sh` and helpers |

## Build and test

- `swift build` builds everything; `swift test` runs the unit tests. Keep them passing.
- `Scripts/build-app.sh` makes `dist/MSL.app`; `Scripts/build-installer.sh` makes `dist/MSL-<version>.pkg`.
- Help guide text lives in `Sources/MSLCore/Help/Content/`; the tests check its links and tables. `msl --help` and the guide's Command line chapter share one list in `HelpCommandLine.swift`.

## Rules that have bitten before

- **Never copy a built `mslhd` over the installed one.** It strips the `com.apple.security.virtualization` entitlement and every VM start fails. The app and `HostToolInstaller` install and sign the tools.
- **To run a new build locally:** quit MSL, run `Scripts/build-app.sh`, open `dist/MSL.app` (it installs its tools on launch), then `launchctl kickstart -k gui/$(id -u)/com.msl.mslhd`. Restarting mslhd ends every running shell and app session, so don't do it while someone is using MSL.
- **MSL Files is its own app** (`dist/MSL Files.app`, bundle id `com.msl.files`) but the *same executable*: `Sources/MSLApp/main.swift` picks `MSLApp` or `MSLFilesApp` from the running bundle id (`MSLFilesIdentity`; `MSL_RUN_AS_FILES=1` for unbundled runs). `build-app.sh` builds both; install and `lsregister` both. MSL Files never installs tools (`AppModel.start(installsTools: false)`); reveal links use `msl-files://`, with `msl://files` kept as MSL.app's fallback.
- **`swift test` can create `~/Library/Application Support/MSL`.** Clean it up if you're testing on a Mac that shouldn't have MSL installed.
- **The installer package must stay non-relocatable**, or macOS installs MSL.app over whatever other copy it finds.
- **Never commit disk images** (`*.img`, `*.img.xz`, `*.cpio.gz`) or `dist/`. Images are published separately.
- **Each instance has its own disk** (`InstanceDisk`), an APFS `clonefile` of the distro's downloaded *base* (`rootfs-<distro>.img`). The base is never booted - that is what keeps a new instance a genuinely fresh install. Removing an instance deletes only its own disk; removing a distro takes the base and every instance disk with it. Never boot or write the base, and never clone with `cp -c`/`copyItem` (they silently fall back to a real 20 GB copy).

## Style

- Match the code around you. Comments explain why, not what, and often record the bug that made the code necessary.
- User-facing text is plain, specific and friendly. Kaomoji are part of MSL's voice in the app and docs; don't sprinkle them into code.
- Licensing: mslgd (the paths above) is GPL-3.0, everything else is MIT. Keep code from mslgd out of MIT files unless it's clearly meant to be GPL-3.0.
