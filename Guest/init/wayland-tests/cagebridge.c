/* Phase 3 of cage-planning.md: the guest side of the cage/Wayland frame
 * stream. Builds directly on `03_screencopy_loop.c`'s proven persistent
 * `zwlr_screencopy_manager_v1` capture loop (30/30 frames, no stall,
 * confirmed 2026-09-03) - the only new part here is streaming each
 * captured frame out over a vsock connection to the host's `CageBridge`
 * (`Sources/MSLCore/CageBridge.swift`) instead of just printing a line.
 *
 * Connection direction matches `x11tunnel.c`/`DisplayBridge`: the GUEST
 * dials OUT to the host (`VMADDR_CID_HOST`), since it's the guest side
 * that knows when a frame is actually ready to send. Unlike `x11tunnel`
 * (which dials fresh per local X client), this dials ONCE at startup and
 * streams continuously - so launch order matters in a way it doesn't for
 * x11tunnel: if this starts before the host has registered its listener
 * on `cageVsockPort`, the very first `connect()` fails outright (nothing
 * to retry *into* yet). Retries with a short backoff instead of giving up
 * after one attempt, so the harness doesn't have to win a startup race.
 *
 * Wire format - see `CageBridge.swift`'s doc comment for the authoritative
 * description, kept in sync by hand on both sides since this is raw bytes
 * with no schema: a 24-byte header (magic "CAGF", width, height, stride,
 * format, flags - all native-endian uint32) immediately followed by
 * `stride * height` bytes of raw pixel data. Repeated once per frame.
 */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"
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

#define CAGF_MAGIC 0x43414746u /* "CAGF" */
#define DEFAULT_VSOCK_PORT 5004

/* `flags` (added, along with the extra field it's carried in, after
 * Phase 3's first version shipped without it) is the screencopy `flags`
 * event's own bitfield - just `y_invert` (bit 0) today per the protocol
 * XML. NOT checked/interpreted here on purpose: which way is "right side
 * up" is a HOST-side rendering decision (how the received bytes get
 * blitted into an NSView), not something this guest-side bridge should
 * silently correct - passed through opaquely, same policy as `format`. */
struct frame_header {
    uint32_t magic, width, height, stride, format, flags;
};

struct state {
    struct wl_shm *shm;
    struct wl_output *output;
    struct zwlr_screencopy_manager_v1 *screencopy_manager;

    int buf_ready;
    uint32_t format, width, height, stride, flags;
    int flags_logged;
    struct wl_buffer *buffer;
    void *pixels;
    int pixels_size;

    struct zwlr_screencopy_frame_v1 *frame;
    int vsock_fd;
    long num_frames;   /* 0 = unlimited (real streaming mode) */
    long frames_done;
    int failed;
};

/* Blocking, retries a handful of times with a short sleep - the guest
 * bridge can plausibly start racing the host's `startCageBridge()`
 * control request (see this file's header comment), unlike a one-shot
 * `x11tunnel` client dial that can just fail and drop that one X client. */
static int connect_to_host(unsigned int vsock_port) {
    for (int attempt = 0; attempt < 20; attempt++) {
        int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (fd < 0) { perror("socket"); return -1; }

        struct sockaddr_vm addr;
        memset(&addr, 0, sizeof(addr));
        addr.svm_family = AF_VSOCK;
        addr.svm_cid = VMADDR_CID_HOST;
        addr.svm_port = vsock_port;

        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            return fd;
        }
        close(fd);
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 250 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    return -1;
}

static int write_all(int fd, const void *buf, size_t len) {
    const unsigned char *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static void make_buffer(struct state *st) {
    int fd = memfd_create("screencopy-buffer", 0);
    if (fd < 0) { perror("memfd_create"); exit(1); }
    st->pixels_size = st->stride * st->height;
    if (ftruncate(fd, st->pixels_size) < 0) { perror("ftruncate"); exit(1); }
    st->pixels = mmap(NULL, st->pixels_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (st->pixels == MAP_FAILED) { perror("mmap"); exit(1); }

    struct wl_shm_pool *pool = wl_shm_create_pool(st->shm, fd, st->pixels_size);
    st->buffer = wl_shm_pool_create_buffer(pool, 0, st->width, st->height, st->stride, st->format);
    wl_shm_pool_destroy(pool);
    close(fd);
}

static void start_capture(struct state *st);

static void frame_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format,
                          uint32_t width, uint32_t height, uint32_t stride) {
    struct state *st = data;
    if (!st->buf_ready) {
        st->format = format;
        st->width = width;
        st->height = height;
        st->stride = stride;
        make_buffer(st);
        st->buf_ready = 1;
    }
    zwlr_screencopy_frame_v1_copy(frame, st->buffer);
}

static void frame_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {
    struct state *st = data;
    st->flags = flags;
    if (!st->flags_logged) {
        fprintf(stderr, "screencopy flags: 0x%x (y_invert=%d)\n", flags, flags & 1);
        st->flags_logged = 1;
    }
}

/* Only ever called with the PRIOR capture's copy fully complete (this
 * client issues capture_output serially, one at a time, exactly like
 * `03_screencopy_loop.c` - see that file's comment on why reusing one
 * wl_buffer across captures is safe under that invariant and would
 * NOT be if this ever pipelined two captures at once). Sends the header
 * + pixels synchronously before re-arming the next capture, so a slow/
 * stalled vsock write naturally throttles the capture rate rather than
 * piling up frames somewhere. */
static void frame_ready(void *data, struct zwlr_screencopy_frame_v1 *frame,
                         uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
    struct state *st = data;
    zwlr_screencopy_frame_v1_destroy(frame);
    st->frame = NULL;

    struct frame_header hdr = {
        .magic = CAGF_MAGIC, .width = st->width, .height = st->height,
        .stride = st->stride, .format = st->format, .flags = st->flags,
    };
    if (write_all(st->vsock_fd, &hdr, sizeof(hdr)) < 0 ||
        write_all(st->vsock_fd, st->pixels, st->pixels_size) < 0) {
        fprintf(stderr, "vsock write failed, stopping\n");
        st->failed = 1;
        return;
    }

    st->frames_done++;
    if (st->num_frames == 0 || st->frames_done < st->num_frames) {
        start_capture(st);
    }
}

static void frame_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    struct state *st = data;
    fprintf(stderr, "frame %ld: capture FAILED\n", st->frames_done + 1);
    st->failed = 1;
    zwlr_screencopy_frame_v1_destroy(frame);
    st->frame = NULL;
}

static void frame_damage(void *data, struct zwlr_screencopy_frame_v1 *frame,
                          uint32_t x, uint32_t y, uint32_t width, uint32_t height) {}
static void frame_linux_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame,
                                uint32_t format, uint32_t width, uint32_t height) {}
static void frame_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = frame_buffer, .flags = frame_flags, .ready = frame_ready,
    .failed = frame_failed, .damage = frame_damage,
    .linux_dmabuf = frame_linux_dmabuf, .buffer_done = frame_buffer_done,
};

static void start_capture(struct state *st) {
    st->frame = zwlr_screencopy_manager_v1_capture_output(st->screencopy_manager, 0, st->output);
    zwlr_screencopy_frame_v1_add_listener(st->frame, &frame_listener, st);
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                             const char *interface, uint32_t version) {
    struct state *st = data;
    if (strcmp(interface, "wl_shm") == 0) {
        st->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, "wl_output") == 0 && !st->output) {
        st->output = wl_registry_bind(registry, name, &wl_output_interface, 1);
    } else if (strcmp(interface, "zwlr_screencopy_manager_v1") == 0) {
        st->screencopy_manager = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, 1);
    }
}
static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = registry_global, .global_remove = registry_global_remove
};

/* Usage: cagebridge [num-frames [vsock-port]]
 * num-frames: 0 (default) = stream forever until the connection drops or
 * capture fails. A positive count is what the Phase-3-step-2 test harness
 * uses to make a run deterministic/bounded. */
int main(int argc, char **argv) {
    long num_frames = 0;
    unsigned int vsock_port = DEFAULT_VSOCK_PORT;
    if (argc > 1) num_frames = atol(argv[1]);
    if (argc > 2) vsock_port = (unsigned int)atoi(argv[2]);

    /* See cageinput.c's own comment on this - same reasoning: a closed
     * vsock connection killing this process via a raw SIGPIPE, rather
     * than write() returning -1/EPIPE, is the exact opaque failure Phase
     * 3 step 2 hit and had to root-cause through mslhd's trace log (see
     * cage-planning.md). Ignoring it makes the existing "vsock write
     * failed, stopping" error path actually fire instead. */
    signal(SIGPIPE, SIG_IGN);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }

    struct state st = {0};
    st.num_frames = num_frames;

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &st);
    wl_display_roundtrip(display);

    if (!st.shm || !st.output || !st.screencopy_manager) {
        fprintf(stderr, "missing a required global (shm=%p output=%p screencopy_manager=%p)\n",
                (void *)st.shm, (void *)st.output, (void *)st.screencopy_manager);
        return 1;
    }

    st.vsock_fd = connect_to_host(vsock_port);
    if (st.vsock_fd < 0) {
        fprintf(stderr, "couldn't connect to host on vsock port %u after retries\n", vsock_port);
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    start_capture(&st);
    while ((st.num_frames == 0 || st.frames_done < st.num_frames) && !st.failed) {
        if (wl_display_dispatch(display) < 0) {
            fprintf(stderr, "wl_display_dispatch failed\n");
            break;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "streamed %ld frames in %.3fs (%.1f fps)\n", st.frames_done, elapsed,
            elapsed > 0 ? st.frames_done / elapsed : 0.0);

    close(st.vsock_fd);
    wl_display_disconnect(display);
    return (!st.failed && (st.num_frames == 0 || st.frames_done == st.num_frames)) ? 0 : 1;
}
