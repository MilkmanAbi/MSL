/* Layer 0 regression test for a real, high-impact bug: `SetClipRectangles`
 * (core opcode 59) was unimplemented, and - unlike this server's usual
 * "unrecognized opcode gets a silent BadImplementation error, which the
 * X11 spec says any client must tolerate" policy - a real GDK/GTK client
 * (galculator) did NOT tolerate it: it's part of GDK's routine damage/
 * redraw-region bookkeeping (fires on ordinary widget redraws, e.g. every
 * button click), and receiving a `BadImplementation` for it left GDK's
 * own internal state broken enough to crash the app outright shortly
 * after. Confirmed live: this was the actual root cause behind
 * "galculator doesn't respond to button clicks" - not a focus/input-
 * delivery problem (mouse events were reaching the app fine), but this
 * one request making it crash before the click's own effects ever
 * rendered. Fixed by making `SetClipRectangles` a silent no-op like
 * every other genuinely-unimplemented-but-benign request.
 *
 * This test just needs to prove the request doesn't blow up the
 * connection - draws a known rect, calls XSetClipRectangles, then draws
 * ANOTHER rect to prove the connection/GC are still alive and usable
 * afterward, and diffs the final window content.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 150, 100, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    GC gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 0, 0, 150, 100);

    /* The request under test. */
    XRectangle clip = { 0, 0, 150, 100 };
    XSetClipRectangles(dpy, gc, 0, 0, &clip, 1, Unsorted);
    XFlush(dpy);
    usleep(100 * 1000);

    /* If the connection survived, this MUST still work and be visible -
     * proves the client (and this server) are still in a normal,
     * functioning state after the request under test, not just that the
     * process didn't crash immediately. */
    XSetForeground(dpy, gc, 0x0000FF00);
    XFillRectangle(dpy, win, gc, 20, 20, 110, 60);
    XFlush(dpy);
    usleep(200 * 1000);

    fprintf(stderr, "SetClipRectangles survived, connection still usable\n");

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
