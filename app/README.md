# Settings and This PC

Settings laid out like Windows 11's: a search box and the categories down the
left, the current page on the right under a large title, its settings in
cards.

- **Display** shows the monitors Hyprland sees (`hyprctl monitors all -j`):
  where they stand, and each one's name, connector, resolution, refresh rate
  and scale. When the separate Displays app (`displays`) is installed, *Open
  Displays* brings it forward or starts it (`omarchy-launch-or-focus displays
  'uwsm-app -- displays'`) to change them. Without it the summary stays, and
  the page says where Hyprland takes the settings from instead.
- **Package** chooses what [omarchy-windows-like](../README.md) changes, a
  page for each part: **Taskbar & Start** (Windows 11 or classic, bottom or
  top, height, workspaces, Super opening Start, pinned apps), **Snapping**
  (each kind of snapping, snap layouts, snap assist) and **Windows & tabs**
  (floating by default, resizing from any side or together, tabs and their
  terminal shortcuts, and animation effects: windows gliding into place when
  they snap, the snap preview and layouts fading, Start sliding up). Reset to defaults is on the Package page.

Every change is saved to `~/.config/omarchy-windows-like/settings.json` as you
make it and applied right away with `omarchy-windows-like apply`. The shell
picks up the file live; pins made from the Start menu show up here too.

## This PC

**This PC** (`windows-like-settings --this-pc`, its own launcher entry) is
Windows 11's This PC for Files:

- **Folders**: Desktop, Documents, Downloads, Music, Pictures and Videos, as
  your XDG user dirs name them (one that is just your home folder is left out).
- **Devices and drives**: each filesystem worth opening, with a bar of the
  space used (red once it's 90 % full) and "X free of Y". The system drive
  shows once as *System (/)*, however many subvolumes it's mounted as; other
  drives show their label and where they're mounted. USB drives, SD cards,
  discs and phones (from gvfs) have icons of their own. Drives that aren't
  mounted show their size without a bar, and are mounted when opened. Left
  out: swap and zram, loop devices, EFI, boot, Microsoft reserved and
  recovery partitions, LVM, RAID and LUKS containers (the filesystem inside an
  unlocked one shows instead) and empty card readers.
- **Network locations**: kernel mounts (SMB/CIFS, NFS, SSHFS, WebDAV) and
  shares opened in Files (gvfs).

Double-click or Enter opens one in Files; right-click (or the Menu key) offers
Open, Eject for removable drives (unmount, lock if encrypted, power off) and
Properties: file system, device, disk, connection, and the space used, free
and in all. Mounting and ejecting go through `udisksctl`, so polkit asks for a
password where it needs one, and any failure shows at the top of the window.
The list follows drives being plugged in, mounted and unmounted as it happens,
and the space used every few seconds.

Files (Nautilus) has no way for an extension to add a place to its sidebar or
a view of its own, so the package adds a *This PC* item to Files' right-click
menu on a folder's background instead (`nautilus/windows-like-this-pc.py`; it
needs `python-nautilus`, and Files picks it up the next time it starts:
`nautilus -q`).

Both windows follow the Omarchy theme live: its accent and colors (light
themes too) and Hyprland's rounding.

## Install

```sh
omarchy-windows-like install-app     # or: app/bin/install
```

It builds the app and installs it as an Arch package (`makepkg -fsi`, which
asks for your password), so **Settings** and **This PC** appear in the
launcher and in Start. The package, binary and Settings' desktop entry keep
the id `windows-like-settings`, so pins and Start's settings button keep
working; This PC is `windows-like-this-pc`.

## Shortcuts

| Key | Action |
|---|---|
| Ctrl + F | Find a setting (↑ ↓ to choose, Enter to open, Esc to clear) |
| Ctrl + 1, 2 | Go to a category |
| Ctrl + Tab, Ctrl + Shift + Tab | Next / previous category |
| Alt + ← | Back |
| Space | Toggle the focused setting |
| ? | Show or hide the shortcuts |
| Q | Quit |

In This PC:

| Key | Action |
|---|---|
| Arrow keys | Move between folders and drives |
| Enter | Open (mounting the drive first) |
| Menu, Shift + F10 | Open, Eject, Properties |
| Alt + Enter | Properties |
| F5 | Refresh |
| ? | Show or hide the shortcuts |
| Q | Quit |

## Development

```sh
bin/build    # build/windows-like-settings
bin/test     # Qt tests, offscreen (fake lsblk, udisksctl and the rest: no real drive is touched)
```

C++ reads and writes the settings and runs `apply` (`src/backend.*`), asks
Hyprland about the monitors and opens Displays (`src/monitors.*`), and finds
This PC's drives (`src/drives.*`: `lsblk -J` for the drives, which gives the
whole disk, partition, LUKS and LVM tree with labels, partition types, mount
points and space in one call and is easy to test against canned output in
`tests/data/`; `findmnt` and gvfs's FUSE folder for network locations). QML
is the window (`src/Main.qml`), a page per file (`src/*Page.qml`) built from
cards (`src/SettingsCard.qml` and the switch, choice, slider and link cards
on it); This PC is `src/ThisPC.qml` and its `src/Tile.qml`. The theme and language handling follow Omarchy's own apps (Omacut,
Monologue).

To add a category, add it to `categories` in `Main.qml` and add its page to
`pages` there with the same `pageId`; a page under it names it as its
`parentId`. Search finds every card on every page by itself.
