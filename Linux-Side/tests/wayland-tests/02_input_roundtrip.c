/* Layer 0 (Wayland edition), Phase 2 of cage-planning.md: "a synthetic
 * click/keypress delivered into cage's headless session, confirmed via
 * a changed frame." Renders solid BLACK until a real wl_keyboard `key`
 * (pressed) event arrives, then switches to solid WHITE and keeps
 * running - the harness captures a frame before and after sending a
 * synthetic keypress (via `wtype`) and confirms the color actually
 * changed, the Wayland-side equivalent of this project's whole XI2/
 * crossing-event live-click-testing methodology on the X11 side.
 *
 * `wtype` injects through the `zwp_virtual_keyboard_manager_v1`
 * protocol - a real, separate Wayland extension a compositor must
 * implement for it to work at all (analogous to `XTestFakeKeyEvent` on
 * the X11 side, or this server's own `XIGrabDevice`/XTEST device
 * plumbing) - cage/wlroots ships it, confirmed live by this test
 * actually working end to end.
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
#include <poll.h>

#define WIDTH 200
#define HEIGHT 150

struct state {
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *xdg_toplevel;
    int configured;
    int key_pressed; /* 0 = black (initial), 1 = white (after a real keypress) */
};

static struct wl_buffer *make_solid_buffer(struct wl_shm *shm, uint32_t color) {
    int stride = WIDTH * 4;
    int size = stride * HEIGHT;
    int fd = memfd_create("wl_shm-buffer", 0);
    if (fd < 0) { perror("memfd_create"); exit(1); }
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { perror("mmap"); exit(1); }
    for (int i = 0; i < WIDTH * HEIGHT; i++) pixels[i] = color;
    munmap(pixels, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

static void redraw(struct state *st) {
    struct wl_buffer *buffer = make_solid_buffer(st->shm, st->key_pressed ? 0x00FFFFFF : 0x00000000);
    wl_surface_attach(st->surface, buffer, 0, 0);
    wl_surface_damage_buffer(st->surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(st->surface);
}

/* Triggers on ANY `key` event (press OR release), not just PRESSED -
 * confirmed live via `wev` against this exact cage+wtype combination
 * that a synthetic press from `wtype` doesn't necessarily arrive as
 * its own `wl_keyboard.key` event at all: by the time this surface
 * actually gains keyboard focus, the seat may already consider the key
 * held, and reports it via `wl_keyboard.enter`'s "already pressed
 * keys" array instead (a real, distinct part of the protocol) - only
 * the matching RELEASE then shows up as a normal `key` event. Since
 * this test's actual goal is proving a synthetic input event round-
 * trips into the client at all (not exercising press-vs-release
 * semantics specifically), reacting to whichever one actually arrives
 * is the correct fix, not a workaround. */
static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t time,
                          uint32_t key, uint32_t key_state) {
    struct state *st = data;
    if (!st->key_pressed) {
        st->key_pressed = 1;
        redraw(st);
    }
}
/* Required by the interface but not needed for this test - a keymap is
 * mandatory to ack (real clients feed it to libxkbcommon to interpret
 * `key`'s raw keycode), but this test only cares THAT a key event
 * arrived at all, not which one. */
static void keyboard_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int32_t fd, uint32_t size) { close(fd); }
static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) {}
static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *surface) {}
static void keyboard_modifiers(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t mods_depressed,
                                uint32_t mods_latched, uint32_t mods_locked, uint32_t group) {}
static void keyboard_repeat_info(void *data, struct wl_keyboard *kb, int32_t rate, int32_t delay) {}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap, .enter = keyboard_enter, .leave = keyboard_leave,
    .key = keyboard_key, .modifiers = keyboard_modifiers, .repeat_info = keyboard_repeat_info
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    struct state *st = data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !st->keyboard) {
        st->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(st->keyboard, &keyboard_listener, st);
    }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) {}
static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };

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
    } else if (strcmp(interface, "wl_seat") == 0) {
        st->seat = wl_registry_bind(registry, name, &wl_seat_interface, 5);
        wl_seat_add_listener(st->seat, &seat_listener, st);
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
static const struct xdg_surface_listener xdg_surface_listener_impl = { .configure = xdg_surface_configure };
static void xdg_toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *t) {}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = xdg_toplevel_configure, .close = xdg_toplevel_close
};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }

    struct state st = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &st);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display); /* second roundtrip - lets wl_seat's own capabilities event land too, not just the registry binds themselves */

    if (!st.compositor || !st.shm || !st.wm_base || !st.seat) {
        fprintf(stderr, "missing a required global (compositor=%p shm=%p wm_base=%p seat=%p)\n",
                (void *)st.compositor, (void *)st.shm, (void *)st.wm_base, (void *)st.seat);
        return 1;
    }

    st.surface = wl_compositor_create_surface(st.compositor);
    st.xdg_surface = xdg_wm_base_get_xdg_surface(st.wm_base, st.surface);
    xdg_surface_add_listener(st.xdg_surface, &xdg_surface_listener_impl, &st);
    st.xdg_toplevel = xdg_surface_get_toplevel(st.xdg_surface);
    xdg_toplevel_add_listener(st.xdg_toplevel, &toplevel_listener, &st);
    xdg_toplevel_set_title(st.xdg_toplevel, "wayland-tests-02-input-roundtrip");

    wl_surface_commit(st.surface);
    while (!st.configured) wl_display_dispatch(display);

    redraw(&st); /* initial solid black */
    wl_display_flush(display);

    /* Run the real event loop (not `sleep`) for up to ~8s so a real
     * `key` event actually gets processed and triggers `redraw` - exits
     * as soon as it sees one. `poll()` on the display's own fd, not a
     * plain blocking `wl_display_dispatch`, so this can't hang forever
     * if no key ever arrives - it just falls through once the deadline
     * passes, matching the outer harness's own `timeout` wrapper's
     * spirit instead of relying on it exclusively. Follows libwayland's
     * own documented prepare_read/read_events dance so a stray event
     * that arrived between the last dispatch and this poll() isn't
     * silently missed (a plain poll+dispatch loop has exactly that
     * race). */
    for (int elapsed_ms = 0; elapsed_ms < 8000 && !st.key_pressed; ) {
        while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
        wl_display_flush(display);
        struct pollfd pfd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        int n = poll(&pfd, 1, 100);
        if (n > 0) { wl_display_read_events(display); wl_display_dispatch_pending(display); }
        else { wl_display_cancel_read(display); }
        elapsed_ms += 100;
    }
    /* Stay alive well past the redraw, not just long enough to flush it -
     * cage is a KIOSK compositor that exits the instant its one wrapped
     * app exits, and the harness's own AFTER capture (`grim`, run ~1s
     * after the synthetic keypress) needs the compositor to still be
     * up when it runs. Confirmed live this matters: an earlier version
     * exited within ~300ms of the redraw and made the harness's own
     * grim fail with "failed to create display" - not a capture bug,
     * just this process (and therefore cage) already being gone by
     * the time grim tried to connect. */
    wl_display_flush(display);
    sleep(3);

    xdg_toplevel_destroy(st.xdg_toplevel);
    xdg_surface_destroy(st.xdg_surface);
    wl_surface_destroy(st.surface);
    wl_display_disconnect(display);
    return st.key_pressed ? 0 : 1;
}
