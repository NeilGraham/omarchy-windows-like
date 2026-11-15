-- omarchy-windows-like: the Hyprland side.
--
-- Loaded from ~/.config/hypr/windows-like.lua, which `omarchy-windows-like
-- setup` writes and requires from ~/.config/hypr/hyprland.lua.

-- The native plugin: drag events for snapping, side resizing, and tabs. It is
-- built for the running Hyprland by setup, and again after `omarchy update`
-- by the post-update hook. See native/drag-events/.
local home = os.getenv("HOME") or ""
-- OMARCHY_WINDOWS_LIKE_NATIVE points tests at a fresh build.
local native = os.getenv("OMARCHY_WINDOWS_LIKE_NATIVE") or (home .. "/.local/lib/omarchy-windows-like/drag-events.so")
local file = io.open(native, "r")
if file then
  file:close()
  hl.plugin.load(native)
end

-- Super + Z: the snap layout picker for the focused window, like Win + Z.
o.bind("SUPER + Z", "Snap layouts", hl.dsp.event("windows-like-toggle"))

-- ---------- Tabs ----------

-- Tabs are Hyprland groups drawn by the plugin's own tab bar, so Hyprland's
-- group bar stays off. New windows only join a group when asked to (a new
-- tab), and a new tab goes to the end, like on a Mac.
hl.config({ group = { auto_group = false, insert_after_current = false, groupbar = { enabled = false } } })

-- The tab bar follows the Omarchy theme: the active tab takes the title bar's
-- color so the two read as one, inactive tabs sit darker.
local function theme_colors()
  local colors = {}
  local theme = io.open(home .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if theme then
    for line in theme:lines() do
      local key, value = line:match('^%s*([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"')
      if key then
        colors[key] = value
      end
    end
    theme:close()
  end
  return colors
end

if hl.plugin.windows_like then
  local c = theme_colors()
  local function rgb(name, fallback)
    return "rgb(" .. (c[name] or fallback) .. ")"
  end
  local titlebar = c.lighter_background
  if not titlebar or titlebar == c.background then
    titlebar = c.selection
  end
  hl.config({
    plugin = {
      windows_like = {
        tab_height = 28,
        tab_font = "monospace",
        tab_font_size = 12,
        ["col.active"] = "rgb(" .. (titlebar or "2c2c2e") .. ")",
        ["col.bar"] = rgb("dark_background", "161618"),
        ["col.hover"] = rgb("background", "1c1c1e"),
        ["col.text"] = rgb("foreground", "f5f5f7"),
        ["col.text_inactive"] = rgb("dark_foreground", "98989d"),
        ["col.separator"] = rgb("selection", "3a3a3c"),
        ["col.button_hover"] = rgb("selection", "3a3a3c"),
      },
    },
  })
end

-- Mac Terminal's tab shortcuts, with Ctrl for Cmd. They act only in the apps
-- matching plugin:windows_like:tab_apps (foot for now); everywhere else the
-- key goes on to the app untouched, so Ctrl + T still opens a browser tab.
local function tab(action, n)
  return function()
    local plugin = hl.plugin.windows_like
    if plugin and plugin.tab(action, n) then
      return
    end
    return { pass_event = true }
  end
end

hl.bind("CTRL + T", tab("new"), { description = "New tab" })
hl.bind("CTRL + W", tab("close"), { description = "Close tab" })
for n = 1, 9 do
  hl.bind("CTRL + " .. n, tab("select", n), { description = n == 9 and "Last tab" or ("Tab " .. n) })
end
hl.bind("CTRL + TAB", tab("next"), { description = "Next tab" })
hl.bind("CTRL + SHIFT + TAB", tab("prev"), { description = "Previous tab" })
hl.bind("CTRL + SHIFT + bracketright", tab("next"), { description = "Next tab" })
hl.bind("CTRL + SHIFT + bracketleft", tab("prev"), { description = "Previous tab" })
