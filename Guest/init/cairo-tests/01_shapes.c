/* Layer 1: cairo alone, no toolkit - `cairo_xlib_surface_create` bound
 * directly to a plain Xlib window, then cairo's own drawing primitives
 * (filled rect, filled circle, stroked line). Isolates "does cairo's own
 * compositing (RENDER-based, or its core-X fallback) work through mslgd"
 * from GTK's widget/CSS/fontconfig/glycin stack entirely - if THIS fails,
 * the bug is in mslgd's RENDER/core-X handling as cairo actually drives
 * it (a different access pattern than the Layer-0 RENDER test's hand-
 * rolled requests); if this passes, a GTK-level bug is toolkit-specific,
 * not a rendering-pipeline problem.
 */
#include <X11/Xlib.h>
#include <cairo.h>
#include <cairo-xlib.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    int width = 200, height = 150;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 0,
                                      BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win, ExposureMask);
    XMapWindow(dpy, win);

    XEvent ev;
    do { XNextEvent(dpy, &ev); } while (ev.type != Expose);

    cairo_surface_t *surface = cairo_xlib_surface_create(
        dpy, win, DefaultVisual(dpy, screen), width, height);
    cairo_t *cr = cairo_create(surface);

    /* White background. */
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);

    /* Blue filled rectangle. */
    cairo_set_source_rgb(cr, 0, 0, 1);
    cairo_rectangle(cr, 10, 10, 70, 50);
    cairo_fill(cr);

    /* Red filled circle. */
    cairo_set_source_rgb(cr, 1, 0, 0);
    cairo_arc(cr, 150, 35, 30, 0, 2 * 3.14159265358979);
    cairo_fill(cr);

    /* Green stroked line, width 4. */
    cairo_set_source_rgb(cr, 0, 1, 0);
    cairo_set_line_width(cr, 4);
    cairo_move_to(cr, 10, 100);
    cairo_line_to(cr, 190, 100);
    cairo_stroke(cr);

    /* A translucent (alpha=0.5) black rectangle over the green line and
     * white background, at a known spot - directly exercises cairo's
     * alpha compositing path (RENDER Composite under the hood on a real
     * X11 backend), over a KNOWN solid background so the expected result
     * is exact: 0.5*black + 0.5*white = mid-gray (127,127,127). */
    cairo_set_source_rgba(cr, 0, 0, 0, 0.5);
    cairo_rectangle(cr, 10, 115, 70, 25);
    cairo_fill(cr);

    cairo_surface_flush(surface);
    XFlush(dpy);
    usleep(300 * 1000);

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
