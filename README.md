# omarchy-windows-like

Make [Omarchy](https://omarchy.org) feel familiar to people coming from Windows.

Omarchy already has a Windows-like **floating** layout (Super + L cycles to it):
windows overlap, have title bars, and can be minimized to the dock. This
project builds on it with the window management Windows users reach for
without thinking.

## What you get

**A Windows 11 taskbar and Start menu** (or a classic Windows 10 layout).
Omarchy's bar moves to the bottom (or stays at the top), grows to taskbar
height, and is laid out like Windows 11: weather, the world clock and Omarchy's indicators
(passwordless sudo, screen recording, night light…) on the left, where
Windows keeps its weather; the Omarchy mark, your workspaces and your apps in
the middle (classic: all on the left, as on Windows 10); the tray on the right
with a two-line clock last, whose calendar opens above it. Which widgets go on
the left is `taskbar.leftWidgets` in settings.json; Omarchy's own workspace
numbers can come back there with *Show Omarchy's workspace row* in Settings.

- App buttons show pinned and running apps, with Windows 11's line under a
  running app and a longer accent line under the focused one. Click to open,
  bring forward, minimize, or step through an app's windows; right-click to
  pin, open another window, or close.
- **Workspaces**, right of the Omarchy mark: Omarchy's workspaces are what
  Windows calls virtual desktops, and this is its Task View. The button shows
  the number of the workspace you're on. Click it for your workspaces along
  the taskbar, each a small picture of the screen: your background with every
  window where it is, as it looks, and the app's icon on it. Click a
  workspace to go there, or a window in one to go straight to that window;
  drag a window onto another workspace (or onto **+**) to move it there;
  **+** for a new workspace, and click a name (or right-click a workspace) to
  rename it, as on Windows. The wheel steps through them. Names are kept in
  settings.json (`desktops.names`) and apply to that workspace on every
  monitor.
- Drag an app button sideways to move it; the others make room. Pinned apps
  keep their new order (it is saved with the pins); a running app that isn't
  pinned keeps its place until the shell restarts, as on Windows.
- When the buttons no longer fit beside the tray, the last ones go behind a
  **•••** button, which opens them in a flyout, as on Windows 11.
- **Start** (tap **Super** on its own, or click the mark): search, pinned
  apps, All apps A–Z, and Recommended — apps you used and installed recently,
  leaving out the ones pinned to Start — with your name and power options.
  **Super + Alt + Space** opens All apps.
- The bar reserves its space, so snapped, stretched and maximized windows
  never end up behind it. Omarchy's dock steps aside while the taskbar is on.

**Settings**, an app in the launcher laid out like Windows 11's, turns each
part on or off under **Package**, and sets up your monitors under **Display**
the way Windows does, all on one page: arrange them by dragging, extend,
duplicate or turn them off, and change scale, resolution, orientation,
refresh rate, variable refresh rate, HDR and color, with *Keep these display
settings?* for anything that could leave a screen blank.
**This PC** shows your folders, drives and network locations with the space
free on each, like Windows' This PC, and opens them in Files (which gets a
*This PC* item in its right-click menu). Both come in one package (see
[app/README.md](app/README.md)). Settings live in
`~/.config/omarchy-windows-like/settings.json`; `omarchy-windows-like apply`
applies them, and turning the taskbar off brings back Omarchy's bar exactly as
it was.

**Snapping by dragging** (by the title bar, or with Super + drag):

| Drop the window…                     | It becomes…                     |
|--------------------------------------|---------------------------------|
| at the left or right edge            | that half of the screen         |
| in any corner                        | that quarter                    |
| at the very top edge                 | maximized                       |
| on the layout picker near the top    | that zone (halves, ⅔ + ⅓, thirds, ½ + two quarters, quarters) |

Next to a window that stands the full height of the screen (one snapped and
then resized, or one stretched from top to bottom), a snapped window fills the
room beside it instead of exactly half — so a window stretched down the middle
and two snapped to the sides stand three side by side.

Snapped windows meet each other and the edges of the screen, with no gaps,
as on Windows (`snapping.gaps`, *Leave gaps between snapped windows* in
Settings, keeps Hyprland's gaps instead).

A preview shows where the window will land before you let go. After a snap,
**snap assist** offers the other windows on that workspace (minimized ones
included) for the rest of the layout (Tab to skip a space, Esc to stop). Dragging a snapped window away gives it back the
size it had before.

**Smooth motion:** a snapped window glides into its place with a short
decelerating ease (220 ms, like Windows), animated by Hyprland every frame at
your monitor's refresh rate (this is Hyprland's window-move animation, so
other moves and resizes Hyprland animates get the same ease). Start slides up from the taskbar (down from a bar
at the top) as it fades in and goes back quicker than it came; the snap
preview and layout picker fade in and out. `animations.enabled` in
settings.json turns all of this off (windows then land at once), and so does
Omarchy's own switch for animations, which turns them off everywhere.

**Full-height stretch:** drag a window's top or bottom border to the edge of
the screen and it stretches from top to bottom, keeping its width.

**Resizing snapped windows together:** windows standing side by side (or one
above another) share the edge between them. Hover it and the cursor becomes a
split arrow; drag it and every window on that edge resizes, like Windows 11.
The vertical line through four quarters moves all four; a horizontal line
moves only the two windows of its column.

**Resizing like Windows:** dragging a window's side resizes it in that
direction only (Hyprland on its own always resizes from the nearest corner),
corners resize both ways, and the top edge above the title bar shows a resize
cursor and resizes the top, just like the other three sides.

**Tabs for any window** (Mac Terminal style), in the title bar: the app's logo
sits where its name was (rest the pointer on it for the name), then the tabs, then a **+** that opens another
window of the same app as a new tab, with the minimize, maximize and close
buttons left where they are at the right. foot shows its tab from the start;
other apps once they have a second tab. Each tab has a ✕ (on the active tab,
and on any tab you hover), middle-click closes a tab, dragging the logo or the
empty title bar moves the window, and when tabs no longer fit they scroll
sideways with the wheel or touchpad. Tabs drag like in Windows Terminal: along
the tab strip to reorder them, or out of it to tear one off into a window of
its own, which follows the pointer (and snaps like any dragged window). A
window dragged by its tab (a torn-off tab, or a window with one tab, which its
tab simply moves) joins another window's tabs when dropped on them, where it
is dropped. A double click on a tab maximizes, as on the title bar. Opening
and closing tabs is instant, like switching them (no window animations), and
takes no room from the window. A window without a title bar (a tiled one) gets
a tab bar of its own under its border once it has a second tab. Tabs are
Hyprland groups underneath, so Omarchy's group shortcuts (Super + G, Super +
Alt + 1–5…) work on them too.

In **foot**, Mac Terminal's shortcuts work with Ctrl in place of Cmd:

| Keys | Action |
|---|---|
| Ctrl + T | New tab, in the current tab's folder |
| Ctrl + W | Close tab |
| Ctrl + 1 … 8, Ctrl + 9 | Go to tab 1 … 8, last tab |
| Ctrl + Tab, Ctrl + Shift + Tab | Next / previous tab |
| Ctrl + Shift + ] / [ | Next / previous tab |

Every other app still gets these keys (Ctrl + T still opens a browser tab).
In foot, fzf's file picker moves from Ctrl + T to **Alt + T**, and Alt +
Backspace deletes a word. Terminal tabs are named after what runs in them: the
folder while the shell waits, the program (`nvim README.md`, `ssh server`,
`claude`) while one runs, or the title the program sets itself.

**Super + Z** opens the layout picker for the focused window, like Win + Z.

**Floating by default:** setup (and `apply`) makes floating the default
layout for every workspace, as windows behave on Windows. Super + L still
switches a single workspace to tiling or scrolling; *Floating by default* in
Settings turns it off.

## Install

Requires Omarchy 4 (Hyprland 0.56+ with the Lua config) and a compiler
(`omarchy pkg add base-devel` if `g++` is missing).

```sh
omarchy plugin add https://github.com/NeilGraham/omarchy-windows-like --enable
~/.config/omarchy/plugins/io.github.neilgraham.windows-like/bin/omarchy-windows-like setup
```

`setup`:

1. builds the small `drag-events` Hyprland plugin for your Hyprland version
   into `~/.local/lib/omarchy-windows-like/`,
2. writes `~/.config/hypr/windows-like.lua` and adds
   `require("hypr.windows-like")` to `~/.config/hypr/hyprland.lua` (after
   backing it up),
3. adds an Alt + T binding for fzf's file picker to `~/.bashrc`,
4. installs a `post-update` hook that rebuilds the plugin after
   `omarchy update` brings a new Hyprland,
5. makes floating the default workspace layout,
6. links `omarchy-windows-like` into `~/.local/bin`.

Then, for the settings app: `omarchy-windows-like install-app` (it asks for
your password to install the package).

Other commands: `omarchy-windows-like status`, `omarchy-windows-like apply`,
`omarchy-windows-like build`, `omarchy-windows-like uninstall` (which also
restores Omarchy's bar and dock).

After updating (`omarchy plugin update`, or `git pull` in a development
checkout), run `omarchy-windows-like build`: it rebuilds the native plugin
and restarts the shell, which keeps `WindowsLike.qml` loaded and doesn't
notice changes made through a linked plugin folder.

### Settings

```sh
omarchy-shell windowslike drag off     # stop snapping by dragging (on/off/status)
omarchy-shell windowslike assist off   # no snap assist after a snap (on/off/status)
```

Both are saved in `~/.config/omarchy/shell.json`.

## How it works

Two parts, each kept as small as possible:

- **`native/drag-events/`** — a small Hyprland plugin. Hyprland has no
  event for "a window is being dragged", and Omarchy's title bars swallow the
  mouse button, so nothing outside the compositor can see a title-bar drag.
  The plugin watches Hyprland's drag controller (for dragging it hooks
  nothing and changes no input) and reports `start` / `move` / `end` with the pointer and window
  position as `custom` IPC events. It also restarts border resizes on the
  side that was pressed and sets the border cursor from the whole window,
  title bar included. And it draws tabs in the title bar (`tabs.cpp`), in
  place of Hyprland's group bar: the one place it takes input, from a hook on
  Hyprland's mouse button handler, so a press on a tab, its ✕ or **+** goes to
  the tab and not to the title bar under it (tab drags are run from there).
- **`WindowsLike.qml`** — an Omarchy shell plugin (Quickshell) that listens for
  those events, draws the preview and the layout picker, and places windows
  with `hyprctl eval`. Gaps, border size and title bar height are read from
  Hyprland, so snapped windows line up with the rest of Omarchy.

Without the native plugin nothing snaps by dragging, but Super + Z still works.

## Tests

The tests run a disposable nested Hyprland in a window, drive it with a
virtual pointer, and never touch your session:

```sh
make -C native/drag-events
python -I tests/test_drag_events.py native/drag-events/drag-events.so
python -I tests/test_snapping.py native/drag-events/drag-events.so
python -I tests/test_edges.py native/drag-events/drag-events.so
python -I tests/test_tabs.py native/drag-events/drag-events.so
python -I tests/test_tab_drag.py native/drag-events/drag-events.so
python -I tests/test_taskbar_space.py native/drag-events/drag-events.so
python -I tests/test_keys.py native/drag-events/drag-events.so
python -I tests/test_snap_fill.py native/drag-events/drag-events.so
python -I tests/test_joint_resize.py native/drag-events/drag-events.so
node --test tests/taskbar_model.test.js
app/bin/test
```

`tests/preview_shell.py` runs Omarchy's real shell, with the taskbar applied
to a copy of your shell config, inside a nested Hyprland and takes screenshots
of the taskbar, Start, All apps and the calendar
(`python -I tests/preview_shell.py native/drag-events/drag-events.so /tmp/preview classic bottom`).

`tests/keyboard.c` is a virtual keyboard with the standard US keymap: wtype
uploads a keymap of its own, which Hyprland's key bindings don't match.

Hyprland 0.56 can crash while shutting down with grouped windows still open
(it does so without any plugin loaded), so the harness closes its windows
before stopping the nested compositor.

`test_snapping.py` runs `WindowsLike.qml` in its own Quickshell with stand-ins
for Omarchy's theme modules (`tests/qs-stub/`), drags real windows by their
title bars and borders, and checks where they land. Screenshots go to
`/tmp/owl-test-snapping/`.

## Roadmap

- Win + arrow keys to snap and maximize from the keyboard
- Restore the pre-snap size as soon as a snapped window is dragged (not on drop)
- Tab shortcuts for every app (e.g. Super + Alt + T / W), not just foot
- Alt + Tab window switcher with previews; Win + D to show the desktop
- Taskbar polish on top of Omarchy's dock
- Multi-monitor testing (shared edges already need a short pause before snapping)

## Credits

See [CREDITS.md](CREDITS.md). The layout picker and snap assist started from
[n0rthstar88/omarchy-snap-layouts](https://github.com/n0rthstar88/omarchy-snap-layouts) (MIT).

## License

[MIT](LICENSE)
