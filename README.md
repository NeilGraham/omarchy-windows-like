# omarchy-windows-like

Make [Omarchy](https://omarchy.org) feel familiar to people coming from Windows.

Omarchy already has a Windows-like **floating** layout (Super + L cycles to it):
windows overlap, have title bars, and can be minimized to the dock. This
project builds on it with the window management Windows users reach for
without thinking.

## What you get

**A Windows 11 taskbar and Start menu** (or a classic Windows 10 layout).
Omarchy's bar moves to the bottom (or stays at the top), grows to taskbar
height, and is laid out like Windows: workspaces on the left, the Omarchy mark
and your apps in the middle (classic: on the left), the tray and indicators on
the right with a two-line clock last, whose calendar opens above it.

- App buttons show pinned and running apps, with Windows 11's line under a
  running app and a longer accent line under the focused one. Click to open,
  bring forward, minimize, or step through an app's windows; right-click to
  pin, open another window, or close.
- **Start** (tap **Super** on its own, or click the mark): search, pinned
  apps, All apps A–Z, and Recommended — apps you used and installed recently —
  with your name and power options. **Super + Alt + Space** opens All apps.
- The bar reserves its space, so snapped, stretched and maximized windows
  never end up behind it. Omarchy's dock steps aside while the taskbar is on.

**Windows-like Settings**, an app in the launcher, turns each part on or off
(see [app/README.md](app/README.md)). Settings live in
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

A preview shows where the window will land before you let go. After a snap,
**snap assist** offers your other windows for the rest of the layout (Tab to
skip a space, Esc to stop). Dragging a snapped window away gives it back the
size it had before.

**Full-height stretch:** drag a window's top or bottom border to the edge of
the screen and it stretches from top to bottom, keeping its width.

**Resizing like Windows:** dragging a window's side resizes it in that
direction only (Hyprland on its own always resizes from the nearest corner),
corners resize both ways, and the top edge above the title bar shows a resize
cursor and resizes the top, just like the other three sides.

**Tabs for any window** (Mac Terminal style): a window gets a tab bar under its
title bar as soon as it has a second tab, and loses it again at one. Each tab
has a ✕ (on the active tab, and on any tab you hover), the **+** at the right
opens another window of the same app as a new tab, middle-click closes a tab,
and when tabs no longer fit the bar scrolls sideways with the wheel or
touchpad. Opening and closing tabs is instant, like switching them (no
window animations), and the window's frame stays put as the tab bar appears
or goes: the bar takes its room from the content. Tabs are Hyprland groups underneath, so Omarchy's group shortcuts
(Super + G, Super + Alt + 1–5…) work on them too.

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

**Floating by default:** setup makes floating the default layout. Super + L
still switches a single workspace to tiling or scrolling.

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
  The plugin watches Hyprland's drag controller (it hooks nothing and changes
  no input) and reports `start` / `move` / `end` with the pointer and window
  position as `custom` IPC events. It also restarts border resizes on the
  side that was pressed and sets the border cursor from the whole window,
  title bar included; it never cancels or redirects a click. And it draws the
  tab bar for grouped windows (`tabs.cpp`), in place of Hyprland's group bar.
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
python -I tests/test_taskbar_space.py native/drag-events/drag-events.so
python -I tests/test_keys.py native/drag-events/drag-events.so
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
- Drag tabs to reorder them, or out into a window of their own
- Tab shortcuts for every app (e.g. Super + Alt + T / W), not just foot
- Alt + Tab window switcher with previews; Win + D to show the desktop
- Taskbar polish on top of Omarchy's dock
- Multi-monitor testing (shared edges already need a short pause before snapping)

## Credits

See [CREDITS.md](CREDITS.md). The layout picker and snap assist started from
[n0rthstar88/omarchy-snap-layouts](https://github.com/n0rthstar88/omarchy-snap-layouts) (MIT).

## License

[MIT](LICENSE)
