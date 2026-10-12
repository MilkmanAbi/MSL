/*
 * msl-eglsize.c - LD_PRELOAD shim: keep Mesa's idea of an EGL window's size
 * current, so software-rendered GL apps stop painting only the top of their
 * window.
 *
 * The bug it fixes (traced 2026-09-23 with Krita):
 *
 *   A toolkit creates its top-level window small (Qt: 640x480, before
 *   layout), makes an EGL window surface on it, then resizes the window.
 *   Mesa's X11 swrast path seeds dri2_surf->base.Height from the geometry at
 *   surface creation and clamps every upload to it:
 *
 *       if (y + h > dri2_surf->base.Height) h = base.Height - y;
 *
 *   base.Height is only refreshed when someone asks for it through
 *   eglQuerySurface(EGL_WIDTH/EGL_HEIGHT), and Qt never does. So the window
 *   grows to 912 rows and only the first 480 are ever written again - the
 *   rest keep whatever was drawn there before (Krita: its welcome page).
 *   mslgd answers GetGeometry correctly throughout; it cannot fix this from
 *   its side.
 *
 * The fix: ask. Before every swap, query the surface's size, which makes
 * Mesa re-read the drawable geometry, update base.Width/Height, and
 * invalidate the drawable if it changed. One extra GetGeometry round trip
 * per frame - the same one Mesa's swrast path already makes each frame.
 *
 * Deliberately does NOT link libEGL: the real entry points are looked up at
 * the first swap (see real_symbol), so preloading this into a process that
 * never touches EGL costs nothing and changes nothing. That is what makes it
 * safe to preload into every Linux GUI app MSL launches.
 *
 * Only eglSwapBuffers is wrapped. The damage variants
 * (eglSwapBuffersWithDamageKHR/EXT) are extensions: glvnd's libEGL does not
 * export them, so callers get them from eglGetProcAddress and a symbol here
 * would never be reached - except by something probing the global namespace,
 * which would then get a wrapper with no real function behind it. Qt 5's
 * QEGLPlatformContext::swapBuffers calls plain eglSwapBuffers.
 *
 * Build (in the guest):
 *   gcc -O2 -Wall -Wextra -shared -fPIC -o msl-eglsize.so msl-eglsize.c
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>

/* The EGL types and enums used, declared here so this builds without
 * libegl-dev and never pulls libEGL in at link time. Values are fixed by
 * the EGL 1.4 spec. */
typedef void *EGLDisplay;
typedef void *EGLSurface;
typedef int32_t EGLint;
typedef unsigned int EGLBoolean;
#define MSL_EGL_HEIGHT 0x3056
#define MSL_EGL_WIDTH  0x3057

typedef EGLBoolean (*query_surface_fn)(EGLDisplay, EGLSurface, EGLint, EGLint *);
typedef EGLBoolean (*swap_fn)(EGLDisplay, EGLSurface);
typedef EGLBoolean (*swap_damage_fn)(EGLDisplay, EGLSurface, const EGLint *, EGLint);

/* Finds the REAL libEGL entry point.
 *
 * RTLD_NEXT alone is not enough, and the first version of this shim broke
 * every GL app because of it: Qt's xcb EGL plugin is itself dlopen()ed, and
 * it pulls libEGL in with local scope. A preloaded library searching
 * RTLD_NEXT only sees the global scope, so it found nothing, returned 0,
 * and Qt logged "eglSwapBuffers failed: 3000" (3000 = EGL_SUCCESS - nothing
 * had actually failed) on every frame while the window stopped updating.
 * By the time any swap happens libEGL is loaded, so asking for it by name
 * with RTLD_NOLOAD returns that same copy without loading a second one; a
 * handle lookup searches that library and not this shim, so it can never
 * resolve back to ourselves. */
static void *real_symbol(const char *name) {
    void *sym = dlsym(RTLD_NEXT, name);
    if (sym) return sym;
    void *egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_NOLOAD);
    if (!egl) egl = dlopen("libEGL.so.1", RTLD_NOW);
    return egl ? dlsym(egl, name) : NULL;
}

static void refresh_size(EGLDisplay dpy, EGLSurface surface) {
    static query_surface_fn query;
    if (!query) query = (query_surface_fn)real_symbol("eglQuerySurface");
    if (!query) return;
    EGLint ignored;
    /* Either attribute triggers the refresh; both, to not depend on which
     * one a given Mesa version keys it on. */
    query(dpy, surface, MSL_EGL_WIDTH, &ignored);
    query(dpy, surface, MSL_EGL_HEIGHT, &ignored);
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    static swap_fn real;
    if (!real) real = (swap_fn)real_symbol("eglSwapBuffers");
    refresh_size(dpy, surface);
    return real ? real(dpy, surface) : 0;
}
