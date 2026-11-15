-- omarchy-windows-like: the Hyprland side.
--
-- Loaded from ~/.config/hypr/windows-like.lua, which `omarchy-windows-like
-- setup` writes and requires from ~/.config/hypr/hyprland.lua.

-- The drag-events plugin tells the shell when a window is being dragged; see
-- native/drag-events/main.cpp. It is built for the running Hyprland by setup,
-- and again after `omarchy update` by the post-update hook.
local home = os.getenv("HOME") or ""
local drag_events = home .. "/.local/lib/omarchy-windows-like/drag-events.so"
local file = io.open(drag_events, "r")
if file then
  file:close()
  hl.plugin.load(drag_events)
end

-- Super + Z: the snap layout picker for the focused window, like Win + Z.
o.bind("SUPER + Z", "Snap layouts", hl.dsp.event("windows-like-toggle"))
