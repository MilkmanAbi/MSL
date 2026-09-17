/* Layer 2: minimal GTK3 - one window, one GtkDrawingArea doing manual
 * cairo drawing (a filled rect + text), no button/label/icon-theme/CSS
 * complexity. Deliberately NOT galculator - isolates "does a bare-bones
 * GTK3 app work at all through mslgd" (window/widget realization, GDK's
 * own X11 backend, cairo drawing inside a GTK "draw" signal handler)
 * from galculator's own fontconfig/glycin/pango/CSS-heavy real-world
 * complexity, per the plan's Layer 2 rationale.
 *
 * This is the exact test that surfaced a real, high-impact mslgd bug:
 * a `GtkDrawingArea` gets its own native child X11 window, and GDK never
 * invoked "draw" for it - mslgd sent `Expose` on map but never
 * `MapNotify`, which GDK treats as the authoritative "you're really
 * visible now" signal for any window it's watching StructureNotifyMask
 * on. Fixed in `X11Connection.mapChild`/`handleMapWindow` (see
 * `sendMapNotify`'s doc comment). Very plausibly a major contributor to
 * this project's original galculator blank-window mystery, since GTK
 * widgets commonly get native child windows the same way.
 */
#include <gtk/gtk.h>

static gboolean on_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
    GtkAllocation alloc;
    gtk_widget_get_allocation(widget, &alloc);

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);

    cairo_set_source_rgb(cr, 0, 0.4, 1);
    cairo_rectangle(cr, 15, 15, alloc.width - 30, alloc.height - 30);
    cairo_fill(cr);

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 20);
    cairo_move_to(cr, 30, alloc.height / 2 + 7);
    cairo_show_text(cr, "GTK3");

    return FALSE;
}

static gboolean quit_after_delay(gpointer data) {
    gtk_main_quit();
    return FALSE;
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(window), 200, 100);

    GtkWidget *area = gtk_drawing_area_new();
    gtk_container_add(GTK_CONTAINER(window), area);
    g_signal_connect(area, "draw", G_CALLBACK(on_draw), NULL);

    gtk_widget_show_all(window);
    g_timeout_add(600, quit_after_delay, NULL);
    gtk_main();
    return 0;
}
