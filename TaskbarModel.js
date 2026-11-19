// Taskbar and start menu logic, free of QML so tests can run it in node.
// claimingEntryId and the minimized-workspace convention follow Omarchy's
// dock (plugins/dock/DockModel.js, MIT).

var MINIMIZED_WORKSPACE = "special:minimized"

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

// The desktop entry a window's app id belongs to when the usual lookup can't
// tell: a terminal app started with --app-id=<id>, or Omarchy's
// org.omarchy.<command> TUIs.
function claimingEntryId(appId, entries) {
  var id = String(appId || "")
  if (!id)
    return ""
  var list = entries || []
  var flag = "--app-id=" + id
  for (var i = 0; i < list.length; i++) {
    var words = String(list[i].execString || "").split(/\s+/)
    if (words.indexOf(flag) >= 0)
      return list[i].id
  }
  if (id.indexOf("org.omarchy.") !== 0)
    return ""
  var command = id.slice("org.omarchy.".length)
  for (var j = 0; j < list.length; j++) {
    var program = String((list[j].command || [])[0] || "")
    if (list[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command)
      return list[j].id
  }
  return ""
}

// Which windows a taskbar on a monitor shows: those on the workspace that
// monitor shows, and minimized ones (they wait on the taskbar, as on Windows).
function visibleWindow(window, workspaceId) {
  return !!window && (window.minimized || window.workspaceId === workspaceId)
}

// Taskbar buttons: pinned apps first, in pin order, then other running apps
// in the order their first window appears. Windows of one app share a button.
//   pinned:  ["firefox.desktop", ...]  (desktop ids)
//   windows: [{ key, address, workspaceId, minimized, activated }]
function buildItems(pinned, windows, workspaceId) {
  var items = []
  var byKey = {}
  function itemFor(key, isPinned) {
    if (!byKey[key]) {
      byKey[key] = { key: key, pinned: isPinned, windows: [] }
      items.push(byKey[key])
    }
    return byKey[key]
  }
  for (var i = 0; i < (pinned || []).length; i++)
    if (pinned[i])
      itemFor(pinned[i], true)
  for (var j = 0; j < (windows || []).length; j++) {
    var w = windows[j]
    if (w && w.key && visibleWindow(w, workspaceId))
      itemFor(w.key, false).windows.push(w)
  }
  return items
}

// The buttons in the order they were dragged into this session (`order`,
// their keys). Pins keep their saved order among themselves: wherever the
// order has a pin, the next pin in saved order goes. A pin the order doesn't
// know yet goes after the last pin, a new running app at the end.
function arrange(items, order) {
  var list = (items || []).slice()
  if (!order || order.length === 0)
    return list
  var byKey = {}
  var pins = []
  for (var i = 0; i < list.length; i++) {
    byKey[list[i].key] = list[i]
    if (list[i].pinned)
      pins.push(list[i])
  }
  var out = []
  var placed = {}
  var nextPin = 0
  for (var j = 0; j < order.length; j++) {
    var item = byKey[order[j]]
    if (!item || placed[item.key])
      continue
    if (item.pinned)
      item = pins[nextPin++]
    placed[item.key] = true
    out.push(item)
  }
  var lastPin = -1
  for (var k = 0; k < out.length; k++)
    if (out[k].pinned)
      lastPin = k
  for (; nextPin < pins.length; nextPin++)
    out.splice(++lastPin, 0, pins[nextPin])
  for (var m = 0; m < list.length; m++)
    if (!list[m].pinned && !placed[list[m].key])
      out.push(list[m])
  return out
}

// `list` with the element at `from` moved to `to`.
function move(list, from, to) {
  var out = (list || []).slice()
  if (from < 0 || from >= out.length)
    return out
  var moved = out.splice(from, 1)[0]
  out.splice(Math.max(0, Math.min(to, out.length)), 0, moved)
  return out
}

// Where a dragged button lands: past every other button whose middle its
// middle has passed. centers are the buttons' middles where they stand.
function dropIndex(centers, from, center) {
  var to = 0
  for (var i = 0; i < (centers || []).length; i++)
    if (i !== from && centers[i] < center)
      to++
  return to
}

// How far the button at `index` steps aside while the one at `from` is held
// over `to`: by the dragged button's room (its width and the spacing).
function shiftFor(index, from, to, room) {
  if (from < 0 || index === from)
    return 0
  if (from < to && index > from && index <= to)
    return -room
  if (to < from && index >= to && index < from)
    return room
  return 0
}

// The saved pins with the ones in `keys` put in the order they have there;
// pins not shown (an app no longer installed) keep their places.
function reorderPinned(saved, keys) {
  var list = (saved || []).slice()
  var isPin = {}
  for (var i = 0; i < list.length; i++)
    isPin[list[i]] = true
  var shown = (keys || []).filter(function(k) {
    return isPin[k]
  })
  var isShown = {}
  for (var j = 0; j < shown.length; j++)
    isShown[shown[j]] = true
  var next = 0
  for (var k = 0; k < list.length; k++)
    if (isShown[list[k]])
      list[k] = shown[next++]
  return list
}

// How many buttons fit in `room`, with `spacing` between them. When not all
// do, as many as fit beside an overflow button `moreWidth` wide, as on
// Windows 11.
function fitCount(widths, spacing, room, moreWidth) {
  var n = (widths || []).length
  var total = 0
  for (var i = 0; i < n; i++)
    total += widths[i] + (i > 0 ? spacing : 0)
  if (!(room < total))
    return n
  var used = moreWidth
  var count = 0
  while (count < n && used + spacing + widths[count] <= room) {
    used += spacing + widths[count]
    count++
  }
  return count
}

// What clicking a button does, like Windows:
//   no window            -> launch the app
//   its window is active -> minimize it (one window), or go to the next one
//   otherwise            -> bring forward the best window: one on this
//                           workspace, else a minimized one
// Returns { action: "launch" | "focus" | "minimize", index }.
function clickAction(item, workspaceId) {
  var list = (item && item.windows) || []
  if (list.length === 0)
    return { action: "launch", index: -1 }
  var active = -1
  for (var i = 0; i < list.length; i++)
    if (list[i].activated && !list[i].minimized)
      active = i
  if (active >= 0)
    return list.length === 1 ? { action: "minimize", index: active } : { action: "focus", index: (active + 1) % list.length }
  var best = 0
  for (var j = 0; j < list.length; j++) {
    if (!list[j].minimized && list[j].workspaceId === workspaceId) {
      best = j
      break
    }
    if (list[j].minimized && list[best].minimized === false && list[best].workspaceId !== workspaceId)
      best = j
  }
  return { action: "focus", index: best }
}

// Indicator under a button: "none", "running" (short line) or "active"
// (long accent line), as on Windows 11.
function indicator(item) {
  var list = (item && item.windows) || []
  for (var i = 0; i < list.length; i++)
    if (list[i].activated && !list[i].minimized)
      return "active"
  return list.length > 0 ? "running" : "none"
}

// Most recent first, no repeats, at most `max`.
function pushRecent(list, id, max) {
  var out = [String(id)]
  for (var i = 0; i < (list || []).length && out.length < (max || 12); i++)
    if (list[i] !== id)
      out.push(list[i])
  return out
}

// "1700000000.12 firefox.desktop" lines (newest first, from find -printf)
// into desktop ids, keeping only ids the start menu knows, at most `max`.
function recentlyInstalled(lines, knownIds, max) {
  var known = {}
  for (var i = 0; i < (knownIds || []).length; i++)
    known[knownIds[i]] = true
  var out = []
  var seen = {}
  var rows = String(lines || "").split("\n")
  for (var j = 0; j < rows.length && out.length < (max || 6); j++) {
    var m = rows[j].match(/^\s*[\d.]+\s+(\S+\.desktop)\s*$/)
    if (!m)
      continue
    var id = m[1].replace(/\.desktop$/, "")
    if ((known[id] || known[m[1]]) && !seen[id]) {
      seen[id] = true
      out.push(known[id] ? id : m[1])
    }
  }
  return out
}

// Start's Recommended: recently installed and recently used apps, taking
// turns so both kinds show, without repeats and without apps pinned to Start
// (the next ones move up instead). idOf(id) gives the id of the entry an id
// names, or "" to leave it out (gone, or hidden from menus).
// Returns [{ id, why: "installed" | "used" }], at most `max`.
function recommendations(installed, recent, pinned, idOf, max) {
  var skip = {}
  for (var i = 0; i < (pinned || []).length; i++) {
    var p = idOf(pinned[i])
    if (p)
      skip[p] = true
  }
  var out = []
  var n = installed || []
  var r = recent || []
  function add(id, why) {
    var entryId = idOf(id)
    if (entryId && !skip[entryId] && out.length < (max || 8)) {
      skip[entryId] = true
      out.push({ id: entryId, why: why })
    }
  }
  for (var j = 0; j < Math.max(n.length, r.length); j++) {
    if (j < n.length)
      add(n[j], "installed")
    if (j < r.length)
      add(r[j], "used")
  }
  return out
}

// The letter an app is filed under in "All apps": A-Z, or "#" for the rest.
function letterFor(name) {
  var c = String(name || "").trim().charAt(0).toUpperCase()
  return c >= "A" && c <= "Z" ? c : "#"
}

// Apps sorted by name, with a { header: "A" } row before each new letter.
function withLetterHeaders(apps, nameOf) {
  var sorted = (apps || []).slice().sort(function(a, b) {
    return String(nameOf(a)).localeCompare(String(nameOf(b)), undefined, { sensitivity: "base" })
  })
  var out = []
  var last = null
  for (var i = 0; i < sorted.length; i++) {
    var letter = letterFor(nameOf(sorted[i]))
    if (letter !== last) {
      out.push({ header: letter })
      last = letter
    }
    out.push({ app: sorted[i] })
  }
  return out
}

if (typeof module !== "undefined")
  module.exports = {
    isMinimizedWorkspace: isMinimizedWorkspace,
    claimingEntryId: claimingEntryId,
    visibleWindow: visibleWindow,
    buildItems: buildItems,
    arrange: arrange,
    move: move,
    dropIndex: dropIndex,
    shiftFor: shiftFor,
    reorderPinned: reorderPinned,
    fitCount: fitCount,
    clickAction: clickAction,
    indicator: indicator,
    pushRecent: pushRecent,
    recentlyInstalled: recentlyInstalled,
    recommendations: recommendations,
    letterFor: letterFor,
    withLetterHeaders: withLetterHeaders
  }
