/* Layer 0: event delivery - ConfigureNotify (resize), ButtonPress/
 * Release, KeyPress, PropertyNotify (ChangeProperty/DeleteProperty), and
 * a ClientMessage round trip via SendEvent-to-self. No pixels checked
 * here - this test's PASS/FAIL is entirely "did every expected event
 * arrive, with the right fields" (asserted in C, exit(1) on any
 * mismatch), snapshotting only a small marker color at the very end so
 * the harness (which always pixel-diffs a snapshot) has something to
 * compare. A hang here (caught by the harness's `timeout 5`) means an
 * expected event never arrived at all.
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static Display *dpy;
static Window win;

static void fail(const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    exit(1);
}

/* Blocks until an event of `type` arrives, discarding anything else
 * (mirrors how a real client's event loop would skip events it doesn't
 * care about right now) - but bails out via the harness's own `timeout`
 * if the expected event never shows up, rather than looping forever. */
static void wait_for(int type, XEvent *out) {
    for (;;) {
        XNextEvent(dpy, out);
        if (out->type == type) return;
    }
}

int main(void) {
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    win = XCreateSimpleWindow(dpy, root, 0, 0, 150, 100, 0,
                               BlackPixel(dpy, screen), WhitePixel(dpy, screen));
    XSelectInput(dpy, win,
                 ExposureMask | StructureNotifyMask | ButtonPressMask | ButtonReleaseMask |
                 KeyPressMask | PropertyChangeMask);
    XMapWindow(dpy, win);

    XEvent ev;
    wait_for(Expose, &ev);

    GC gc = XCreateGC(dpy, win, 0, NULL);
    XSetForeground(dpy, gc, 0x00FFFFFF);
    XFillRectangle(dpy, win, gc, 0, 0, 150, 100);
    XFlush(dpy);

    /* --- ConfigureNotify: resize the window, expect a matching notify. --- */
    XResizeWindow(dpy, win, 220, 130);
    XFlush(dpy);
    wait_for(ConfigureNotify, &ev);
    if (ev.xconfigure.width != 220 || ev.xconfigure.height != 130) {
        fprintf(stderr, "ConfigureNotify size mismatch: got %dx%d\n",
                ev.xconfigure.width, ev.xconfigure.height);
        fail("ConfigureNotify");
    }

    /* --- ButtonPress/Release: synthesize via SendEvent (no real pointer
     * hardware in this headless test) - exercises the exact delivery path
     * a real click would, just without needing actual input hardware. --- */
    XButtonEvent be;
    memset(&be, 0, sizeof(be));
    be.type = ButtonPress;
    be.display = dpy;
    be.window = win;
    be.root = root;
    be.same_screen = True;
    be.button = Button1;
    be.x = 10; be.y = 10;
    XSendEvent(dpy, win, False, ButtonPressMask, (XEvent *)&be);
    XFlush(dpy);
    wait_for(ButtonPress, &ev);
    if (ev.xbutton.button != Button1) fail("ButtonPress button field");

    be.type = ButtonRelease;
    XSendEvent(dpy, win, False, ButtonReleaseMask, (XEvent *)&be);
    XFlush(dpy);
    wait_for(ButtonRelease, &ev);

    /* --- KeyPress via SendEvent, same reasoning as ButtonPress above. --- */
    XKeyEvent ke;
    memset(&ke, 0, sizeof(ke));
    ke.type = KeyPress;
    ke.display = dpy;
    ke.window = win;
    ke.root = root;
    ke.same_screen = True;
    ke.keycode = 38; /* 'a' on a typical evdev/xkb keycode map - value itself isn't asserted, just that it round-trips */
    XSendEvent(dpy, win, False, KeyPressMask, (XEvent *)&ke);
    XFlush(dpy);
    wait_for(KeyPress, &ev);
    if (ev.xkey.keycode != 38) fail("KeyPress keycode field");

    /* --- PropertyNotify: ChangeProperty then DeleteProperty, expect one
     * notify each, with the right state (NewValue=0/Deleted=1). --- */
    Atom testAtom = XInternAtom(dpy, "MSL_TEST_PROPERTY", False);
    const char *value = "hello";
    XChangeProperty(dpy, win, testAtom, XA_STRING, 8, PropModeReplace,
                     (unsigned char *)value, (int)strlen(value));
    XFlush(dpy);
    wait_for(PropertyNotify, &ev);
    if (ev.xproperty.atom != testAtom || ev.xproperty.state != PropertyNewValue) {
        fail("PropertyNotify (ChangeProperty)");
    }

    XDeleteProperty(dpy, win, testAtom);
    XFlush(dpy);
    wait_for(PropertyNotify, &ev);
    if (ev.xproperty.atom != testAtom || ev.xproperty.state != PropertyDelete) {
        fail("PropertyNotify (DeleteProperty)");
    }

    /* --- ClientMessage round trip via SendEvent-to-self. --- */
    Atom msgType = XInternAtom(dpy, "MSL_TEST_CLIENT_MESSAGE", False);
    XClientMessageEvent cm;
    memset(&cm, 0, sizeof(cm));
    cm.type = ClientMessage;
    cm.window = win;
    cm.message_type = msgType;
    cm.format = 32;
    cm.data.l[0] = 0xABCD1234;
    XSendEvent(dpy, win, False, NoEventMask, (XEvent *)&cm);
    XFlush(dpy);
    wait_for(ClientMessage, &ev);
    if (ev.xclient.message_type != msgType || (unsigned)ev.xclient.data.l[0] != 0xABCD1234u) {
        fail("ClientMessage round trip");
    }

    /* All assertions passed - paint a marker color so the harness has a
     * deterministic pixel to diff, proving this point was actually reached. */
    XSetForeground(dpy, gc, 0x0000FF00); /* green = all events verified */
    XFillRectangle(dpy, win, gc, 0, 0, 220, 130);
    XFlush(dpy);
    usleep(300 * 1000);

    fprintf(stderr, "all events verified OK\n");

    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
