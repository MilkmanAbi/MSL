/* Layer 0 (Wayland edition): the from-scratch equivalent of x11-tests'
 * own 01_window_lifecycle.c - a minimal client using raw wl_compositor +
 * wl_shm + xdg_wm_base (no toolkit), deliberately drawing one STATIC,
 * deterministic frame (four solid color quadrants at a known size) and
 * then just idling. See cage-planning.md's Phase 1 ("one static frame
 * round-trip... deliberately that modest in scope").
 *
 * Why a custom client instead of one of Alpine's prebuilt demo clients
 * (weston-simple-shm etc.): tried weston-simple-shm first - it works
 * (a real frame round-tripped through cage's headless backend + grim +
 * the existing guest->host virtiofs share, confirmed by eye), but its
 * pattern is continuously time-animated, not frame-count-locked to a
 * deterministic start - two runs captured at the identical wall-clock
 * delay after launch still differ almost everywhere (confirmed: diffed
 * two real captures, bbox covered nearly the whole 1280x720 frame).
 * That's fine for a first "does the pipe work" check but useless as a
 * byte-exact regression target - a real test needs a client whose
 * output doesn't depend on scheduling jitter at all.
 */
#define _GNU_SOURCE /* memfd_create - musl only exposes it with this defined */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>

#define WIDTH 200
#define HEIGHT 150

struct state {
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *xdg_toplevel;
    int configured;
};

/* Four solid quadrants at known coordinates - a byte-exact regression
 * diff (see pngdiff.py, already proven by the x11-tests suite) can
 * catch a wrong-quadrant/wrong-color/off-by-one bug immediately, the
 * same reasoning 02_gc_primitives.c used on the X11 side. XRGB8888,
 * matching the format this test negotiates below - no alpha byte to
 * get wrong. */
static void fill_pixels(uint32_t *pixels) {
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            uint32_t color;
            if (x < WIDTH / 2 && y < HEIGHT / 2)      color = 0x00FF3333; /* top-left: red */
            else if (x >= WIDTH / 2 && y < HEIGHT / 2) color = 0x0033FF33; /* top-right: green */
            else if (x < WIDTH / 2 && y >= HEIGHT / 2) color = 0x003333FF; /* bottom-left: blue */
            else                                        color = 0x00FFFF33; /* bottom-right: yellow */
            pixels[y * WIDTH + x] = color;
        }
    }
}

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    xdg_wm_base_pong(wm_base, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = { .ping = xdg_wm_base_ping };

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                             const char *interface, uint32_t version) {
    struct state *st = data;
    if (strcmp(interface, "wl_compositor") == 0) {
        st->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    } else if (strcmp(interface, "wl_shm") == 0) {
        st->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, "xdg_wm_base") == 0) {
        st->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(st->wm_base, &wm_base_listener, NULL);
    }
}
static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_global_remove
};

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial) {
    struct state *st = data;
    xdg_surface_ack_configure(xdg_surface, serial);
    st->configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener_impl = {
    .configure = xdg_surface_configure
};

/* No-ops: a kiosk compositor (cage) always forces its one toplevel to
 * whatever size IT wants (fullscreen on the headless output) - a real
 * client would resize its buffer to match, but this test deliberately
 * keeps a fixed WIDTHxHEIGHT buffer and lets cage scale/position it,
 * since the point here is verifying the round-trip pipe, not cage's own
 * layout policy. */
static void xdg_toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *t) {}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = xdg_toplevel_configure, .close = xdg_toplevel_close
};

static struct wl_buffer *make_buffer(struct wl_shm *shm) {
    int stride = WIDTH * 4;
    int size = stride * HEIGHT;
    /* memfd_create - no tmpfile()/O_TMPFILE path dance needed, and no
     * leftover file on disk either. Available in musl (Alpine) same as
     * glibc - a real Linux syscall wrapper, not a glibc extension. */
    int fd = memfd_create("wl_shm-buffer", 0);
    if (fd < 0) { perror("memfd_create"); exit(1); }
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { perror("mmap"); exit(1); }
    fill_pixels(pixels);
    munmap(pixels, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }

    struct state st = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &st);
    wl_display_roundtrip(display); /* let the registry_global callbacks land */

    if (!st.compositor || !st.shm || !st.wm_base) {
        fprintf(stderr, "missing a required global (compositor=%p shm=%p wm_base=%p)\n",
                (void *)st.compositor, (void *)st.shm, (void *)st.wm_base);
        return 1;
    }

    st.surface = wl_compositor_create_surface(st.compositor);
    st.xdg_surface = xdg_wm_base_get_xdg_surface(st.wm_base, st.surface);
    xdg_surface_add_listener(st.xdg_surface, &xdg_surface_listener_impl, &st);
    st.xdg_toplevel = xdg_surface_get_toplevel(st.xdg_surface);
    xdg_toplevel_add_listener(st.xdg_toplevel, &toplevel_listener, &st);
    xdg_toplevel_set_title(st.xdg_toplevel, "wayland-tests-01-static-frame");

    wl_surface_commit(st.surface); /* triggers the initial xdg_surface.configure */
    while (!st.configured) wl_display_dispatch(display);

    struct wl_buffer *buffer = make_buffer(st.shm);
    wl_surface_attach(st.surface, buffer, 0, 0);
    wl_surface_damage_buffer(st.surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(st.surface);
    wl_display_flush(display);

    /* Static on purpose - just keep the connection alive so the
     * compositor has time to actually composite+scan-out the frame
     * before the harness's grim capture runs, then exit. No animation,
     * no timers, no response to input (that's 02_input_roundtrip's job). */
    sleep(3);

    xdg_toplevel_destroy(st.xdg_toplevel);
    xdg_surface_destroy(st.xdg_surface);
    wl_surface_destroy(st.surface);
    wl_display_disconnect(display);
    return 0;
}
