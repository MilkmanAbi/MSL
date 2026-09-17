/* Layer 0: subwindows - a shell/content window tree (matching this
 * project's own `xterm` build's real structure: an outer top-level shell
 * plus one or more child windows mapped via `MapSubwindows`, not their
 * own `MapWindow`), `XGetGeometry` on a child, and `XQueryTree` walking
 * the tree back - checks `handleCreateWindow`'s parent/child split,
 * `handleMapSubwindows`, and the (newly added) `handleQueryTree`.
 *
 * Structural correctness (geometry, tree shape) is asserted directly in
 * C, same as 05_events.c - a hang here (caught by the harness's own
 * `timeout 5`) means `MapSubwindows` never sent the expected `Expose`s,
 * and an assertion failure means the tree/geometry bookkeeping is wrong.
 * Only the FINAL state matters for the harness's pixel diff (see
 * `Scripts/x11-test.sh`'s "newest by mtime" snapshot pick): child2 is
 * drawn last, so its window's snapshot is what actually gets compared.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void fail(const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    exit(1);
}

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window shell = XCreateSimpleWindow(dpy, root, 0, 0, 200, 150, 0,
                                        BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, shell, ExposureMask);

    Window child1 = XCreateSimpleWindow(dpy, shell, 10, 10, 60, 50, 0,
                                         BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, child1, ExposureMask);
    Window child2 = XCreateSimpleWindow(dpy, shell, 100, 10, 60, 50, 0,
                                         BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, child2, ExposureMask);

    /* --- XGetGeometry on an unmapped child: position/size must already
     * be correct, independent of mapping state. --- */
    Window rootRet;
    int gx, gy;
    unsigned int gw, gh, gbw, gdepth;
    if (!XGetGeometry(dpy, child1, &rootRet, &gx, &gy, &gw, &gh, &gbw, &gdepth))
        fail("XGetGeometry request itself failed");
    if (gx != 10 || gy != 10 || gw != 60 || gh != 50) {
        fprintf(stderr, "child1 geometry: x=%d y=%d w=%u h=%u\n", gx, gy, gw, gh);
        fail("child1 geometry mismatch");
    }

    /* --- XQueryTree on the shell: both children must be listed. --- */
    Window treeRoot, treeParent;
    Window *kids = NULL;
    unsigned int nKids = 0;
    if (!XQueryTree(dpy, shell, &treeRoot, &treeParent, &kids, &nKids))
        fail("XQueryTree request itself failed");
    if (nKids != 2) {
        fprintf(stderr, "expected 2 children, got %u\n", nKids);
        fail("XQueryTree child count");
    }
    int sawChild1 = 0, sawChild2 = 0;
    for (unsigned int i = 0; i < nKids; i++) {
        if (kids[i] == child1) sawChild1 = 1;
        if (kids[i] == child2) sawChild2 = 1;
    }
    if (!sawChild1 || !sawChild2) fail("XQueryTree missing an expected child");
    if (kids) XFree(kids);

    /* --- Map the shell, then both children at once via MapSubwindows -
     * matching xterm's real shell/content mapping pattern, NOT each
     * child's own MapWindow. --- */
    XMapWindow(dpy, shell);
    XFlush(dpy);
    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (!(ev.type == Expose && ev.xexpose.window == shell));

    XMapSubwindows(dpy, shell);
    XFlush(dpy);
    int gotExpose1 = 0, gotExpose2 = 0;
    while (!(gotExpose1 && gotExpose2)) {
        XNextEvent(dpy, &ev);
        if (ev.type != Expose) continue;
        if (ev.xexpose.window == child1) gotExpose1 = 1;
        if (ev.xexpose.window == child2) gotExpose2 = 1;
    }

    /* --- Draw into each child - proves each has its own independent,
     * correctly positioned/sized backing store. child1=red, child2=blue
     * (drawn LAST, so it's the one the harness's pixel diff will see -
     * see this file's top doc comment). --- */
    GC gc = XCreateGC(dpy, shell, 0, NULL);
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, shell, gc, 0, 0, 200, 150);

    XSetForeground(dpy, gc, 0x00FF0000);
    XFillRectangle(dpy, child1, gc, 0, 0, 60, 50);
    XFlush(dpy);
    usleep(150 * 1000); /* let child1's snapshot settle before child2 becomes "newest" */

    XSetForeground(dpy, gc, 0x000000FF);
    XFillRectangle(dpy, child2, gc, 0, 0, 60, 50);
    XFlush(dpy);
    usleep(300 * 1000);

    fprintf(stderr, "all subwindow checks verified OK\n");

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, shell); /* destroys child1/child2 with it - handleDestroyWindow's subtree teardown */
    XCloseDisplay(dpy);
    return 0;
}
