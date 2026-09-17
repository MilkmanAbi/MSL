/* Layer 0: the most basic thing a real client depends on - create a
 * window, map it, wait for the initial Expose a newly-visible window
 * needs (this is the exact eventMask/Expose path suspected, but never
 * confirmed, as galculator's black-window blocker), then fill it with a
 * known solid color so the harness has something deterministic to diff.
 *
 * Deliberately plain Xlib - no cairo, no toolkit - so a failure here can
 * only be mslgd's core CreateWindow/MapWindow/Expose/FillRectangle
 * handling, nothing else.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, 200, 150, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));

    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    /* Block for the initial Expose - if mslgd never sends it (the
     * eventMask bug this test exists to catch), this hangs until the
     * outer `timeout` in the harness kills it, which the harness reports
     * as a clear FAIL rather than a false PASS. */
    XEvent ev;
    do {
        XNextEvent(dpy, &ev);
    } while (ev.type != Expose);

    /* A known, deterministic fill - solid orange (0xFF7F00) - so the
     * reference PNG is exactly reproducible. */
    GC gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, 0x00FF7F00);
    XFillRectangle(dpy, win, gc, 0, 0, 200, 150);
    XFlush(dpy);

    /* Give mslgd a moment to actually paint the fill into its bitmap and
     * dump the snapshot before the connection (and the window with it)
     * goes away. */
    usleep(300 * 1000);

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
