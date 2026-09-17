/* Layer 1: the "offscreen pixmap double-buffer" pattern real GTK/cairo
 * apps use (galculator's own actual rendering pattern, confirmed live
 * via mslhd's trace log) - draw into a `cairo_xlib_surface_create`
 * bound to a PIXMAP (not a window), then `XCopyArea` that pixmap onto
 * the real window in one shot.
 *
 * This test caught a real, previously-confirmed whole-window vertical
 * flip bug: `CGContext.draw(_:in:)` carries an extra built-in flip
 * relative to pure path-fill operations (`ctx.fill`/`fillPath`), which
 * `CopyArea`'s final blit always went through - a source pixmap filled
 * via cairo/RENDER (path-fills, no image-draw of its own) picked up
 * exactly one such flip and came out visibly wrong, while a `PutImage`-
 * filled source happened to look right by accident (its OWN fill also
 * used `draw(_:in:)`, so two flips canceled). Fixed by normalizing
 * EVERY raw-image `draw(_:in:)` call site in mslgd (`PutImage`,
 * `RenderComposite`'s image-src branch, the glyph color-image branch,
 * `X11CanvasView.resize`'s content-preserving copy, and `CopyArea`
 * itself) through `drawImageTopLeftOriented` - see that function's doc
 * comment in `X11Drawable.swift` for the full investigation, including
 * two earlier, narrower fix attempts that were tried and reverted
 * before this one (each fixed this exact case while regressing others).
 * A live galculator run hit this exact bug on its own main window.
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

    /* --- Draw everything into an OFFSCREEN PIXMAP via cairo - same
     * surface-creation pattern as 01_shapes.c but bound to a Pixmap,
     * matching galculator's own double-buffering. --- */
    Pixmap backbuf = XCreatePixmap(dpy, win, width, height, 24);
    cairo_surface_t *pixSurface = cairo_xlib_surface_create(
        dpy, backbuf, DefaultVisual(dpy, screen), width, height);
    cairo_t *cr = cairo_create(pixSurface);

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);

    /* Blue rect near the TOP - if the whole thing ends up vertically
     * flipped, this would appear near the BOTTOM instead. */
    cairo_set_source_rgb(cr, 0, 0, 1);
    cairo_rectangle(cr, 10, 10, 60, 30);
    cairo_fill(cr);

    /* Text near the top too. */
    cairo_set_source_rgb(cr, 0, 0, 0);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 20);
    cairo_move_to(cr, 90, 35);
    cairo_show_text(cr, "TOP");

    /* Red circle near the BOTTOM - the asymmetry (top vs bottom content
     * differs) is what makes a whole-image flip unambiguous either way. */
    cairo_set_source_rgb(cr, 1, 0, 0);
    cairo_arc(cr, 40, 120, 25, 0, 2 * 3.14159265358979);
    cairo_fill(cr);

    cairo_surface_flush(pixSurface);

    /* --- Now blit the whole pixmap onto the window in one shot, exactly
     * like GDK's own double-buffer flush (a raw XCopyArea, not cairo). --- */
    GC gc = XCreateGC(dpy, win, 0, NULL);
    XCopyArea(dpy, backbuf, win, gc, 0, 0, width, height, 0, 0);
    XFlush(dpy);
    usleep(300 * 1000);

    cairo_destroy(cr);
    cairo_surface_destroy(pixSurface);
    XFreePixmap(dpy, backbuf);
    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
