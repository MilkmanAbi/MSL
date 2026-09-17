/* Phase 3 step 3 of cage-planning.md: the guest side of host->guest input
 * injection, DELIBERATELY a separate binary/connection from `cagebridge.c`
 * (the guest->host frame stream), not a bidirectional extension of it -
 * per the advisor's own reasoning (recorded in cage-planning.md): a
 * 1280x720x4 frame is 3.6MB against vsock socket buffers of tens of KB,
 * so under sustained streaming `cagebridge`'s `write_all` blocks *inside*
 * its Wayland event callback - a single-threaded client stuck mid-frame-
 * write cannot also service an input fd, no matter how it's polled. Two
 * independent binaries on two independent ports (`cagebridge` on 5004,
 * this on 5005) sidesteps the problem entirely - same shape the codebase
 * already uses elsewhere (`grim`/`wtype` are separate binaries; `mslhd`
 * already runs `DisplayBridge`/`X11Server`/`CageBridge` as independent
 * listeners on independent ports).
 *
 * Binds `wl_seat` + `zwp_virtual_keyboard_manager_v1` +
 * `zwlr_virtual_pointer_manager_v1` (both CONFIRMED present via
 * `wayland-info` against a live cage session, 2026-09-03 - wlroots
 * implements both, but whether a given compositor instantiates the
 * manager is a per-compositor choice, so this was checked rather than
 * assumed), then blocks reading fixed-size commands from the host and
 * injecting them. No Wayland *events* are needed back (this client never
 * reads its own input back), so unlike `cagebridge.c`/`02_input_
 * roundtrip.c` there's no dispatch loop here - just synchronous
 * request-then-flush per command.
 *
 * Wire format (host->guest, one 20-byte fixed command per injected
 * event, symmetric in SIZE only with `cagebridge.c`'s frame header - a
 * completely different, unrelated meaning):
 *   struct { uint32_t type, a, b, c, d; }
 *   type 1 (KEY):            a=keycode (evdev, e.g. KEY_A=30), b=state (0/1)
 *   type 2 (POINTER_MOTION):  a=x, b=y, c=x_extent, d=y_extent (absolute)
 *   type 3 (POINTER_BUTTON):  a=button (e.g. BTN_LEFT=0x110), b=state (0/1)
 *
 * The virtual keyboard protocol REQUIRES a keymap to be set before any
 * `key` request (a `no_keymap` protocol error + disconnect otherwise -
 * stated explicitly in `virtual-keyboard-unstable-v1.xml`'s own error
 * enum) - compiled here with libxkbcommon (a real "us" layout, not a
 * stub) and handed over via a memfd, the same pattern `wl_shm` buffers
 * already use elsewhere in this project's Wayland clients.
 */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include <xkbcommon/xkbcommon.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <time.h>
#include <linux/vm_sockets.h>

#define DEFAULT_VSOCK_PORT 5005
#define CMD_KEY 1
#define CMD_POINTER_MOTION 2
#define CMD_POINTER_BUTTON 3

struct input_command {
    uint32_t type, a, b, c, d;
};

struct state {
    struct wl_seat *seat;
    struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
    struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
    struct zwp_virtual_keyboard_v1 *keyboard;
    struct zwlr_virtual_pointer_v1 *pointer;
};

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* Same retry shape as `cagebridge.c`'s `connect_to_host` - see its own
 * comment for why a bounded retry (not one-shot) matters here: this
 * dials out once at startup, so it can plausibly race the host's own
 * `startCageInputBridge` control request registering the listener. */
static int connect_to_host(unsigned int vsock_port) {
    for (int attempt = 0; attempt < 20; attempt++) {
        int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (fd < 0) { perror("socket"); return -1; }
        struct sockaddr_vm addr;
        memset(&addr, 0, sizeof(addr));
        addr.svm_family = AF_VSOCK;
        addr.svm_cid = VMADDR_CID_HOST;
        addr.svm_port = vsock_port;
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) return fd;
        close(fd);
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 250 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    return -1;
}

static int read_all(int fd, void *buf, size_t len) {
    unsigned char *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

/* A real "us" layout, not a stub keymap - compiled once at startup and
 * handed to the compositor via `zwp_virtual_keyboard_v1.keymap`, which
 * MUST happen before any `key` request per the protocol's own `no_keymap`
 * error. */
static void set_keymap(struct state *st) {
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx) { fprintf(stderr, "xkb_context_new failed\n"); exit(1); }
    struct xkb_rule_names names = { .rules = NULL, .model = NULL, .layout = "us", .variant = NULL, .options = NULL };
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) { fprintf(stderr, "xkb_keymap_new_from_names failed\n"); exit(1); }
    char *keymap_str = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t keymap_size = strlen(keymap_str) + 1;

    int fd = memfd_create("keymap", 0);
    if (fd < 0) { perror("memfd_create"); exit(1); }
    if (ftruncate(fd, (off_t)keymap_size) < 0) { perror("ftruncate"); exit(1); }
    void *ptr = mmap(NULL, keymap_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) { perror("mmap"); exit(1); }
    memcpy(ptr, keymap_str, keymap_size);
    munmap(ptr, keymap_size);

    zwp_virtual_keyboard_v1_keymap(st->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)keymap_size);
    close(fd);
    free(keymap_str);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                             const char *interface, uint32_t version) {
    struct state *st = data;
    if (strcmp(interface, "wl_seat") == 0) {
        st->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, "zwp_virtual_keyboard_manager_v1") == 0) {
        st->keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    } else if (strcmp(interface, "zwlr_virtual_pointer_manager_v1") == 0) {
        st->pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}
static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_global_remove
};

int main(int argc, char **argv) {
    unsigned int vsock_port = DEFAULT_VSOCK_PORT;
    if (argc > 1) vsock_port = (unsigned int)atoi(argv[1]);

    /* Without this, the far end (CageBridge on the host, or a dropped
     * connection) closing mid-write kills this process with an opaque
     * signal and no diagnostic - the exact failure `cagebridge.c` hit
     * getting Phase 3 step 2 working (see cage-planning.md). Ignoring it
     * makes `write()` return -1/EPIPE instead, which this file's own
     * read/write error handling already treats as "connection over." */
    signal(SIGPIPE, SIG_IGN);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }

    struct state st = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &st);
    wl_display_roundtrip(display);

    if (!st.seat || !st.keyboard_manager || !st.pointer_manager) {
        fprintf(stderr, "missing a required global (seat=%p keyboard_manager=%p pointer_manager=%p)\n",
                (void *)st.seat, (void *)st.keyboard_manager, (void *)st.pointer_manager);
        return 1;
    }

    st.keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(st.keyboard_manager, st.seat);
    set_keymap(&st);
    st.pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(st.pointer_manager, st.seat);
    wl_display_roundtrip(display);

    int vsock_fd = connect_to_host(vsock_port);
    if (vsock_fd < 0) {
        fprintf(stderr, "couldn't connect to host on vsock port %u after retries\n", vsock_port);
        return 1;
    }
    fprintf(stderr, "cageinput ready, connected on port %u\n", vsock_port);

    struct input_command cmd;
    while (read_all(vsock_fd, &cmd, sizeof(cmd)) == 0) {
        switch (cmd.type) {
        case CMD_KEY:
            zwp_virtual_keyboard_v1_key(st.keyboard, now_ms(), cmd.a, cmd.b);
            break;
        case CMD_POINTER_MOTION:
            zwlr_virtual_pointer_v1_motion_absolute(st.pointer, now_ms(), cmd.a, cmd.b, cmd.c, cmd.d);
            zwlr_virtual_pointer_v1_frame(st.pointer);
            break;
        case CMD_POINTER_BUTTON:
            zwlr_virtual_pointer_v1_button(st.pointer, now_ms(), cmd.a, cmd.b);
            zwlr_virtual_pointer_v1_frame(st.pointer);
            break;
        default:
            fprintf(stderr, "unknown command type %u, ignoring\n", cmd.type);
            continue;
        }
        wl_display_flush(display);
    }

    fprintf(stderr, "input connection closed, exiting\n");
    close(vsock_fd);
    wl_display_disconnect(display);
    return 0;
}
