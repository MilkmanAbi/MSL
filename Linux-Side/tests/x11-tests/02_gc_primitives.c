/* Layer 0: GC-based drawing primitives - lines, rectangles, filled
 * polygons, arcs, filled arcs - at known coordinates, against
 * mslgd's handlePolySegment/handleFillPoly/handlePolyArc/
 * handlePolyFillArc (X11Connection.swift). No cairo, no toolkit.
 */
#include <X11/Xlib.h>
#include <stdio.h>
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

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    GC gc = XCreateGC(dpy, win, 0, NULL);

    /* White background first, so every shape below is unambiguous. */
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 0, 0, 200, 150);

    /* A blue filled rectangle. */
    XSetForeground(dpy, gc, 0x000000FF);
    XFillRectangle(dpy, win, gc, 10, 10, 60, 40);

    /* A green line. */
    XSetForeground(dpy, gc, 0x0000FF00);
    XSetLineAttributes(dpy, gc, 3, LineSolid, CapButt, JoinMiter);
    XDrawLine(dpy, win, gc, 80, 10, 190, 10);

    /* A red filled triangle (polygon). */
    XSetForeground(dpy, gc, 0x00FF0000);
    XPoint tri[3] = { {100, 30}, {140, 30}, {120, 65} };
    XFillPolygon(dpy, win, gc, tri, 3, Convex, CoordModeOrigin);

    /* A black filled circle (arc, 0-360 degrees in 64ths). */
    XSetForeground(dpy, gc, 0x00000000);
    XFillArc(dpy, win, gc, 10, 70, 50, 50, 0, 360 * 64);

    /* A magenta unfilled arc outline (a half-circle). */
    XSetForeground(dpy, gc, 0x00FF00FF);
    XSetLineAttributes(dpy, gc, 2, LineSolid, CapButt, JoinMiter);
    XDrawArc(dpy, win, gc, 80, 70, 50, 50, 0, 180 * 64);

    XFlush(dpy);
    usleep(300 * 1000);

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
