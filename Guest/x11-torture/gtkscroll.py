#!/usr/bin/env python3
"""GTK3 scroll probe: prints every scroll event GTK hands a widget.

    GDK_CORE_DEVICE_EVENTS=1 python3 gtkscroll.py [native]

`native` gives the drawing area its own X window (gdk_window_ensure_native),
which is how Firefox's MozContainer receives input.
"""
import sys, time
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

w = Gtk.Window(title="gtkscroll")
w.set_default_size(500, 400)
area = Gtk.DrawingArea()
area.add_events(Gdk.EventMask.SCROLL_MASK | Gdk.EventMask.SMOOTH_SCROLL_MASK | Gdk.EventMask.BUTTON_PRESS_MASK)
def on_scroll(widget, ev):
    ok, dx, dy = ev.get_scroll_deltas()
    print("%.3f scroll dir=%s deltas=%s time=%d src=%s emulated=%s win_smooth=%s state=%s" % (
          time.time(), ev.direction.value_nick, (dx, dy) if ok else None, ev.time,
          ev.get_source_device().get_name() if ev.get_source_device() else None,
          ev.get_pointer_emulated(), bool(ev.window.get_events() & Gdk.EventMask.SMOOTH_SCROLL_MASK),
          int(ev.state)), flush=True)
    return True
area.connect("scroll-event", on_scroll)
area.connect("button-press-event", lambda w_, e: print("press", e.button, flush=True))
w.add(area)
w.connect("destroy", Gtk.main_quit)
w.show_all()
if "native" in sys.argv:
    area.get_window().ensure_native()
    print("native child:", hex(area.get_window().get_xid()), flush=True)
Gtk.main()
