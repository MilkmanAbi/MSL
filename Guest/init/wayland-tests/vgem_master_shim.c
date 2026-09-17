/* Phase "OpenGL investigation" of cage-planning.md - a small LD_PRELOAD
 * shim working around wlroots' headless backend never calling
 * `drmSetMaster()`. Root-caused live (a standalone C test, not
 * guesswork): `vgem`'s `DRM_IOCTL_MODE_CREATE_DUMB` fails with EACCES
 * unless the calling fd has first been made DRM master via
 * `drmSetMaster()`. wlroots' headless backend has no real mode-setting
 * to do, so it never calls it - but vgem's dumb-buffer allocator (the
 * `kms_swrast` software-GL fallback path routes through it) demands
 * master status regardless, and nothing else holds master on this VM.
 *
 * FIRST attempt intercepted `open`/`openat` and called `drmSetMaster()`
 * right after opening `/dev/dri/card*` - didn't fully work: `strace`
 * showed the fd actually used for `DRM_IOCTL_MODE_CREATE_DUMB` wasn't
 * reliably the one that got intercepted (wlroots/Mesa's GBM backend
 * opens/closes/reuses several `/dev/dri` fds - both `card0` and
 * `renderD128` - and `strace` without tracing `close` makes exact fd
 * identity across that churn hard to pin down by open-time alone).
 *
 * This version is more surgical: intercept `ioctl()` itself and call
 * `drmSetMaster(fd)` on whatever fd is about to do
 * `DRM_IOCTL_MODE_CREATE_DUMB` (or `_DESTROY_DUMB`/`_MAP_DUMB`), right
 * at the point of use - sidesteps the whole "which fd is it" tracking
 * problem, since it acts exactly where it matters instead of trying to
 * predict it in advance. Redundant `drmSetMaster()` calls on an
 * already-master fd are harmless (confirmed: it's idempotent), so no
 * bookkeeping needed to avoid repeat calls.
 *
 * Usage: `LD_PRELOAD=/path/to/vgem_master_shim.so cage ...`
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

/* musl's own prototype (sys/ioctl.h) is `int ioctl(int, int, ...)` -
 * matching it exactly, not the more common glibc `unsigned long`, since
 * a mismatched signature is a hard compile error, not just a warning. */
static int (*real_ioctl)(int, int, ...) = NULL;

int ioctl(int fd, int request, ...) {
    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    if (request == DRM_IOCTL_MODE_CREATE_DUMB ||
        request == DRM_IOCTL_MODE_DESTROY_DUMB ||
        request == DRM_IOCTL_MODE_MAP_DUMB) {
        int r = drmSetMaster(fd);
        fprintf(stderr, "[vgem_master_shim] intercepted dumb-buffer ioctl on fd=%d, drmSetMaster=%d (errno=%d %s)\n",
                fd, r, errno, strerror(errno));
    }

    return real_ioctl(fd, request, arg);
}
