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

-- Settings: ~/.config/omarchy-windows-like/settings.json, which
-- `omarchy-windows-like apply` (run by Windows-like Settings) turns into this
-- Lua table. Missing keys fall back to the defaults below.
-- OMARCHY_WINDOWS_LIKE_SETTINGS points tests at a settings file of their own.
local settings = {}
local settings_path = os.getenv("OMARCHY_WINDOWS_LIKE_SETTINGS") or (home .. "/.config/omarchy-windows-like/settings.lua")
local settings_file = io.open(settings_path, "r")
if settings_file then
  settings_file:close()
  local ok, loaded = pcall(dofile, settings_path)
  if ok and type(loaded) == "table" then
    settings = loaded
  end
end

-- setting("tabs.enabled", true)
local function setting(path, fallback)
  local value = settings
  for key in string.gmatch(path, "[^.]+") do
    if type(value) ~= "table" then
      return fallback
    end
    value = value[key]
  end
  if value == nil then
    return fallback
  end
  return value
end

-- The shared shell presentation follows the focused monitor. The native
-- plugin receives the policy for all numbered workspaces.
local command = ...
local policy = settings.workspacePolicy or {}
local overrides = policy.overrides or {}
local function workspace_enabled(id)
  local override = overrides[tostring(id)]
  if override ~= nil then return override == "windows-like" end
  if policy.startMode == "native" then return false end
  if policy.scope ~= "selected" then return true end
  for _, selected in ipairs(policy.selected or {}) do
    if selected == id then return true end
  end
  return false
end

local workspace = (hl.get_active_workspace and hl.get_active_workspace()) or {}
local active = workspace_enabled(workspace.id)
if command then
  local quoted = "'" .. command:gsub("'", "'\\''") .. "'"
  local function sync_mode()
    hl.exec_cmd(quoted .. " sync-mode")
  end
  hl.on("workspace.active", sync_mode)
  hl.on("monitor.focused", sync_mode)
  hl.timer(sync_mode, { type = "oneshot", timeout = 100 })
  hl.bind("SUPER + SHIFT + F12", function()
    local focused = hl.get_active_workspace()
    if focused and focused.id > 0 then
      hl.exec_cmd(quoted .. " toggle-mode " .. tostring(focused.id))
    end
  end, { description = "Toggle Windows-like workspace mode" })
end

-- Super + Z: the snap layout picker for the focused window, like Win + Z.
if active and setting("general.superZ", true) then
  o.bind("SUPER + Z", "Snap layouts", hl.dsp.event("windows-like-toggle"))
end

-- ---------- Start menu ----------

if active and setting("taskbar.enabled", true) then
  -- Tapping Super alone opens Start, like Windows. As a release bind on the
  -- key that is itself the modifier, Hyprland fires it only when nothing else
  -- was pressed in between: Super + anything else shadows it.
  if setting("start.superOpens", true) then
    hl.bind("SUPER + Super_L", hl.dsp.event("windows-like-start"), { release = true, description = "Start menu" })
  end
  -- Omarchy's app grid lives in its dock, which the taskbar replaces: its key
  -- opens Start's All apps instead.
  hl.unbind("SUPER + ALT + SPACE")
  o.bind("SUPER + ALT + SPACE", "All apps", hl.dsp.event("windows-like-start-apps"))
end

-- ---------- Animations ----------

-- Snapped windows glide into their zone, as on Windows. Hyprland animates a
-- window's move and resize (windowsMove) itself, every frame at the monitor's
-- refresh rate; this makes that a short deceleration (220 ms, Windows'
-- "decelerate" curve) in place of Omarchy's longer ease. With
-- animations.enabled off, windows land at once. Omarchy's own switch
-- (animations off everywhere) turns this off too.
if active then
  if setting("animations.enabled", true) then
    hl.curve("windowsLikeDecelerate", { type = "bezier", points = { { 0.1, 0.9 }, { 0.2, 1 } } })
    hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.2, bezier = "windowsLikeDecelerate" })
  else
    hl.animation({ leaf = "windowsMove", enabled = false })
  end
end

-- The snap preview, layout picker and snap assist (WindowsLike.qml) fade
-- themselves; Hyprland's layer fade would run on top of that.
hl.layer_rule({ match = { namespace = "^windows-like$" }, no_anim = true, animation = "none" })

-- ---------- Tabs ----------

-- Tabs are Hyprland groups drawn by the plugin's own tab bar, so Hyprland's
-- group bar stays off. Windows only join a group when asked to (a new tab,
-- or a tab dropped on the tabs, which the plugin handles): not as they open,
-- and not when dropped on one by the title bar (Hyprland's drag_into_group
-- would merge a window carried over another into its tabs). A new tab goes
-- to the end, like on a Mac.
if active and setting("tabs.enabled", true) then
  hl.config({
    group = { auto_group = false, drag_into_group = 0, insert_after_current = false, groupbar = { enabled = false } },
  })
end

-- Positive ids enable the feature, negative ids disable it. The first
-- token is the fallback for ids with no exception.
local fallback = policy.startMode ~= "native" and policy.scope ~= "selected"
local exceptions = {}
local seen = {}
local function add_exception(id)
  if seen[id] then return end
  seen[id] = true
  local enabled = workspace_enabled(id)
  if enabled ~= fallback then
    table.insert(exceptions, enabled and id or -id)
  end
end
for _, id in ipairs(policy.selected or {}) do add_exception(id) end
for id in pairs(overrides) do add_exception(tonumber(id)) end
table.sort(exceptions)
local native_policy = (fallback and "all" or "none") .. " " .. table.concat(exceptions, " ")

-- Float new windows on enabled numbered workspaces without retiling any
-- existing windows or modifying Omarchy's saved workspace layouts.
if setting("general.floatingDefault", true) then
  local function float_range(first, last)
    if first <= last then
      hl.window_rule({ match = { workspace = string.format("r[%d-%d]", first, last) }, float = true })
    end
  end
  if fallback then
    local first = 1
    for index = #exceptions, 1, -1 do
      local id = -exceptions[index]
      float_range(first, id - 1)
      first = id + 1
    end
    float_range(first, 2147483647)
  else
    for _, id in ipairs(exceptions) do float_range(id, id) end
  end
end

-- The tabs follow the Omarchy theme. They sit in the title bar (in its
-- color, laid over its title), and the active tab takes the window's own
-- background so it reads as one with the content under it.
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
  local foreground = c.foreground or "f5f5f7"
  hl.config({
    plugin = {
      windows_like = {
        tab_height = 28,
        tab_font = "monospace",
        tab_font_size = 12,
        -- Omarchy's title bar buttons (−, □, ×): 20 px each, 8 px apart, 10 px in.
        tab_buttons_width = 94,
        ["col.titlebar"] = "rgb(" .. (titlebar or "2c2c2e") .. ")",
        ["col.bar"] = "rgb(" .. (titlebar or "2c2c2e") .. ")",
        ["col.active"] = rgb("background", "1c1c1e"),
        ["col.hover"] = "rgba(" .. foreground .. "14)",
        ["col.text"] = "rgb(" .. foreground .. ")",
        ["col.text_inactive"] = rgb("dark_foreground", "98989d"),
        ["col.separator"] = rgb("selection", "3a3a3c"),
        ["col.button_hover"] = "rgba(" .. foreground .. "26)",
        workspace_policy = native_policy,
        tabs = setting("tabs.enabled", true) and 1 or 0,
        terminal_names = setting("tabs.terminalNames", true) and 1 or 0,
        side_resize = setting("resizing.sides", true) and 1 or 0,
        joint_resize = setting("resizing.joint", true) and 1 or 0,
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

if setting("tabs.enabled", true) and setting("tabs.terminalShortcuts", true) then
  hl.bind("CTRL + T", tab("new"), { description = "New tab" })
  hl.bind("CTRL + W", tab("close"), { description = "Close tab" })
  for n = 1, 9 do
    hl.bind("CTRL + " .. n, tab("select", n), { description = n == 9 and "Last tab" or ("Tab " .. n) })
  end
  hl.bind("CTRL + TAB", tab("next"), { description = "Next tab" })
  hl.bind("CTRL + SHIFT + TAB", tab("prev"), { description = "Previous tab" })
  hl.bind("CTRL + SHIFT + bracketright", tab("next"), { description = "Next tab" })
  hl.bind("CTRL + SHIFT + bracketleft", tab("prev"), { description = "Previous tab" })
end
