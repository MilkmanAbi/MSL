/* Layer 1 regression test for a real, previously-confirmed bug: every
 * raw-image `draw(_:in:)` call in mslgd (`PutImage`, `RenderComposite`'s
 * image-src branch, the glyph color-image branch, `X11CanvasView.
 * resize`'s content-preserving copy, and `CopyArea`) needs the SAME
 * counter-flip (`drawImageTopLeftOriented`, see its doc comment in
 * `Sources/MSLCore/X11/X11Drawable.swift`) or content ends up vertically
 * flipped in some combinations but not others, depending on how many
 * such calls a given pixel's content happened to pass through on its
 * way to the screen - `CGContext.draw(_:in:)` carries an extra built-in
 * flip relative to pure path-fill operations that a naive single-call
 * fix can't account for.
 *
 * Exercises all three ways this could go wrong in one image, each half
 * with an asymmetric (never solid) fill so a flip is always visible:
 *  - Pixmap A: filled via `XPutImage`, then `XCopyArea`'d onto the
 *    window (two `draw(_:in:)` calls chained).
 *  - Pixmap B: same size/pattern, filled via cairo/RENDER path-fills
 *    instead, then `XCopyArea`'d the same way (one `draw(_:in:)`, one
 *    pure-CTM path-fill).
 *  - A `PutImage` straight onto the window, no pixmap or `CopyArea`
 *    involved at all (exactly one `draw(_:in:)` call, in isolation).
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <cairo.h>
#include <cairo-xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    int pw = 40, ph = 30;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 100, 100, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);
    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);
    GC gc = XCreateGC(dpy, win, 0, NULL);

    /* Pixmap A: filled via XPutImage, orange TOP half / teal BOTTOM half,
     * then CopyArea'd onto the window at (5,5). */
    Pixmap pmA = XCreatePixmap(dpy, win, pw, ph, 24);
    unsigned char *buf = malloc((size_t)pw * ph * 4);
    for (int y = 0; y < ph; y++) {
        for (int x = 0; x < pw; x++) {
            unsigned char *px = buf + (y * pw + x) * 4;
            if (y < ph / 2) { px[0] = 0x00; px[1] = 0x7F; px[2] = 0xFF; px[3] = 0x00; } /* orange top */
            else            { px[0] = 0x80; px[1] = 0x80; px[2] = 0x00; px[3] = 0x00; } /* teal bottom */
        }
    }
    XImage *img = XCreateImage(dpy, DefaultVisual(dpy, screen), 24, ZPixmap, 0,
                                (char *)buf, pw, ph, 32, pw * 4);
    XPutImage(dpy, pmA, gc, img, 0, 0, 0, 0, pw, ph);
    XDestroyImage(img);
    XCopyArea(dpy, pmA, win, gc, 0, 0, pw, ph, 5, 5);
    XSync(dpy, False);
    usleep(200 * 1000);

    /* Pixmap B: same size, same orange-top/teal-bottom pattern, filled
     * via cairo instead (two rectangle fills, not a solid paint), then
     * CopyArea'd onto the window at (55,5). */
    Pixmap pmB = XCreatePixmap(dpy, win, pw, ph, 24);
    cairo_surface_t *surf = cairo_xlib_surface_create(dpy, pmB, DefaultVisual(dpy, screen), pw, ph);
    cairo_t *cr = cairo_create(surf);
    cairo_set_source_rgb(cr, 1.0, 0x7F / 255.0, 0.0);
    cairo_rectangle(cr, 0, 0, pw, ph / 2);
    cairo_fill(cr);
    cairo_set_source_rgb(cr, 0.0, 0x80 / 255.0, 0x80 / 255.0);
    cairo_rectangle(cr, 0, ph / 2, pw, ph - ph / 2);
    cairo_fill(cr);
    cairo_surface_flush(surf);
    XCopyArea(dpy, pmB, win, gc, 0, 0, pw, ph, 55, 5);
    XSync(dpy, False);
    usleep(200 * 1000);

    /* Direct check: PutImage straight onto the WINDOW (no pixmap, no
     * CopyArea at all) - a single draw(image,in:) call, in isolation,
     * at (5,45). Red top / green bottom. */
    unsigned char *buf2 = malloc((size_t)pw * ph * 4);
    for (int y = 0; y < ph; y++) {
        for (int x = 0; x < pw; x++) {
            unsigned char *px = buf2 + (y * pw + x) * 4;
            if (y < ph / 2) { px[0] = 0x00; px[1] = 0x00; px[2] = 0xFF; px[3] = 0x00; } /* red top */
            else            { px[0] = 0x00; px[1] = 0xFF; px[2] = 0x00; px[3] = 0x00; } /* green bottom */
        }
    }
    XImage *img2 = XCreateImage(dpy, DefaultVisual(dpy, screen), 24, ZPixmap, 0,
                                 (char *)buf2, pw, ph, 32, pw * 4);
    XPutImage(dpy, win, gc, img2, 0, 0, 5, 45, pw, ph);
    XDestroyImage(img2);
    XSync(dpy, False);
    usleep(200 * 1000);

    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    XFreePixmap(dpy, pmA);
    XFreePixmap(dpy, pmB);
    free(buf);
    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
