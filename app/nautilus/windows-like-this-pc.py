# A "This PC" item in Files' right-click menu (on a folder's background),
# opening This PC from the windows-like-settings package. Nautilus has no way
# for an extension to add a sidebar place or a view of its own, so this is
# the way in from Files. Loaded only where nautilus-python is installed.
import shutil

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus


class ThisPCMenu(GObject.GObject, Nautilus.MenuProvider):
    def get_background_items(self, *args):
        if not shutil.which("windows-like-settings"):
            return []
        item = Nautilus.MenuItem(name="WindowsLike::ThisPC", label="This PC")
        item.connect("activate", self._open)
        return [item]

    def _open(self, *args):
        command = ["windows-like-settings", "--this-pc"]
        if shutil.which("uwsm-app"):
            command = ["uwsm-app", "--"] + command
        Gio.Subprocess.new(command, Gio.SubprocessFlags.NONE)
