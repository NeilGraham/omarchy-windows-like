# Windows-like Settings

Choose what [omarchy-windows-like](../README.md) changes: the taskbar and
Start (Windows 11 or classic, bottom or top, height, workspaces, Super opening
Start, pinned apps), each kind of snapping, tabs and their terminal
shortcuts, resizing from any side, and floating windows by default.

Every change is saved to `~/.config/omarchy-windows-like/settings.json` as you
make it and applied right away with `omarchy-windows-like apply`. The shell
picks up the file live; pins made from the Start menu show up here too.

## Install

```sh
omarchy-windows-like install-app     # or: app/bin/install
```

It builds the app and installs it as an Arch package (`makepkg -fsi`, which
asks for your password), so it appears in the launcher and in Start.

## Shortcuts

| Key | Action |
|---|---|
| Ctrl + 1, 2, 3 | Go to a page |
| Ctrl + Tab | Next page |
| Space | Toggle the focused setting |
| ? | Show or hide the shortcuts |
| Q | Quit |

## Development

```sh
bin/build    # build/windows-like-settings
bin/test     # Qt tests, offscreen
```

C++ (`src/backend.*`) reads and writes the settings and runs `apply`; QML
(`src/Main.qml`) is the window. The theme and language handling follow
Omarchy's own apps (Omacut, Monologue).
