/* Layer 0: pixmaps + PutImage + CopyArea, covering both the plain
 * depth-24 (opaque, no alpha channel) and depth-32 (ARGB, premultiplied
 * alpha) wire formats mslgd's handlePutImage distinguishes.
 *
 * Raw pixel buffers are built by hand (not via XCreateImage's default
 * visual masks, which have no alpha concept) so each pixel's exact wire
 * bytes - and therefore the request's `depth` field - are fully
 * controlled: B,G,R,pad for depth 24; B,G,R,A for depth 32, matching the
 * LSBFirst/0x00RRGGBB layout X11ConnectionSetup advertises.
 *
 * The depth-32 region is pre-filled with solid black before the
 * semi-transparent PutImage so the expected composited color is exact
 * (source-over against a zero destination is just the premultiplied
 * source color, no fractional rounding to account for) - this is the
 * direct regression test for the depth-32 premultipliedFirst alpha fix.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

static XImage *make_raw_image(Display *dpy, int depth, int w, int h, unsigned char *buf) {
    return XCreateImage(dpy, DefaultVisual(dpy, DefaultScreen(dpy)), depth, ZPixmap, 0,
                         (char *)buf, w, h, 32, w * 4);
}

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 200, 150, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    GC gc = XCreateGC(dpy, win, 0, NULL);

    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 0, 0, 200, 150);

    /* --- Part 1: depth-24 pixmap round trip (CreatePixmap + PutImage +
     * CopyArea), opaque orange top half / teal bottom half. --- */
    const int pw = 60, ph = 50;
    unsigned char *buf24 = malloc((size_t)pw * ph * 4);
    for (int y = 0; y < ph; y++) {
        for (int x = 0; x < pw; x++) {
            unsigned char *px = buf24 + (y * pw + x) * 4;
            if (y < ph / 2) { px[0] = 0x00; px[1] = 0x7F; px[2] = 0xFF; px[3] = 0x00; } /* orange */
            else            { px[0] = 0x80; px[1] = 0x80; px[2] = 0x00; px[3] = 0x00; } /* teal */
        }
    }
    XImage *img24 = make_raw_image(dpy, 24, pw, ph, buf24);
    Pixmap pm = XCreatePixmap(dpy, win, pw, ph, 24);
    XPutImage(dpy, pm, gc, img24, 0, 0, 0, 0, pw, ph);
    XCopyArea(dpy, pm, win, gc, 0, 0, pw, ph, 10, 10);
    XFreePixmap(dpy, pm);
    XDestroyImage(img24); /* also frees buf24 */

    /* --- Part 2: depth-32 ARGB PutImage straight onto the window, over a
     * known solid-black backdrop - regression test for the premultiplied-
     * alpha depth-32 fix. Alpha=128, premultiplied RGB=(100,60,20). --- */
    XSetForeground(dpy, gc, 0x00000000);
    XFillRectangle(dpy, win, gc, 110, 10, pw, ph);

    unsigned char *buf32 = malloc((size_t)pw * ph * 4);
    for (int i = 0; i < pw * ph; i++) {
        unsigned char *px = buf32 + i * 4;
        px[0] = 20; px[1] = 60; px[2] = 100; px[3] = 128; /* B,G,R,A */
    }
    XImage *img32 = make_raw_image(dpy, 32, pw, ph, buf32);
    XPutImage(dpy, win, gc, img32, 0, 0, 110, 10, pw, ph);
    XDestroyImage(img32); /* also frees buf32 */

    /* --- Part 3: depth-8 PutImage (1 byte/pixel, rows padded to a 4-byte
     * boundary per X11's scanline-pad=32 convention) straight onto the
     * window. Regression test for `handlePutImage` unconditionally
     * assuming 4 bytes/pixel regardless of `depth`: every depth-8 upload
     * (this is exactly the wire shape GDK/cairo's antialiased text path
     * uses for glyph coverage masks - see `handlePutImage`'s own doc
     * comment) failed its byte-count check and got silently dropped,
     * confirmed live as why a second typed calculator digit's glyph never
     * appeared even though the keystroke itself was delivered correctly.
     * Width 17 (not a multiple of 4) deliberately exercises the row-
     * padding math, not just the common case. A plain `XCreateImage` at
     * depth 8 already builds a correctly-padded/1-byte-per-pixel buffer
     * (unlike Parts 1/2 above, which hand-build depth 24/32 buffers to
     * control the alpha byte exactly) - no `make_raw_image` needed here. */
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 10, 70, 80, 40);

    const int gw = 17, gh = 6;
    /* Xlib's own `XCreateImage` (bytes_per_line=0 below) computes a
     * ROW STRIDE padded to a 4-byte boundary per X11's scanline-pad=32
     * convention - `(gw + 3) & ~3` = 20, not `gw` = 17 - and reads
     * `image->data` at THAT stride when marshalling the wire request,
     * regardless of how the buffer itself was allocated. A tightly-
     * packed `malloc(gw * gh)` (17*6=102 bytes) is 18 bytes short of
     * the 120 Xlib actually reads (6 rows * 20-byte stride) - a real,
     * genuinely non-deterministic client-side heap-OOB-read bug (not a
     * server bug: confirmed by hand-deriving `buf8[100]`/`buf8[101]`
     * against the OLD tightly-packed indexing and finding they exactly
     * predicted the previously "mysteriously flaky" pixel values this
     * test kept showing at (33-35,85) - reading validly-in-bounds but
     * WRONG-ROW data for every row after the first, and genuine
     * uninitialized heap garbage for the tail of the last row, which is
     * exactly why only that specific spot varied between builds/runs).
     * `buf24`/`buf32` above never hit this since 4 bytes/pixel is
     * already a multiple of 4 - this is the first non-4-aligned width
     * in this file. Fix: allocate (and index) at the real padded
     * stride, matching what any real client's glyph-mask buffer does. */
    const int gstride = (gw + 3) & ~3;
    unsigned char *buf8 = malloc((size_t)gstride * gh);
    for (int y = 0; y < gh; y++) {
        for (int x = 0; x < gw; x++) {
            /* A diagonal gradient - not a solid fill, so a byte-count/
             * row-padding bug (reading garbage into wrong rows) would
             * show up as a visibly wrong pattern, not just "blank". */
            buf8[y * gstride + x] = (unsigned char)((x * 255) / (gw - 1));
        }
    }
    XImage *img8 = XCreateImage(dpy, DefaultVisual(dpy, screen), 8, ZPixmap, 0,
                                 (char *)buf8, gw, gh, 32, 0);
    /* This core-protocol `PutImage` handler draws the raw bytes as a
     * plain grayscale image (no GC color involved) - a client wanting a
     * TINTED coverage mask composites it separately via RENDER, which is
     * exactly what `handleRenderCompositeGlyphs8`'s own A8 branch does;
     * this test only exercises the `PutImage` byte-layout fix itself. */
    XPutImage(dpy, win, gc, img8, 0, 0, 20, 80, gw, gh);
    XDestroyImage(img8); /* also frees buf8 */

    XFlush(dpy);
    usleep(300 * 1000);

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
