/* Layer 1: cairo text rendering (`cairo_show_text`, the toy font API) -
 * a real client's font/glyph path, distinct from shape filling
 * (01_shapes.c already covers trapezoid-based fills). Cairo's xlib
 * backend may rasterize glyphs via the RENDER glyph-set extension
 * (`CreateGlyphSet`/`AddGlyphs`/`CompositeGlyphs8`, none of which mslgd
 * implements yet as of this test's writing) or may fall back to per-
 * glyph image/trapezoid compositing depending on font backend/config -
 * this test exists to find out which, empirically, rather than guessing.
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
    int width = 200, height = 80;
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

    cairo_set_source_rgb(cr, 0, 0, 0);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 40);
    cairo_move_to(cr, 10, 55);
    cairo_show_text(cr, "MSL");

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
