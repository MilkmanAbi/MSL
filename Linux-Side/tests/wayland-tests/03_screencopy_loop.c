/* Phase 3 step 1 of cage-planning.md (per advisor guidance 2026-09-03):
 * prove a PERSISTENT `zwlr_screencopy_manager_v1` client can capture many
 * frames back-to-back by re-arming `capture_output` on each `ready` event,
 * with NO transport and NO host code involved yet. `grim` (used by Phases
 * 1-2) only proves a ONE-SHOT capture works - a persistent client that
 * re-arms `copy()` after each frame is a genuinely different code path
 * (in particular: the prior frame's buffer must be fully done with before
 * the next `capture_output` is issued, or wlroots can stall waiting on it).
 *
 * This test captures NUM_FRAMES frames against `01_static_frame`'s own
 * output (started separately by the harness), reusing ONE persistent
 * wl_buffer sized on the FIRST frame's `buffer` event (screencopy always
 * reports the same format/size for a given output, so allocating once and
 * reusing it - rather than a fresh memfd per frame - is the realistic
 * shape for the eventual streaming bridge, not just this test's shortcut).
 * Prints one line per captured frame with its reported timestamp so the
 * harness (or a human) can confirm frames are actually arriving at a
 * reasonable cadence, not just that N `ready` events eventually fire.
 */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <time.h>

#define NUM_FRAMES 30

struct state {
    struct wl_shm *shm;
    struct wl_output *output;
    struct zwlr_screencopy_manager_v1 *screencopy_manager;

    /* Set from the first frame's `buffer` event, then reused every capture. */
    int buf_ready;
    uint32_t format, width, height, stride;
    struct wl_buffer *buffer;
    void *pixels;
    int pixels_size;

    struct zwlr_screencopy_frame_v1 *frame;
    int frames_done;
    int failed;
};

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

static void frame_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {}

static void frame_ready(void *data, struct zwlr_screencopy_frame_v1 *frame,
                         uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
    struct state *st = data;
    st->frames_done++;
    /* Cheap content signal (not a full checksum) - just prove the pixels
     * aren't literally uninitialized/zeroed every time, i.e. real capture
     * data is arriving, not a stalled/reused-empty buffer. */
    uint32_t first_pixel = st->pixels ? *(uint32_t *)st->pixels : 0;
    printf("frame %d/%d ready: ts=%u.%09u first_pixel=0x%08x\n",
           st->frames_done, NUM_FRAMES, tv_sec_lo, tv_nsec, first_pixel);
    zwlr_screencopy_frame_v1_destroy(frame);
    st->frame = NULL;
    if (st->frames_done < NUM_FRAMES) {
        start_capture(st);
    }
}

static void frame_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    struct state *st = data;
    fprintf(stderr, "frame %d: capture FAILED\n", st->frames_done + 1);
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
    .buffer = frame_buffer,
    .flags = frame_flags,
    .ready = frame_ready,
    .failed = frame_failed,
    .damage = frame_damage,
    .linux_dmabuf = frame_linux_dmabuf,
    .buffer_done = frame_buffer_done,
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

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }

    struct state st = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &st);
    wl_display_roundtrip(display);

    if (!st.shm || !st.output || !st.screencopy_manager) {
        fprintf(stderr, "missing a required global (shm=%p output=%p screencopy_manager=%p)\n",
                (void *)st.shm, (void *)st.output, (void *)st.screencopy_manager);
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    start_capture(&st);
    while (st.frames_done < NUM_FRAMES && !st.failed) {
        if (wl_display_dispatch(display) < 0) {
            fprintf(stderr, "wl_display_dispatch failed\n");
            return 1;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("captured %d frames in %.3fs (%.1f fps)\n", st.frames_done, elapsed,
           st.frames_done / elapsed);

    wl_display_disconnect(display);
    return (st.frames_done == NUM_FRAMES && !st.failed) ? 0 : 1;
}
