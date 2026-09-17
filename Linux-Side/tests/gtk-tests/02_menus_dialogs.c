/* Layer 2 GTK3 test, interactive (no auto-quit) - deliberately exercises
 * the features galculator's own simple menu bar doesn't: a NESTED
 * submenu (Edit > Selection > ...), a real modal GtkDialog
 * (gtk_dialog_new_with_buttons, transient-for the main window, not just
 * an override-redirect popup), and a second independent top-level window
 * opened from a button (tests window-opens-window ownership, not just
 * menu popups). Written for `gui-bugs.md`'s broader "make sure complex
 * GTK apps work, not just galculator" investigation - run directly via
 * `msl gui-native <instance> <this binary>`, not through the automated
 * snapshot harness (nothing here auto-quits).
 */
#include <gtk/gtk.h>

static void on_about(GtkMenuItem *item, gpointer data) {
    GtkWidget *parent = GTK_WIDGET(data);
    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(parent), GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        GTK_MESSAGE_INFO, GTK_BUTTONS_OK, "This is a real modal GtkDialog.");
    gtk_window_set_title(GTK_WINDOW(dialog), "About");
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static void on_prefs(GtkMenuItem *item, gpointer data) {
    GtkWidget *parent = GTK_WIDGET(data);
    GtkWidget *dialog = gtk_dialog_new_with_buttons(
        "Preferences", GTK_WINDOW(parent),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        "_Cancel", GTK_RESPONSE_CANCEL, "_OK", GTK_RESPONSE_OK, NULL);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget *label = gtk_label_new("A real GtkDialog with Cancel/OK buttons.");
    gtk_widget_set_margin_start(label, 12);
    gtk_widget_set_margin_end(label, 12);
    gtk_widget_set_margin_top(label, 12);
    gtk_widget_set_margin_bottom(label, 12);
    gtk_container_add(GTK_CONTAINER(content), label);
    gtk_widget_show_all(dialog);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static void on_open_second_window(GtkButton *btn, gpointer data) {
    GtkWidget *parent = GTK_WIDGET(data);
    GtkWidget *second = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(second), "Second Window");
    gtk_window_set_default_size(GTK_WINDOW(second), 250, 150);
    gtk_window_set_transient_for(GTK_WINDOW(second), GTK_WINDOW(parent));
    GtkWidget *label = gtk_label_new("A second, independent top-level window\nowned by the first (transient-for).");
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_container_add(GTK_CONTAINER(second), label);
    gtk_widget_show_all(second);
}

static void quit(GtkMenuItem *item, gpointer data) {
    gtk_main_quit();
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "Menus & Dialogs Test");
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(window), vbox);

    /* Menu bar: File > Quit ; Edit > Selection > (Select All, Select None) ; Help > About, Preferences */
    GtkWidget *menubar = gtk_menu_bar_new();

    GtkWidget *fileMenuItem = gtk_menu_item_new_with_label("File");
    GtkWidget *fileMenu = gtk_menu_new();
    GtkWidget *quitItem = gtk_menu_item_new_with_label("Quit");
    g_signal_connect(quitItem, "activate", G_CALLBACK(quit), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(fileMenu), quitItem);
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(fileMenuItem), fileMenu);
    gtk_menu_shell_append(GTK_MENU_SHELL(menubar), fileMenuItem);

    GtkWidget *editMenuItem = gtk_menu_item_new_with_label("Edit");
    GtkWidget *editMenu = gtk_menu_new();
    GtkWidget *selectionSubItem = gtk_menu_item_new_with_label("Selection");
    GtkWidget *selectionSubmenu = gtk_menu_new();
    GtkWidget *selectAllItem = gtk_menu_item_new_with_label("Select All");
    GtkWidget *selectNoneItem = gtk_menu_item_new_with_label("Select None");
    gtk_menu_shell_append(GTK_MENU_SHELL(selectionSubmenu), selectAllItem);
    gtk_menu_shell_append(GTK_MENU_SHELL(selectionSubmenu), selectNoneItem);
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(selectionSubItem), selectionSubmenu);
    gtk_menu_shell_append(GTK_MENU_SHELL(editMenu), selectionSubItem);
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(editMenuItem), editMenu);
    gtk_menu_shell_append(GTK_MENU_SHELL(menubar), editMenuItem);

    GtkWidget *helpMenuItem = gtk_menu_item_new_with_label("Help");
    GtkWidget *helpMenu = gtk_menu_new();
    GtkWidget *aboutItem = gtk_menu_item_new_with_label("About");
    GtkWidget *prefsItem = gtk_menu_item_new_with_label("Preferences");
    g_signal_connect(aboutItem, "activate", G_CALLBACK(on_about), window);
    g_signal_connect(prefsItem, "activate", G_CALLBACK(on_prefs), window);
    gtk_menu_shell_append(GTK_MENU_SHELL(helpMenu), aboutItem);
    gtk_menu_shell_append(GTK_MENU_SHELL(helpMenu), prefsItem);
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(helpMenuItem), helpMenu);
    gtk_menu_shell_append(GTK_MENU_SHELL(menubar), helpMenuItem);

    gtk_box_pack_start(GTK_BOX(vbox), menubar, FALSE, FALSE, 0);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(content, 12);
    gtk_widget_set_margin_end(content, 12);
    gtk_widget_set_margin_top(content, 12);
    gtk_widget_set_margin_bottom(content, 12);
    gtk_box_pack_start(GTK_BOX(vbox), content, TRUE, TRUE, 0);

    GtkWidget *label = gtk_label_new("File > Quit | Edit > Selection > ... | Help > About / Preferences");
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_box_pack_start(GTK_BOX(content), label, FALSE, FALSE, 0);

    GtkWidget *openWinBtn = gtk_button_new_with_label("Open Second Window");
    g_signal_connect(openWinBtn, "clicked", G_CALLBACK(on_open_second_window), window);
    gtk_box_pack_start(GTK_BOX(content), openWinBtn, FALSE, FALSE, 0);

    GtkWidget *bottomMarker = gtk_label_new("<<< BOTTOM >>>");
    gtk_box_pack_end(GTK_BOX(content), bottomMarker, FALSE, FALSE, 0);

    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
