# Workspace modes

Implemented and installed locally on November 24, 2026, based on upstream commit `e25318b`.

## Settings and behavior

Open **Settings → Package → Windows & tabs** to choose the starting mode and apply it to all workspaces or selected workspace numbers. **Super + Shift + F12** toggles the focused numbered workspace. Each toggle persists across logins. Changing the starting mode or the effective selection clears the saved toggles.

- The project defaults to Windows-like on all workspaces, matching the previous behavior.
- This desktop starts Windows-like on workspace 1 and native Omarchy elsewhere. Snap Assist and floating by default are disabled in the user settings.
- The shared taskbar, dock, Start shortcuts, and global compositor appearance follow the focused monitor. Snapping, resizing, and Windows-like tab behavior use the window's workspace. Switching modes preserves existing windows and groups.

## Implementation

The starting policy lives under `workspaces` in `~/.config/omarchy-windows-like/settings.json`. The CLI saves per-workspace overrides under `~/.local/state/omarchy-windows-like/` and generates policy files for Quickshell and Hyprland. Workspace and monitor focus events synchronize the shared shell profile. The CLI saves the native bar, height, and dock preference so it can restore them when switching back.

The workspace-mode change also uses Hyprland's unbind followed by Omarchy's bind for **Super + Alt + Space**, replacing the native Apps shortcut while Windows-like Start is active. The floating setting uses rules for new windows on enabled workspaces.

## Local installation and verification

The installed shell plugin and native library were updated at user level. The Settings launcher uses the updated binary in `~/.local/bin/windows-like-settings`; the system package still supplies This PC. The pre-install files are in [the desktop backup](../windows-like-backup/workspace-mode-install.c3RMFt/).

- The native plugin and Settings app built successfully. All 32 Settings tests passed, along with the taskbar model tests.
- `bash tests/test_workspace_modes.sh` covered selected and all-workspace policies, persistence, and restoring the native bar and dock.
- `python -I tests/test_workspace_bindings.py native/drag-events/drag-events.so` verified native and Windows-like bindings, the physical shortcut through virtual keyboard events, and live bar switching in an isolated Hyprland session with the real Omarchy shell.
- After installation, the live compositor reported no configuration errors and showed the Windows-like taskbar on workspace 1. Mixed modes across multiple physical monitors were not tested.
