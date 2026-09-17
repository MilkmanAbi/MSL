# Assets

The original artwork, kept in the repository so MSL does not depend on a
folder on one person's Desktop.

| File | What it is | Where it ends up |
|---|---|---|
| `App_Logo.png` | The melon. MSL's logo. | The Dock and Finder icon (via `MSL.icns`), the About window, and the fallback icon for a Linux app that ships none |
| `Mascot.png` | The little guy, by neekocat_2025 | The About window |
| `Abi_Logo-Light.png` | Abi's mark, black ink | The About window, on a light background |
| `Abi_Logo-Dark.png` | The same mark, white ink | The About window, on a dark background |
| `License.md` | The GNU GPL v3 text, despite the neutral name | Shown in the About window's Licence pane |

## This folder is the source of truth

The files here are copied, not linked, into the places the build actually
reads from:

- `Sources/MSLApp/Resources/` - everything the About window shows
- `Sources/MSLCore/Resources/App_Logo.png` - the melon again, because
  `LinuxAppBundle` needs it from the CLI as well as the GUI
- `Resources/MSLApp/MSL.icns` - generated from `App_Logo.png`

Copies rather than symlinks because SwiftPM copies a symlinked resource into
the built bundle *as a symlink*, with a relative target that no longer
resolves from where it lands - it dangles, silently, and the image is simply
missing at runtime.

So after changing anything here:

```sh
Scripts/sync-assets.sh
```

which re-copies every file and rebuilds the icon. `AssetParityTests` fails
the build if the copies are ever out of step, so this cannot be forgotten
quietly.

## One thing that is not here

`License.md` is the GPL, not the mascot's licence — the About window credits
neekocat_2025 for `Mascot.png`, but the terms they supplied it under are not
in this repository. Worth adding before anyone else redistributes it.
