# Prebuilt aarch64 guest binaries

For populating a new image that has no compiler yet. Copy into
`/usr/local/bin` and `chmod +x`.

| File | Built | Matches source? |
|---|---|---|
| `shellinit` | 2026-09-03 | probably - `shellinit.c` unchanged since 2026-08-31 |
| `fileopsd` | 2026-09-03 | **NO - stale as of 2026-09-09** |
| `x11tunnel.STALE-pre-announce` | 2026-09-03 | **NO - do not use** |

## Why the fileopsd binary is now stale too

`fileopsd.c` gained three listing fixes on 2026-09-09: `lstat` instead of
`stat` (a dangling symlink used to vanish from the listing silently - a file
plainly visible in `ls` that Finder swore did not exist), skipping names
containing a tab or newline (they broke the field delimiters and corrupted
every entry after them), and rejecting truncated paths. This binary has none
of them.

Building from source is now easy and tested: `provision/provision-msl.sh`
does it, and all three daemons were confirmed compiling clean on aarch64
musl and glibc on 2026-09-09. Prefer that to any file in here.

## Why the x11tunnel binary is marked stale

`x11tunnel.c` gained `--announce` on 2026-09-06: each connecting client now
sends its application name to the host before any X11 traffic, which is what
lets every Linux app get its own Dock tile, icon and name instead of all of
them sharing one. The binary here predates that and was never refreshed on
the host - the working copy was compiled *inside* the Alpine guest and lives
at its `/usr/local/bin/x11tunnel`, which is not reachable right now because
that image won't boot.

Verified rather than assumed: `strings` finds no `announce` or `cmdline` in
this binary, and its build date is three days before the source changed.

**Build `x11tunnel` from `daemons/x11tunnel.c`** (see `daemons/Makefile`).
It has no dependencies beyond libc. The stale copy is kept only so the file
that is currently deployed on the host is accounted for, not because it
should be used.
