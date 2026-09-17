/* Layer 0 regression test for the RANDR, XC-MISC, and SHAPE extensions
 * added while auditing XQuartz's own `mi/miinitext.c` static-extension
 * list for extensions real GTK/Qt apps query that this server didn't
 * implement yet (this server previously only had RENDER, BIG-REQUESTS,
 * XInputExtension, and XKEYBOARD - see gui-bugs.md issue #2's writeup for
 * how those came to exist).
 *
 * RANDR matters because GDK's X11 backend queries it unconditionally at
 * startup for monitor/DPI info (falls back gracefully if absent, so this
 * wasn't a confirmed crash/hang like XI2/XKB were - but XQuartz's own
 * extension list flagged it as present in every real server, worth
 * closing the gap rather than leaving it as an untested "no RANDR"
 * combination). SHAPE matters for GTK/Qt's non-rectangular popups/
 * tooltips (`gtk_widget_shape_combine_region`); this server tracks the
 * shape but doesn't yet enforce it visually - see `handleShapeRequest`'s
 * own doc comment in X11Connection.swift for the concrete follow-up.
 *
 * This test asserts real return VALUES (not just "didn't hang/error",
 * the way 07_clip_rectangles.c did) since both extensions are now real
 * implementations, not silent no-ops: RANDR's screen-resources/output/
 * crtc/monitor graph must describe this server's actual one virtual
 * screen correctly, and SHAPE's rectangle list must round-trip exactly
 * through Set-then-Get. Only draws (and lets the harness pixel-diff) a
 * final green rectangle if every assertion passes - a wrong extension
 * reply fails loudly via stderr + a nonzero exit, a wrong PIXEL result
 * fails via the harness's own diff, so either kind of regression is
 * caught.
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/shape.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } \
} while (0)

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);

    /* --- RANDR --- */
    int rr_event_base, rr_error_base;
    CHECK(XRRQueryExtension(dpy, &rr_event_base, &rr_error_base), "XRRQueryExtension reported absent");

    int rr_major, rr_minor;
    CHECK(XRRQueryVersion(dpy, &rr_major, &rr_minor), "XRRQueryVersion failed");
    CHECK(rr_major == 1 && rr_minor >= 5, "expected RandR >= 1.5");

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, root);
    CHECK(res != NULL, "XRRGetScreenResourcesCurrent returned NULL");
    CHECK(res->ncrtc == 1, "expected exactly 1 crtc");
    CHECK(res->noutput == 1, "expected exactly 1 output");
    CHECK(res->nmode == 1, "expected exactly 1 mode");

    RROutput output = res->outputs[0];
    RRCrtc crtc = res->crtcs[0];

    XRROutputInfo *outInfo = XRRGetOutputInfo(dpy, res, output);
    CHECK(outInfo != NULL, "XRRGetOutputInfo returned NULL");
    CHECK(outInfo->connection == RR_Connected, "expected output to be connected");
    CHECK(outInfo->crtc == crtc, "output's crtc didn't match the one crtc from screen resources");
    CHECK(outInfo->nmode >= 1, "expected output to list at least 1 mode");

    XRRCrtcInfo *crtcInfo = XRRGetCrtcInfo(dpy, res, crtc);
    CHECK(crtcInfo != NULL, "XRRGetCrtcInfo returned NULL");
    int screenW = DisplayWidth(dpy, screen);
    int screenH = DisplayHeight(dpy, screen);
    CHECK((int)crtcInfo->width == screenW, "crtc width didn't match the actual screen width");
    CHECK((int)crtcInfo->height == screenH, "crtc height didn't match the actual screen height");
    CHECK(crtcInfo->noutput == 1, "expected crtc to drive exactly 1 output");

    int nmonitors = 0;
    XRRMonitorInfo *monitors = XRRGetMonitors(dpy, root, True, &nmonitors);
    CHECK(monitors != NULL && nmonitors == 1, "expected exactly 1 monitor from XRRGetMonitors");
    CHECK(monitors[0].primary, "expected the one monitor to be primary");
    CHECK(monitors[0].width == screenW && monitors[0].height == screenH, "monitor geometry didn't match the screen");

    XRRFreeCrtcInfo(crtcInfo);
    XRRFreeOutputInfo(outInfo);
    XRRFreeScreenResources(res);
    XRRFreeMonitors(monitors);

    fprintf(stderr, "RANDR: version %d.%d, 1 output/crtc/mode/monitor, geometry %dx%d - all correct\n",
            rr_major, rr_minor, screenW, screenH);

    /* --- SHAPE --- */
    int shape_event_base, shape_error_base;
    CHECK(XShapeQueryExtension(dpy, &shape_event_base, &shape_error_base), "XShapeQueryExtension reported absent");

    int shape_major, shape_minor;
    CHECK(XShapeQueryVersion(dpy, &shape_major, &shape_minor), "XShapeQueryVersion failed");

    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 150, 100, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);
    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    /* An L-shape: two rectangles, set then read back. */
    XRectangle shapeRects[2] = {
        { 0, 0, 150, 50 },
        { 0, 50, 75, 50 },
    };
    XShapeCombineRectangles(dpy, win, ShapeBounding, 0, 0, shapeRects, 2, ShapeSet, Unsorted);
    XFlush(dpy);
    usleep(100 * 1000);

    int count = 0, ordering = 0;
    XRectangle *gotRects = XShapeGetRectangles(dpy, win, ShapeBounding, &count, &ordering);
    CHECK(gotRects != NULL, "XShapeGetRectangles returned NULL");
    CHECK(count == 2, "expected 2 rectangles back from XShapeGetRectangles");
    /* Order isn't guaranteed by the protocol, so check as a set. */
    int found0 = 0, found1 = 0;
    for (int i = 0; i < count; i++) {
        if (gotRects[i].x == 0 && gotRects[i].y == 0 && gotRects[i].width == 150 && gotRects[i].height == 50) found0 = 1;
        if (gotRects[i].x == 0 && gotRects[i].y == 50 && gotRects[i].width == 75 && gotRects[i].height == 50) found1 = 1;
    }
    CHECK(found0 && found1, "shape rectangles didn't round-trip correctly through Set/Get");
    XFree(gotRects);

    fprintf(stderr, "SHAPE: version %d.%d, 2-rectangle shape round-tripped correctly\n", shape_major, shape_minor);

    /* Everything checked out - draw something for the harness's own
     * pixel-diff pass, proving the connection is still fully usable. */
    GC gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, 0x0000FF00);
    XFillRectangle(dpy, win, gc, 0, 0, 150, 100);
    XFlush(dpy);
    usleep(200 * 1000);

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
