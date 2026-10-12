import Foundation

/// The GTK3 file-dialog shim's source, shipped in the guest kit and compiled
/// there on install.
///
/// **Why the source and not a binary.** The kit travels as text inside one
/// `shellinit` EXEC frame, and MSL has no cross-compiler for every guest
/// architecture and libc it supports. The shim deliberately includes no
/// headers and links nothing, so a plain `cc` is the only thing a guest
/// needs - and a guest without one simply keeps its own file dialogs.
///
/// **Generated - do not edit.** The readable copy lives at
/// `Guest/init/msl-gtkpicker.c`, which is what the image build compiles;
/// `Scripts/gen-gtkpicker-source.py` regenerates this file from it, and
/// `testGTKPickerSourceMatchesCheckedInFile` asserts the two are identical so
/// neither can drift from the other.
extension GuestIntegration {
    static let gtkPickerSource = #"""
/*
 * msl-gtkpicker.c - LD_PRELOAD shim: send a GTK3 app's Open/Save dialog to
 * MSL Files instead of letting it draw its own.
 *
 * Why a shim at all (measured 2026-09-29):
 *
 *   `GTK_USE_PORTAL=1` only reaches GtkFileChooserNative and GTK4's
 *   GtkFileDialog. The older GtkFileChooserDialog builds its chooser in
 *   process and never speaks to a portal, so no environment variable can
 *   reach it. That is still the common case on these images: both GIMP
 *   (/usr/bin/gimp-3.0) and Mousepad (libmousepad.so.0) import
 *   gtk_file_chooser_dialog_new *and* gtk_dialog_run. Qt is already solved
 *   a supported way - QT_QPA_PLATFORMTHEME=xdgdesktopportal - and GTK4 and
 *   GtkFileChooserNative are covered by GTK_USE_PORTAL. This file is only
 *   for what neither reaches.
 *
 * There are two interception points, because apps drive these dialogs in two
 * different ways and neither covers the other:
 *
 *   1. gtk_dialog_run() - the blocking form. Mousepad does this.
 *   2. gtk_widget_show() / _show_all() / gtk_window_present() followed by a
 *      "response" signal handler - the non-blocking form. GIMP does this,
 *      and a hook on gtk_dialog_run alone reached none of it.
 *
 * Either way the real dialog is never shown, which is what makes this
 * simple: nothing to hide, nothing that can flash on screen, and no unmap
 * for GTK to read as a cancel. The non-blocking form answers by emitting
 * gtk_dialog_response() from an idle callback, exactly as a button press
 * would - from an idle and not from inside show(), because gtk_dialog_run
 * connects its own response handler *after* calling show, so a response
 * emitted during show would be missed and the app would hang forever.
 *
 * The two hooks coordinate through one flag on the dialog: if show() has
 * already scheduled a pick, gtk_dialog_run defers to the real one and lets
 * the idle's response be what it returns.
 *
 * **The answer is stored on the dialog, not applied to it.** Setting the
 * chooser's filename and letting the app read it back would depend on GTK
 * having built a chooser it never showed - set_current_folder on an
 * unrealized chooser is applied when the folder finishes loading, so an app
 * calling get_filename immediately can get NULL. Instead the chosen paths
 * are attached to the dialog with g_object_set_data_full and the six getters
 * an app might use are interposed to return them. No dependence on GTK's
 * internal state machine, and the data dies with the dialog.
 *
 * **Deliberately links nothing and includes no GTK or GLib headers.** Every
 * function is resolved at the first call (real_symbol / glib_symbol), so:
 *   - preloading it into a process with no GTK costs one dlsym that fails;
 *   - it cannot drag libgtk-3 into a GTK4 process, which would be fatal;
 *   - it builds in any guest with a C compiler, with no -dev packages.
 * The only ABI assumed is GTypeInstance's first field being its GTypeClass
 * and that class's first field being its GType, which is how G_OBJECT_TYPE
 * has always been defined.
 *
 * Refuses to act unless gtk_get_major_version() reports 3. GTK4 exports
 * gtk_file_chooser_get_file and get_files under these same names, so those
 * wrappers stay reachable there - they find no attached answer and call
 * straight through.
 *
 * Off by default: it does nothing at all unless MSL_GTK_PICKER=1 is in the
 * environment, which `GuestIntegration.filePortalLines` exports only while
 * the "MSL Files handles folders and file dialogs" setting is on.
 *
 * Whenever anything is unclear - no recognisable accept button, MSL
 * unreachable, a symbol missing - it calls the real gtk_dialog_run and the
 * app shows its own dialog exactly as before. A wrong guess must never cost
 * someone a save.
 *
 * Build (in the guest):
 *   cc -O2 -Wall -Wextra -shared -fPIC -o msl-gtkpicker.so msl-gtkpicker.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* GLib/GTK types, spelled out so no headers are needed. */
typedef void *gpointer;
typedef char gchar;
typedef int gint;
typedef int gboolean;
typedef unsigned long GType;
typedef void (*GDestroyNotify)(gpointer);
typedef gboolean (*GSourceFunc)(gpointer);

typedef struct GSList {
    gpointer data;
    struct GSList *next;
} GSList;

/* GtkResponseType. Only the affirmative ones plus CANCEL are needed. */
#define MSL_RESPONSE_ACCEPT (-3)
#define MSL_RESPONSE_OK     (-5)
#define MSL_RESPONSE_CANCEL (-6)
#define MSL_RESPONSE_YES    (-8)
#define MSL_RESPONSE_APPLY  (-10)

/* GtkFileChooserAction. */
#define MSL_ACTION_OPEN          0
#define MSL_ACTION_SAVE          1
#define MSL_ACTION_SELECT_FOLDER 2
#define MSL_ACTION_CREATE_FOLDER 3

/* What `msl-file-picker` means by its exit code. */
#define PICK_PICKED      0
#define PICK_CANCELLED   1
#define PICK_UNAVAILABLE 2

#define PICK_KEY "msl-picked-paths"
/* Set on a dialog whose show() we have swallowed and whose pick is queued,
 * so a second show does not queue a second one and gtk_dialog_run knows to
 * wait for the idle's answer rather than starting its own. */
#define BUSY_KEY "msl-pick-queued"

/* ------------------------------------------------------------------ */
/* Symbol lookup                                                       */
/* ------------------------------------------------------------------ */

/* The function this shim replaced - looked up past ourselves. */
static void *real_symbol(const char *name)
{
    return dlsym(RTLD_NEXT, name);
}

/* A function we only ever call, never replace. RTLD_DEFAULT because GTK,
 * GLib and GIO are already in the process; if one is not, this returns NULL
 * and the caller falls back. */
static void *any_symbol(const char *name)
{
    return dlsym(RTLD_DEFAULT, name);
}

/* True while a pick is on screen, so a dialog the app opens from inside our
 * nested main loop (an overwrite confirmation, say) is left alone. */
static int in_pick;

static int gtk_is_version_3(void)
{
    static int checked, is3;
    if (!checked) {
        unsigned int (*major)(void) = any_symbol("gtk_get_major_version");
        is3 = major && major() == 3;
        checked = 1;
    }
    return is3;
}

static int enabled(void)
{
    const char *value = getenv("MSL_GTK_PICKER");
    return value && value[0] == '1' && value[1] == '\0';
}

/*
 * A line in the trace, when MSL_GTK_PICKER_DEBUG names a file.
 *
 * There is nowhere else for this to go: the shim lives inside somebody
 * else's process, and writing to its stderr would put MSL's noise in an
 * app's own log. Off unless asked for, opened and closed per line so two
 * processes can share the file, and never able to fail the thing it is
 * describing.
 */
static void trace(const char *what, const char *detail, long value)
{
    const char *path = getenv("MSL_GTK_PICKER_DEBUG");
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    char line[512];
    int n = snprintf(line, sizeof line, "[%d] %s %s %ld\n",
                     (int)getpid(), what, detail ? detail : "-", value);
    if (n > 0) { ssize_t ignored = write(fd, line, (size_t)n); (void)ignored; }
    close(fd);
}

/* G_OBJECT_TYPE without the header: an instance's first field is its class,
 * and a class's first field is its type. */
static GType type_of(gpointer instance)
{
    if (!instance) return 0;
    void *klass = *(void **)instance;
    if (!klass) return 0;
    return *(GType *)klass;
}

static int implements_file_chooser(gpointer object)
{
    GType (*chooser_type)(void) = any_symbol("gtk_file_chooser_get_type");
    gboolean (*is_a)(GType, GType) = any_symbol("g_type_is_a");
    if (!chooser_type || !is_a) return 0;
    GType type = type_of(object);
    return type && is_a(type, chooser_type());
}

/* ------------------------------------------------------------------ */
/* The answer, attached to the dialog                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    char **paths;
    int count;
} Pick;

static void pick_free(gpointer data)
{
    Pick *pick = data;
    if (!pick) return;
    for (int i = 0; i < pick->count; i++) free(pick->paths[i]);
    free(pick->paths);
    free(pick);
}

static void pick_attach(gpointer dialog, char **paths, int count)
{
    void (*set_data_full)(gpointer, const gchar *, gpointer, GDestroyNotify) =
        any_symbol("g_object_set_data_full");
    if (!set_data_full) { for (int i = 0; i < count; i++) free(paths[i]); free(paths); return; }
    Pick *pick = calloc(1, sizeof *pick);
    if (!pick) { for (int i = 0; i < count; i++) free(paths[i]); free(paths); return; }
    pick->paths = paths;
    pick->count = count;
    set_data_full(dialog, PICK_KEY, pick, pick_free);
}

static Pick *pick_of(gpointer object)
{
    if (!object) return NULL;
    gpointer (*get_data)(gpointer, const gchar *) = any_symbol("g_object_get_data");
    if (!get_data) return NULL;
    Pick *pick = get_data(object, PICK_KEY);
    return (pick && pick->count > 0) ? pick : NULL;
}

/* GLib's allocator, because GTK's caller will free the result with g_free.
 * Falls back to strdup only if GLib is somehow absent, which cannot happen
 * in a process that just called a GTK function. */
static gchar *g_copy(const char *text)
{
    gchar *(*g_strdup_fn)(const gchar *) = any_symbol("g_strdup");
    return g_strdup_fn ? g_strdup_fn(text) : strdup(text);
}

/* ------------------------------------------------------------------ */
/* Running the picker                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    pid_t pid;
    int status;
    int done;
    gpointer loop;
} Watch;

/* waitpid can only fail here with ECHILD (already reaped) or EINTR. */
static int errno_is_fatal(void) { return errno != EINTR; }

static gboolean reap(gpointer data)
{
    Watch *watch = data;
    int status = 0;
    pid_t result = waitpid(watch->pid, &status, WNOHANG);
    if (result != watch->pid) return 1;   /* keep polling */
    watch->status = status;
    watch->done = 1;
    void (*quit)(gpointer) = any_symbol("g_main_loop_quit");
    if (quit && watch->loop) quit(watch->loop);
    return 0;
}

/*
 * Runs `msl-file-picker` and waits for it **without blocking the app's main
 * loop**: a nested GMainLoop keeps GTK dispatching, so the app behind the
 * dialog keeps repainting however long someone browses for. That is exactly
 * what the real gtk_dialog_run does, and skipping it would freeze the app -
 * the same failure that killed Firefox when the picker was slow to appear.
 *
 * Output goes to a temp file rather than a pipe: a pipe would deadlock if a
 * large multi-selection filled its 64K buffer while we were not reading.
 *
 * Returns a PICK_ code; on PICK_PICKED, out/count own the result.
 */
static int run_picker(char *const argv[], char ***out, int *count)
{
    char path[] = "/tmp/msl-gtkpicker-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return PICK_UNAVAILABLE;

    pid_t pid = fork();
    if (pid < 0) { close(fd); unlink(path); return PICK_UNAVAILABLE; }
    if (pid == 0) {
        dup2(fd, STDOUT_FILENO);
        close(fd);
        int null = open("/dev/null", O_WRONLY);
        if (null >= 0) { dup2(null, STDERR_FILENO); close(null); }
        execvp(argv[0], argv);
        _exit(PICK_UNAVAILABLE);
    }

    gpointer (*loop_new)(gpointer, gboolean) = any_symbol("g_main_loop_new");
    void (*loop_run)(gpointer) = any_symbol("g_main_loop_run");
    void (*loop_unref)(gpointer) = any_symbol("g_main_loop_unref");
    unsigned int (*timeout_add)(unsigned int, GSourceFunc, gpointer) =
        any_symbol("g_timeout_add");

    Watch watch = { pid, 0, 0, NULL };
    if (loop_new && loop_run && loop_unref && timeout_add) {
        watch.loop = loop_new(NULL, 0);
        timeout_add(40, reap, &watch);
        loop_run(watch.loop);
        loop_unref(watch.loop);
    }
    /* Either GLib was missing or the loop returned for some other reason;
     * either way the child must be reaped before we read its output. */
    while (!watch.done) {
        if (waitpid(pid, &watch.status, 0) == pid) watch.done = 1;
        else if (errno_is_fatal()) break;
    }

    int code = PICK_UNAVAILABLE;
    if (WIFEXITED(watch.status)) code = WEXITSTATUS(watch.status);
    if (code != PICK_PICKED) { close(fd); unlink(path); return code == PICK_CANCELLED ? PICK_CANCELLED : PICK_UNAVAILABLE; }

    /* Read the chosen paths - one per line, as the CLI documents. */
    off_t size = lseek(fd, 0, SEEK_END);
    if (size <= 0 || size > (off_t)(4 << 20)) { close(fd); unlink(path); return PICK_UNAVAILABLE; }
    char *buffer = malloc((size_t)size + 1);
    if (!buffer) { close(fd); unlink(path); return PICK_UNAVAILABLE; }
    lseek(fd, 0, SEEK_SET);
    ssize_t got = read(fd, buffer, (size_t)size);
    close(fd);
    unlink(path);
    if (got <= 0) { free(buffer); return PICK_UNAVAILABLE; }
    buffer[got] = '\0';

    int capacity = 8, used = 0;
    char **paths = malloc((size_t)capacity * sizeof *paths);
    if (!paths) { free(buffer); return PICK_UNAVAILABLE; }
    for (char *line = buffer, *next; line && *line; line = next) {
        char *end = strchr(line, '\n');
        if (end) { *end = '\0'; next = end + 1; } else { next = NULL; }
        if (!*line) continue;
        if (used == capacity) {
            capacity *= 2;
            char **grown = realloc(paths, (size_t)capacity * sizeof *paths);
            if (!grown) break;
            paths = grown;
        }
        paths[used] = strdup(line);
        if (!paths[used]) break;
        used++;
    }
    free(buffer);
    if (used == 0) { free(paths); return PICK_UNAVAILABLE; }
    *out = paths;
    *count = used;
    return PICK_PICKED;
}

/* ------------------------------------------------------------------ */
/* gtk_dialog_run                                                    */
/* ------------------------------------------------------------------ */

/*
 * Which response the app is waiting to hear.
 *
 * An app may use any integer it likes, so this asks GTK which widget it
 * gave each of the conventional affirmative ids to and takes the first that
 * exists. If none does, the app has custom ids and we cannot know which
 * means "they chose a file" - so the caller shows the real dialog rather
 * than returning a number that might mean something else entirely.
 */
static int accept_response(gpointer dialog, int *found)
{
    gpointer (*widget_for)(gpointer, gint) =
        any_symbol("gtk_dialog_get_widget_for_response");
    *found = 0;
    if (!widget_for) return 0;
    static const int candidates[] = {
        MSL_RESPONSE_ACCEPT, MSL_RESPONSE_OK, MSL_RESPONSE_YES, MSL_RESPONSE_APPLY
    };
    for (unsigned i = 0; i < sizeof candidates / sizeof *candidates; i++) {
        if (widget_for(dialog, candidates[i])) { *found = 1; return candidates[i]; }
    }
    return 0;
}

/*
 * Asks MSL for this dialog's file and, if one comes back, attaches it.
 *
 * Shared by both hooks: the blocking one returns the result as
 * gtk_dialog_run's value, the non-blocking one emits it as a response.
 * Returns a PICK_ code.
 */
/*
 * Also tells the real chooser what was chosen.
 *
 * The interposed getters are still the thing that makes this work reliably,
 * but they are not enough on their own: **an app need not ask the chooser at
 * all.** GIMP does not - it keeps its own idea of the selected file, updated
 * from the chooser's "selection-changed" signal as someone browses, and on
 * OK it uses that. Its dialog was never shown here, so it had nothing, and
 * a perfectly good pick opened no image (traced 2026-09-29: `respond-accept`
 * with no `get_file` after it). Setting the file makes the chooser emit that
 * signal, so an app caching the selection learns about ours.
 *
 * Purely additive: if GTK defers the set - it can, on a chooser that has
 * never been shown, until the folder finishes loading - the getters still
 * answer. So this can help and cannot hurt.
 *
 * **Not for a save dialog.** That path already works through the getters,
 * and setting a name on a chooser with `do-overwrite-confirmation` on could
 * raise GTK's own "replace this file?" dialog over a file the person has
 * already chosen in MSL Files, which would be a second question about a
 * decision they made once.
 */
static void apply_to_chooser(gpointer chooser, const char *path, int action)
{
    if (action == MSL_ACTION_SAVE) return;
    gpointer (*new_for_path)(const char *) = any_symbol("g_file_new_for_path");
    gboolean (*set_file)(gpointer, gpointer, gpointer) =
        real_symbol("gtk_file_chooser_set_file");
    void (*unref)(gpointer) = any_symbol("g_object_unref");
    if (!new_for_path || !set_file) return;
    gpointer file = new_for_path(path);
    if (!file) return;
    gboolean ok = set_file(chooser, file, NULL);
    trace("applied-to-chooser", path, ok);
    if (unref) unref(file);
}

static int pick_for_dialog(gpointer dialog)
{
    gint (*get_action)(gpointer) = any_symbol("gtk_file_chooser_get_action");
    gchar *(*get_current_name)(gpointer) = any_symbol("gtk_file_chooser_get_current_name");
    gchar *(*get_current_folder)(gpointer) = any_symbol("gtk_file_chooser_get_current_folder");
    gboolean (*get_multiple)(gpointer) = any_symbol("gtk_file_chooser_get_select_multiple");
    const gchar *(*get_title)(gpointer) = any_symbol("gtk_window_get_title");
    void (*g_free_fn)(gpointer) = any_symbol("g_free");

    int action = get_action ? get_action(dialog) : MSL_ACTION_OPEN;
    gchar *name = NULL;
    /* Only for a save: asking an OPEN chooser for its current name is a
     * programming error in GTK and logs a critical. */
    if (action == MSL_ACTION_SAVE && get_current_name) name = get_current_name(dialog);
    gchar *folder = get_current_folder ? get_current_folder(dialog) : NULL;
    const gchar *title = get_title ? get_title(dialog) : NULL;

    char *argv[12];
    int n = 0;
    argv[n++] = (char *)"msl-file-picker";
    if (action == MSL_ACTION_SAVE) argv[n++] = (char *)"--save";
    if (action == MSL_ACTION_SELECT_FOLDER || action == MSL_ACTION_CREATE_FOLDER)
        argv[n++] = (char *)"--dir";
    if (action == MSL_ACTION_OPEN && get_multiple && get_multiple(dialog))
        argv[n++] = (char *)"--multiple";
    if (name && *name) { argv[n++] = (char *)"--name"; argv[n++] = name; }
    if (title && *title) { argv[n++] = (char *)"--title"; argv[n++] = (char *)title; }
    if (folder && *folder) argv[n++] = folder;
    argv[n] = NULL;

    char **paths = NULL;
    int count = 0;
    in_pick = 1;
    int outcome = run_picker(argv, &paths, &count);
    in_pick = 0;

    if (name && g_free_fn) g_free_fn(name);
    if (folder && g_free_fn) g_free_fn(folder);

    trace("picker-exit", outcome == PICK_PICKED ? paths[0] : "-", outcome);
    if (outcome == PICK_PICKED) {
        apply_to_chooser(dialog, paths[0], action);
        pick_attach(dialog, paths, count);
    }
    return outcome;
}

/* The flag the two hooks share. */
static int pick_is_queued(gpointer dialog)
{
    gpointer (*get_data)(gpointer, const gchar *) = any_symbol("g_object_get_data");
    return get_data && get_data(dialog, BUSY_KEY) != NULL;
}

static void set_pick_queued(gpointer dialog, int queued)
{
    void (*set_data)(gpointer, const gchar *, gpointer) = any_symbol("g_object_set_data");
    if (set_data) set_data(dialog, BUSY_KEY, queued ? (gpointer)1 : NULL);
}

/* Whether this is a file chooser we should take over: a GtkDialog (so it has
 * responses to give) that also implements GtkFileChooser. Both halves
 * matter - a bare GtkFileChooserWidget embedded in some other window has no
 * response to emit and must be left alone. */
static int is_chooser_dialog(gpointer widget)
{
    if (!widget || !gtk_is_version_3() || !implements_file_chooser(widget)) return 0;
    GType (*dialog_type)(void) = any_symbol("gtk_dialog_get_type");
    gboolean (*is_a)(GType, GType) = any_symbol("g_type_is_a");
    if (!dialog_type || !is_a) return 0;
    return is_a(type_of(widget), dialog_type());
}

gint gtk_dialog_run(gpointer dialog)
{
    gint (*real)(gpointer) = real_symbol("gtk_dialog_run");

    if (in_pick || !enabled() || !dialog || !is_chooser_dialog(dialog))
        return real ? real(dialog) : MSL_RESPONSE_CANCEL;

    /* show() already queued a pick for this dialog. Let the real
     * gtk_dialog_run spin its loop and collect the response our idle emits -
     * running a second picker here would ask the person twice. */
    if (pick_is_queued(dialog)) return real ? real(dialog) : MSL_RESPONSE_CANCEL;

    /* Settled before anything is shown: if the app uses response ids we do
     * not recognise, back out now rather than after someone has picked. */
    int found = 0;
    int accept = accept_response(dialog, &found);
    if (!found) return real ? real(dialog) : MSL_RESPONSE_CANCEL;

    int outcome = pick_for_dialog(dialog);
    if (outcome == PICK_PICKED) return accept;
    /* A cancel is a decision. Showing the app's own dialog straight after
     * someone dismissed ours would be the worst of both. */
    if (outcome == PICK_CANCELLED) return MSL_RESPONSE_CANCEL;
    return real ? real(dialog) : MSL_RESPONSE_CANCEL;
}

/* ------------------------------------------------------------------ */
/* show / present, for apps that do not block                          */
/* ------------------------------------------------------------------ */

/*
 * Runs the pick and answers the dialog the way a button press would.
 *
 * On an idle rather than inside show(), because gtk_dialog_run connects its
 * response handler *after* calling show: a response emitted during show
 * would land before anyone is listening and the app would wait forever.
 */
static gboolean pick_then_respond(gpointer dialog)
{
    void (*unref)(gpointer) = any_symbol("g_object_unref");
    void (*respond)(gpointer, gint) = any_symbol("gtk_dialog_response");

    int found = 0;
    int accept = accept_response(dialog, &found);
    int outcome = found ? pick_for_dialog(dialog) : PICK_UNAVAILABLE;

    /* Cleared before answering, so a dialog the app shows again later gets a
     * fresh pick rather than silently reusing this one. */
    set_pick_queued(dialog, 0);

    trace("respond", found ? "known-id" : "no-accept-id", outcome);
    if (outcome == PICK_PICKED && respond) {
        trace("respond-accept", NULL, accept);
        respond(dialog, accept);
    } else if (outcome == PICK_CANCELLED && respond) {
        respond(dialog, MSL_RESPONSE_CANCEL);
    } else {
        /* MSL could not answer. Show the app's own dialog after all - this
         * is the one path where the real show() happens, late. */
        void (*real_show)(gpointer) = real_symbol("gtk_widget_show");
        if (real_show) real_show(dialog);
    }
    if (unref) unref(dialog);
    return 0;   /* one shot */
}

/*
 * Swallows the show and queues the pick. Returns 1 if it took the dialog.
 *
 * Every GTK app calls these constantly, so the common case has to be cheap:
 * `enabled()` is a getenv and `is_chooser_dialog` two type checks, and both
 * fail immediately for ordinary widgets.
 */
/*
 * Whether to take over the non-blocking form as well.
 *
 * **Off by default, and it must stay that way until an app is found that it
 * actually completes.** The hook itself works - MSL Files replaces GIMP's
 * dialog, the person picks, and GIMP reads the chosen path back through the
 * interposed getters (traced 2026-09-29). But GIMP then does nothing with
 * it: no image opens and no error is printed. Its dialog was never shown, so
 * some state it needs was never built, and the person is left with a Open
 * that silently does nothing - which is worse than the Linux dialog they had
 * before, because that one worked.
 *
 * So the blocking form (`gtk_dialog_run`, verified end to end with Mousepad)
 * is on, and this is behind MSL_GTK_PICKER_SHOW=1 for whoever picks the
 * work up. What is left is making the dialog real enough for apps like GIMP
 * without it being visible: showing it off-screen is the obvious next thing
 * to try, the catch being that AppKit constrains window positions onto the
 * screen, so it may need mslgd's help rather than a `gtk_window_move`.
 */
static int show_hook_enabled(void)
{
    const char *value = getenv("MSL_GTK_PICKER_SHOW");
    return value && value[0] == '1' && value[1] == '\0';
}

static int intercept_show(gpointer widget)
{
    if (!show_hook_enabled()) return 0;
    if (in_pick || !enabled() || !widget || !is_chooser_dialog(widget)) return 0;
    if (pick_is_queued(widget)) return 1;   /* already ours; stay hidden */
    int found = 0;
    accept_response(widget, &found);
    if (!found) return 0;                   /* unknown response ids - leave it alone */

    gpointer (*ref)(gpointer) = any_symbol("g_object_ref");
    unsigned int (*idle_add)(GSourceFunc, gpointer) = any_symbol("g_idle_add");
    if (!ref || !idle_add) return 0;

    trace("show-intercepted", NULL, 0);
    set_pick_queued(widget, 1);
    ref(widget);                            /* survives until the idle runs */
    idle_add(pick_then_respond, widget);
    return 1;
}

void gtk_widget_show(gpointer widget)
{
    if (intercept_show(widget)) return;
    void (*real)(gpointer) = real_symbol("gtk_widget_show");
    if (real) real(widget);
}

void gtk_widget_show_all(gpointer widget)
{
    if (intercept_show(widget)) return;
    void (*real)(gpointer) = real_symbol("gtk_widget_show_all");
    if (real) real(widget);
}

void gtk_window_present(gpointer window)
{
    if (intercept_show(window)) return;
    void (*real)(gpointer) = real_symbol("gtk_window_present");
    if (real) real(window);
}

/* ------------------------------------------------------------------ */
/* The getters                                                         */
/* ------------------------------------------------------------------ */

gchar *gtk_file_chooser_get_filename(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    trace("get_filename", pick ? pick->paths[0] : "(not ours)", pick ? pick->count : -1);
    if (pick) return g_copy(pick->paths[0]);
    gchar *(*real)(gpointer) = real_symbol("gtk_file_chooser_get_filename");
    return real ? real(chooser) : NULL;
}

gchar *gtk_file_chooser_get_uri(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    if (pick) {
        gchar *(*to_uri)(const gchar *, const gchar *, gpointer) =
            any_symbol("g_filename_to_uri");
        if (to_uri) return to_uri(pick->paths[0], NULL, NULL);
    }
    gchar *(*real)(gpointer) = real_symbol("gtk_file_chooser_get_uri");
    return real ? real(chooser) : NULL;
}

gpointer gtk_file_chooser_get_file(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    trace("get_file", pick ? pick->paths[0] : "(not ours)", pick ? pick->count : -1);
    if (pick) {
        gpointer (*new_for_path)(const char *) = any_symbol("g_file_new_for_path");
        if (new_for_path) return new_for_path(pick->paths[0]);
    }
    gpointer (*real)(gpointer) = real_symbol("gtk_file_chooser_get_file");
    return real ? real(chooser) : NULL;
}

/* The list getters hand back a GSList the caller owns, matching GTK3's
 * contract: the elements are freed with g_free (or g_object_unref for
 * files) and the list with g_slist_free. */
static GSList *as_list(Pick *pick, int as_file, int as_uri)
{
    GSList *(*append)(GSList *, gpointer) = any_symbol("g_slist_append");
    if (!append) return NULL;
    gpointer (*new_for_path)(const char *) = as_file ? any_symbol("g_file_new_for_path") : NULL;
    gchar *(*to_uri)(const gchar *, const gchar *, gpointer) =
        as_uri ? any_symbol("g_filename_to_uri") : NULL;
    if ((as_file && !new_for_path) || (as_uri && !to_uri)) return NULL;

    GSList *list = NULL;
    for (int i = 0; i < pick->count; i++) {
        gpointer item = as_file ? new_for_path(pick->paths[i])
                      : as_uri  ? (gpointer)to_uri(pick->paths[i], NULL, NULL)
                                : (gpointer)g_copy(pick->paths[i]);
        if (item) list = append(list, item);
    }
    return list;
}

GSList *gtk_file_chooser_get_filenames(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    if (pick) { GSList *list = as_list(pick, 0, 0); if (list) return list; }
    GSList *(*real)(gpointer) = real_symbol("gtk_file_chooser_get_filenames");
    return real ? real(chooser) : NULL;
}

GSList *gtk_file_chooser_get_uris(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    if (pick) { GSList *list = as_list(pick, 0, 1); if (list) return list; }
    GSList *(*real)(gpointer) = real_symbol("gtk_file_chooser_get_uris");
    return real ? real(chooser) : NULL;
}

/*
 * GTK3 returns a GSList of GFile here; GTK4 returns a GListModel. The
 * wrapper is reachable in both, but `pick_of` can only be non-NULL on GTK3 -
 * nothing is ever attached otherwise - so a GTK4 caller always falls
 * through to the real function and gets the type it expects.
 */
GSList *gtk_file_chooser_get_files(gpointer chooser)
{
    Pick *pick = pick_of(chooser);
    trace("get_files", pick ? pick->paths[0] : "(not ours)", pick ? pick->count : -1);
    if (pick) { GSList *list = as_list(pick, 1, 0); if (list) return list; }
    GSList *(*real)(gpointer) = real_symbol("gtk_file_chooser_get_files");
    return real ? real(chooser) : NULL;
}

"""#
}
