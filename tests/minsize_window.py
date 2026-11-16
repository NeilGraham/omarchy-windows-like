"""A test window with a minimum size, as Firefox has one: python -I minsize_window.py <app-id> <min-width> <min-height>

Plain Gtk.Window (no Gtk.Application), so nothing registers on the session
bus: it only talks to the Wayland display it is given.
"""
import sys

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk  # noqa: E402

app_id, min_w, min_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
GLib.set_prgname(app_id)
Gtk.init()
window = Gtk.Window(title=app_id)
box = Gtk.Box()
box.set_size_request(min_w, min_h)
window.set_child(box)
loop = GLib.MainLoop()
window.connect('close-request', lambda *_: loop.quit() or False)
window.present()
loop.run()
