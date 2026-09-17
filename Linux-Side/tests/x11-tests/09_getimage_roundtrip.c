/* Layer 0: GetImage (core opcode 73) - regression test for the "unhandled
 * -> BadImplementation" bug found live via `gpick` (a real GTK color-
 * picker app whose whole purpose is sampling on-screen pixel colors).
 *
 * Not a PNG-diff test like the others in this directory - GetImage's
 * whole point is the DATA it returns, not what it draws (it draws
 * nothing), so this asserts real byte values in C and reports PASS/FAIL
 * on stdout instead. Round-trips a distinctive (non-solid - a real
 * per-pixel bug would hide behind a solid fill) depth-24 pattern through
 * PutImage then reads it back with GetImage, checking every pixel
 * matches exactly - this is exactly the shape of bug this server's own
 * top-left-origin CTM flip has bitten before (see `handlePutImage`'s and
 * `X11Drawable`'s doc comments), just on the READ side this time
 * (`handleGetImage` inverts row order by hand, since there's no
 * `CGContext.draw`-based shortcut for a raw buffer readback).
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 100, 80, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    GC gc = XCreateGC(dpy, win, 0, NULL);

    /* A distinctive per-pixel gradient (not solid) at depth 24, so a
     * row-order or coordinate-offset bug on either side of the round
     * trip shows up as a specific wrong pixel, not just "wrong color
     * everywhere" (which a broken-but-constant offset could still pass
     * by accident on a solid fill). */
    const int w = 20, h = 15, x0 = 5, y0 = 5;
    unsigned char *buf = malloc((size_t)w * h * 4);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned char *px = buf + (y * w + x) * 4;
            px[0] = (unsigned char)(x * 10);       /* B */
            px[1] = (unsigned char)(y * 15);       /* G */
            px[2] = (unsigned char)(x * 5 + y * 3); /* R */
            px[3] = 0;                              /* pad */
        }
    }
    XImage *img = XCreateImage(dpy, DefaultVisual(dpy, screen), 24, ZPixmap, 0,
                                (char *)buf, w, h, 32, 0);
    XPutImage(dpy, win, gc, img, 0, 0, x0, y0, w, h);
    XDestroyImage(img); /* also frees buf */
    XFlush(dpy);
    usleep(2000 * 1000); /* let the async PutImage draw actually land before reading it back */

    XImage *readback = XGetImage(dpy, win, x0, y0, w, h, AllPlanes, ZPixmap);
    if (!readback) {
        printf("FAIL: XGetImage returned NULL\n");
        return 1;
    }

    int mismatches = 0;
    for (int y = 0; y < h && mismatches < 5; y++) {
        for (int x = 0; x < w && mismatches < 5; x++) {
            unsigned long got = XGetPixel(readback, x, y);
            unsigned char expectR = (unsigned char)(x * 5 + y * 3);
            unsigned char expectG = (unsigned char)(y * 15);
            unsigned char expectB = (unsigned char)(x * 10);
            unsigned long expect = ((unsigned long)expectR << 16) | ((unsigned long)expectG << 8) | expectB;
            if (got != expect) {
                printf("FAIL: pixel (%d,%d) got=0x%06lx expected=0x%06lx\n", x, y, got, expect);
                mismatches++;
            }
        }
    }

    if (mismatches == 0) {
        printf("PASS: all %d pixels round-tripped exactly\n", w * h);
    }

    XDestroyImage(readback);
    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return mismatches == 0 ? 0 : 1;
}
