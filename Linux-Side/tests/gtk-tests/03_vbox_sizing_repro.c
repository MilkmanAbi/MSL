/* Minimal, deliberately tiny repro for `gui-bugs.md` issue #9 ("many real
 * GTK apps' default window clips content at the bottom, and a
 * `gtk_box_pack_end` widget frequently never renders at all"). No menu
 * bar, no dialogs, no explicit `gtk_window_set_default_size` - just a
 * 3-widget vertical `GtkBox` (a label, a button, and a `pack_end`'d
 * label), letting GTK compute its own "natural size" for everything.
 *
 * Confirmed live (2026-09-03) this is NOT specific to menu bars, dialogs,
 * or any explicit size hint - `Guest/init/gtk-tests/02_menus_dialogs.c`
 * (much more complex) hits the exact same symptom, and removing its menu
 * bar entirely (this file) still reproduces it. Confirmed the missing
 * bottom widget genuinely never gets a `RENDER CompositeGlyphs8` (or any
 * other draw) request sent for it at all - a client-side (GTK/GDK) layout
 * decision, not an mslgd rendering/clipping bug downstream of a real
 * draw call. Root cause NOT yet found - see issue #9's full writeup for
 * what's been ruled out (WM_NORMAL_HINTS, a stray RandR mm-dimension
 * arithmetic bug - real, fixed, but not sufficient on its own) and what
 * hasn't been checked yet.
 *
 * Run interactively (this doesn't auto-quit): compile in the guest with
 * `pkg-config --cflags/--libs gtk+-3.0`, then `DISPLAY=:1 <binary>` via
 * `msl -- ...` against an already-running `mslhd` + `msl gui-native
 * default` tunnel.
 */
#include <gtk/gtk.h>

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_add(GTK_CONTAINER(window), vbox);

    GtkWidget *label = gtk_label_new("Top label");
    gtk_box_pack_start(GTK_BOX(vbox), label, FALSE, FALSE, 0);

    GtkWidget *btn = gtk_button_new_with_label("A Button");
    gtk_box_pack_start(GTK_BOX(vbox), btn, FALSE, FALSE, 0);

    /* This one - if the bug reproduces - never gets drawn at all. */
    GtkWidget *bottom = gtk_label_new("<<< BOTTOM >>>");
    gtk_box_pack_end(GTK_BOX(vbox), bottom, FALSE, FALSE, 0);

    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
