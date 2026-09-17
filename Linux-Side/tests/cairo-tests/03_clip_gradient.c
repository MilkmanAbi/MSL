/* Layer 1: cairo clipping (`cairo_clip`) and gradients
 * (`cairo_pattern_create_linear`) - the remaining two items from the
 * plan's Layer 1 checklist (shapes: 01_shapes.c, text: 02_text.c).
 * Gradients go through RENDER's linear-gradient picture type, which
 * mslgd does not implement (confirmed unimplemented in X11RenderOpcode) -
 * this test exists to see exactly how that fails (dropped silently like
 * trapezoids/glyphs were, or something else) rather than assume.
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

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);

    /* --- Clipping: clip to a 60x60 circle, then fill a much bigger
     * rectangle with solid blue - only the circle should show blue. --- */
    cairo_save(cr);
    cairo_arc(cr, 40, 40, 30, 0, 2 * 3.14159265358979);
    cairo_clip(cr);
    cairo_set_source_rgb(cr, 0, 0, 1);
    cairo_paint(cr); /* paints the WHOLE surface, but clip should confine it to the circle */
    cairo_restore(cr);

    /* --- Linear gradient: red (left) to green (right), filling a
     * rectangle - checks RENDER's linear-gradient picture type. --- */
    cairo_pattern_t *grad = cairo_pattern_create_linear(100, 10, 190, 10);
    cairo_pattern_add_color_stop_rgb(grad, 0.0, 1, 0, 0);
    cairo_pattern_add_color_stop_rgb(grad, 1.0, 0, 1, 0);
    cairo_set_source(cr, grad);
    cairo_rectangle(cr, 100, 10, 90, 60);
    cairo_fill(cr);
    cairo_pattern_destroy(grad);

    cairo_status_t status = cairo_status(cr);
    if (status != CAIRO_STATUS_SUCCESS) {
        fprintf(stderr, "cairo error: %s\n", cairo_status_to_string(status));
    }

    cairo_surface_flush(surface);
    XFlush(dpy);
    usleep(300 * 1000);

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
