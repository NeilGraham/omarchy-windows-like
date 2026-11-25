// windows-like drag events: a tiny Hyprland plugin that tells the shell when a
// window drag starts, moves, and ends.
//
// Hyprland has no IPC or Lua event for interactive moves and resizes, and the
// title bars Omarchy draws on floating workspaces swallow the mouse button, so
// no keybind sees a title-bar drag either. Every way of dragging a window
// (title bar, Super + drag, border resize) goes through the layout's drag
// controller, though, so this watches that controller and reports what it sees
// as Hyprland "custom" IPC events, which the shell plugin listens for:
//
//   windows-like:start|<move|resize>|0x<address>|<cursor x>|<cursor y>|<x>|<y>|<w>|<h>
//   windows-like:move|<same fields>      (at most ~60 per second while dragging)
//   windows-like:end|<same fields>       (the last known position)
//
// Coordinates are global logical pixels.
//
// It also makes border resizing of floating windows behave like Windows:
//
//   - Hyprland always resizes from the corner nearest the click, so dragging
//     a side changes the height too. Right after a border press starts a
//     resize, this restarts it on just that side (or corner), which Hyprland
//     supports but only offers to client-side resizes.
//   - Hyprland measures its border from the window's content, which puts the
//     band above Omarchy's title bar outside it: no resize cursor shows there,
//     though the title bar plugin does start a (corner) resize from it. The
//     cursor and the side are worked out here from the whole window, title
//     bar included.
//
// Neither cancels any input: presses still go where they went before, only
// the side being resized and the cursor shape change.

#define WLR_USE_UNSTABLE

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>

#include <linux/input-event-codes.h>

#include "tabs.hpp"

#include <chrono>
#include <format>

inline HANDLE PHANDLE = nullptr;

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }

namespace {

struct SDragState {
  bool active = false;
  eMouseBindMode mode = MBIND_INVALID;
  PHLWINDOWREF window;
  std::string lastFields;
  std::chrono::steady_clock::time_point lastMove;
};

SDragState g_state;
bool g_checkQueued = false;

std::string fields(eMouseBindMode mode, PHLWINDOW window) {
  const auto cursor = g_pInputManager->getMouseCoordsInternal();
  // The same geometry `hyprctl clients` reports as "at" and "size".
  CBox box;
  if (window)
    box = CBox{window->positionAnimation()->goal(), window->sizeAnimation()->goal()};
  return std::format("{}|0x{:x}|{}|{}|{}|{}|{}|{}", mode == MBIND_MOVE ? "move" : "resize", reinterpret_cast<uintptr_t>(window.get()),
                     static_cast<int>(cursor.x), static_cast<int>(cursor.y), static_cast<int>(box.x), static_cast<int>(box.y),
                     static_cast<int>(box.w), static_cast<int>(box.h));
}

void post(const std::string &kind, const std::string &data) {
  if (g_pEventManager)
    g_pEventManager->postEvent(SHyprIPCEvent{"custom", "windows-like:" + kind + "|" + data});
}

void check(bool fromMotion) {
  if (!g_layoutManager)
    return;

  const auto &controller = g_layoutManager->dragController();
  const auto mode = controller ? controller->mode() : MBIND_INVALID;
  const auto target = controller ? controller->target() : nullptr;
  const auto window = target ? target->window() : nullptr;
  const bool dragging = mode != MBIND_INVALID && window;

  if (dragging && (!g_state.active || g_state.window.lock() != window)) {
    if (g_state.active)
      post("end", g_state.lastFields);
    g_state.active = true;
    g_state.mode = mode;
    g_state.window = window;
    g_state.lastFields = fields(mode, window);
    g_state.lastMove = std::chrono::steady_clock::now();
    post("start", g_state.lastFields);
    return;
  }

  if (!dragging && g_state.active) {
    g_state.active = false;
    if (const auto last = g_state.window.lock())
      g_state.lastFields = fields(g_state.mode, last);
    post("end", g_state.lastFields);
    g_state.window.reset();
    return;
  }

  if (dragging && fromMotion) {
    g_state.lastFields = fields(mode, window);
    const auto now = std::chrono::steady_clock::now();
    if (now - g_state.lastMove >= std::chrono::milliseconds(16)) {
      g_state.lastMove = now;
      post("move", g_state.lastFields);
    }
  }
}

// Title bars end their drag from their own button listener, which may run
// after this one, so a release is checked once the event has been handled.
void checkSoon() {
  if (g_checkQueued || !g_pEventLoopManager)
    return;
  g_checkQueued = true;
  g_pEventLoopManager->doLater([] {
    g_checkQueued = false;
    check(false);
  });
}

// ---------- Edge resizing ----------

struct SEdgeHit {
  PHLWINDOW window;
  uint8_t edge = Layout::CORNER_NONE;
};

int g_buttonsHeld = 0;
bool g_cursorSet = false;
SEdgeHit g_pressHit;
bool g_cursorQueued = false;

// The window as drawn: its content plus decorations that take input (the
// title bar), without the border.
CBox outerBox(PHLWINDOW w) {
  CBox box = w->getWindowMainSurfaceBox();
  for (auto const &deco : w->m_windowDecorations) {
    if (!(deco->getDecorationFlags() & DECORATION_ALLOWS_MOUSE_INPUT))
      continue;
    const auto db = g_pDecorationPositioner->getWindowDecorationBox(deco.get());
    if (db.w <= 0 || db.h <= 0)
      continue;
    const double x1 = std::min(box.x, db.x), y1 = std::min(box.y, db.y);
    const double x2 = std::max(box.x + box.w, db.x + db.w), y2 = std::max(box.y + box.h, db.y + db.h);
    box = CBox{x1, y1, x2 - x1, y2 - y1};
  }
  return box;
}

// Which side or corner of a floating window's border is under pos, if any.
SEdgeHit edgeAt(const Vector2D &pos) {
  static auto RESIZEONBORDER = CConfigValue<Config::INTEGER>("general:resize_on_border");
  static auto EXTENDGRAB = CConfigValue<Config::INTEGER>("general:extend_border_grab_area");
  if (!*RESIZEONBORDER || !sideResizeEnabled())
    return {};

  const auto w = Desktop::viewState()->hitTest().windowAt(
      pos, Desktop::View::ALLOW_FLOATING | Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
  if (!windowsLikeEnabled(w) || !validMapped(w) || !w->m_isFloating || (w->m_isX11 && w->isX11OverrideRedirect()) ||
      Fullscreen::controller()->isFullscreen(w) || w->hasPopupAt(pos))
    return {};

  const CBox box = outerBox(w);
  const double grab = w->getRealBorderSize() + *EXTENDGRAB;
  const CBox grabBox{box.x - grab, box.y - grab, box.w + 2 * grab, box.h + 2 * grab};
  if (!grabBox.containsPoint(pos) || box.containsPoint(pos))
    return {};

  // How far along a side from a corner still grabs the corner.
  const double corner = w->rounding() + w->getRealBorderSize() + 14;
  uint8_t edge = Layout::CORNER_NONE;
  if (pos.y < box.y + corner)
    edge |= Layout::CORNER_TOP;
  else if (pos.y > box.y + box.h - corner)
    edge |= Layout::CORNER_BOTTOM;
  if (pos.x < box.x + corner)
    edge |= Layout::CORNER_LEFT;
  else if (pos.x > box.x + box.w - corner)
    edge |= Layout::CORNER_RIGHT;
  return {w, edge};
}

// ---------- Resizing windows together ----------
//
// Windows standing side by side along a shared line (snapped halves, three
// columns, quarters) resize together: dragging the line between them moves
// that edge of every window on it. With four quarters, the vertical middle
// line takes all four; the horizontal line between the two on the left takes
// just those two. The window grabbed is resized by Hyprland as usual; the
// others follow it after every move.

struct SJointMember {
  PHLWINDOWREF window;
  CBox start; // its box on screen (content) when the drag began
  bool before; // left of (or above) the line
};

// A window as it is on screen. Its layout box can be smaller: an app with a
// minimum size (Firefox) stays wider than a box it was squeezed into.
CBox realBox(PHLWINDOW w) { return CBox{w->positionAnimation()->goal(), w->sizeAnimation()->goal()}; }

// The narrowest (or shortest) a window may become: its app's minimum, and
// never under 100px.
double minExtent(PHLWINDOW w, bool vertical) {
  constexpr double MIN = 100;
  const auto m = w->minSize();
  return std::max(MIN, m ? (vertical ? m->x : m->y) : 0.0);
}

struct SJoint {
  bool active = false;
  PHLWINDOWREF primary;
  bool vertical = true; // a vertical line: the windows' widths change
  bool primaryBefore = true;
  CBox primaryStart;
  std::vector<SJointMember> others;
};
SJoint g_joint;
bool g_jointQueued = false;

bool sameSpace(PHLWINDOW w, PHLWINDOW ref) {
  return w && w != ref && validMapped(w) && !w->isHidden() && w->m_isFloating && w->m_workspace == ref->m_workspace &&
         !Fullscreen::controller()->isFullscreen(w);
}

// The other windows on the line along `edge` (a single side) of w: those
// facing it across the gap, and those on its side lined up with it.
std::optional<SJoint> jointAt(PHLWINDOW w, uint8_t edge) {
  using namespace Layout;
  if (!windowsLikeEnabled(w) || !jointResizeEnabled() || !(edge == CORNER_LEFT || edge == CORNER_RIGHT || edge == CORNER_TOP || edge == CORNER_BOTTOM))
    return std::nullopt;
  const bool vertical = edge == CORNER_LEFT || edge == CORNER_RIGHT;
  const bool wBefore = edge == CORNER_RIGHT || edge == CORNER_BOTTOM;
  // How far apart facing edges may be (gaps, borders, a title bar), how
  // closely edges on one side must line up, and how much windows must
  // overlap along the line to share it.
  constexpr double GAP = 48, ALIGN = 4, OVERLAP = 24;

  struct SEntry {
    PHLWINDOW w;
    CBox box;
  };
  auto endOf = [&](const CBox &b) { return vertical ? b.x + b.w : b.y + b.h; }; // right or bottom
  auto startOf = [&](const CBox &b) { return vertical ? b.x : b.y; };           // left or top
  auto overlaps = [&](const CBox &a, const CBox &b) {
    return vertical ? std::min(a.y + a.h, b.y + b.h) - std::max(a.y, b.y) > OVERLAP
                    : std::min(a.x + a.w, b.x + b.w) - std::max(a.x, b.x) > OVERLAP;
  };

  std::vector<SEntry> before, after, pool;
  const SEntry self{w, outerBox(w)};
  (wBefore ? before : after).push_back(self);
  std::vector<const void *> targets{w->layoutTarget().get()};
  for (const auto &other : Desktop::windowState()->windows()) {
    if (!sameSpace(other, w))
      continue;
    // A tab group is one target: count it once.
    const void *t = other->layoutTarget().get();
    if (std::ranges::find(targets, t) != targets.end())
      continue;
    targets.push_back(t);
    pool.push_back({other, outerBox(other)});
  }

  // The line has two sides: the grabbed window's edge, and the nearest edge
  // facing it across the gap. A window further off (one standing behind the
  // neighbour, say) never decides where the far side is.
  const double beforeLine = wBefore ? endOf(self.box) : 0, afterLine0 = wBefore ? 0 : startOf(self.box);
  std::optional<double> facing;
  for (const auto &e : pool) {
    if (!overlaps(e.box, self.box))
      continue;
    const double gap = wBefore ? startOf(e.box) - beforeLine : afterLine0 - endOf(e.box);
    if (gap >= -ALIGN && gap <= GAP && (!facing || gap < *facing))
      facing = gap;
  }
  if (!facing)
    return std::nullopt;
  const double lineBefore = wBefore ? beforeLine : afterLine0 - *facing;
  const double lineAfter = wBefore ? beforeLine + *facing : afterLine0;
  auto onBefore = [&](const CBox &b) { return std::abs(endOf(b) - lineBefore) <= ALIGN; };
  auto onAfter = [&](const CBox &b) { return std::abs(startOf(b) - lineAfter) <= ALIGN; };
  auto stackedWith = [&](const CBox &a, const CBox &b) {
    const double apart = std::max(a.y - (b.y + b.h), b.y - (a.y + a.h));
    return apart >= -ALIGN && apart <= GAP;
  };

  // Windows join a side when their edge is on that side's line and they touch
  // the group: across the line from a window on the other side, or (for a
  // vertical line, which runs on through columns) stacked above or below one
  // on their own side. A horizontal line stays inside its column.
  for (bool grew = true; grew;) {
    grew = false;
    for (auto it = pool.begin(); it != pool.end();) {
      int side = 0; // 1 before, 2 after
      if (onAfter(it->box)) {
        for (const auto &b : before)
          if (overlaps(it->box, b.box))
            side = 2;
        if (vertical)
          for (const auto &a : after)
            if (stackedWith(it->box, a.box))
              side = 2;
      }
      if (!side && onBefore(it->box)) {
        for (const auto &a : after)
          if (overlaps(it->box, a.box))
            side = 1;
        if (vertical)
          for (const auto &b : before)
            if (stackedWith(it->box, b.box))
              side = 1;
      }
      if (side) {
        (side == 1 ? before : after).push_back(*it);
        it = pool.erase(it);
        grew = true;
      } else
        ++it;
    }
  }
  if (before.empty() || after.empty())
    return std::nullopt;

  SJoint joint;
  joint.primary = w;
  joint.vertical = vertical;
  joint.primaryBefore = wBefore;
  joint.primaryStart = realBox(w);
  for (const auto &list : {&before, &after})
    for (const auto &e : *list)
      if (e.w != w)
        joint.others.push_back({e.w, realBox(e.w), list == &before});
  return joint;
}

// Moves every window's edge on the line as far as the grabbed one's has
// moved, but only as far as every window there can go: none gets narrower
// (or shorter) than its minimum. When another window stops the line, the
// grabbed one is held there too, so the windows never overlap.
void applyJoint() {
  const auto primary = g_joint.primary.lock();
  if (!g_joint.active || !validMapped(primary))
    return;
  const bool V = g_joint.vertical;
  auto lo = [&](const CBox &b) { return V ? b.x : b.y; };
  auto len = [&](const CBox &b) { return V ? b.w : b.h; };

  // How far the grabbed window's edge has moved, on screen: Hyprland holds it
  // at the app's minimum size, so this already stops there.
  const CBox now = realBox(primary);
  const CBox &s = g_joint.primaryStart;
  double delta = g_joint.primaryBefore ? (lo(now) + len(now)) - (lo(s) + len(s)) : lo(now) - lo(s);

  // A window left of (or above) the line shrinks as the line moves back; one
  // after it shrinks as the line moves on.
  double low = -1e9, high = 1e9;
  auto limit = [&](PHLWINDOW w, const CBox &start, bool before) {
    const double room = len(start) - minExtent(w, V);
    if (before)
      low = std::max(low, -room);
    else
      high = std::min(high, room);
  };
  limit(primary, s, g_joint.primaryBefore);
  for (const auto &m : g_joint.others)
    if (const auto w = m.window.lock(); validMapped(w))
      limit(w, m.start, m.before);
  const double clamped = std::clamp(delta, std::min(low, 0.0), std::max(high, 0.0));

  auto place = [&](PHLWINDOW w, CBox box, bool before, double d) {
    if (!validMapped(w) || !w->layoutTarget() || !w->layoutTarget()->floating() || !w->layoutTarget()->space())
      return;
    if (V) {
      if (before)
        box.w += d;
      else {
        box.x += d;
        box.w -= d;
      }
    } else {
      if (before)
        box.h += d;
      else {
        box.y += d;
        box.h -= d;
      }
    }
    g_layoutManager->setTargetGeom(box, w->layoutTarget());
    w->layoutTarget()->warpPositionSize();
  };
  for (const auto &m : g_joint.others)
    place(m.window.lock(), m.start, m.before, clamped);
  // Another window can't go further: hold the grabbed one there as well.
  if (std::abs(clamped - delta) > 0.5)
    place(primary, s, g_joint.primaryBefore, clamped);
}

void applyJointSoon() {
  if (g_jointQueued || !g_pEventLoopManager)
    return;
  g_jointQueued = true;
  g_pEventLoopManager->doLater([] {
    g_jointQueued = false;
    applyJoint();
  });
}

void endJoint() {
  if (!g_joint.active)
    return;
  applyJoint();
  g_joint = {};
}

// After each move or release: follow the grabbed window, or finish once the
// drag is over.
void jointTick() {
  if (!g_joint.active)
    return;
  const auto *controller = g_layoutManager ? g_layoutManager->dragController().get() : nullptr;
  const auto target = controller ? controller->target() : nullptr;
  const auto primary = g_joint.primary.lock();
  if (!controller || controller->mode() == MBIND_INVALID || controller->mode() == MBIND_MOVE || !target || !primary ||
      target->window() != primary)
    endJoint();
  else
    applyJointSoon();
}

const char *jointCursor(bool vertical) { return vertical ? "col-resize" : "row-resize"; }

const char *cursorFor(uint8_t edge) {
  using namespace Layout;
  switch (edge) {
  case CORNER_TOPLEFT: return "top_left_corner";
  case CORNER_TOPRIGHT: return "top_right_corner";
  case CORNER_BOTTOMLEFT: return "bottom_left_corner";
  case CORNER_BOTTOMRIGHT: return "bottom_right_corner";
  case CORNER_TOP: return "top_side";
  case CORNER_BOTTOM: return "bottom_side";
  case CORNER_LEFT: return "left_side";
  case CORNER_RIGHT: return "right_side";
  default: return nullptr;
  }
}

// Runs after Hyprland has handled the motion, so this cursor wins over the
// one Hyprland just picked from the content box.
void updateCursor() {
  using namespace Pointer::Cursor;
  const bool dragging = g_layoutManager && g_layoutManager->dragController() &&
                        g_layoutManager->dragController()->mode() != MBIND_INVALID;
  const auto hit = (dragging || g_buttonsHeld > 0) ? SEdgeHit{} : edgeAt(g_pInputManager->getMouseCoordsInternal());
  // A side shared with other windows shows that they resize together.
  const auto joint = hit.edge ? jointAt(hit.window, hit.edge) : std::nullopt;
  if (const auto name = joint ? jointCursor(joint->vertical) : cursorFor(hit.edge)) {
    overrideController->setOverride(name, CURSOR_OVERRIDE_WINDOW_EDGE);
    g_cursorSet = true;
  } else if (g_cursorSet) {
    overrideController->unsetOverride(CURSOR_OVERRIDE_WINDOW_EDGE);
    g_cursorSet = false;
  }
}

void updateCursorSoon() {
  if (g_cursorQueued || !g_pEventLoopManager)
    return;
  g_cursorQueued = true;
  g_pEventLoopManager->doLater([] {
    g_cursorQueued = false;
    updateCursor();
  });
}

void onButton(const IPointer::SButtonEvent &e) {
  if (e.state == WL_POINTER_BUTTON_STATE_PRESSED)
    g_buttonsHeld++;
  else
    g_buttonsHeld = std::max(0, g_buttonsHeld - 1);

  if (e.button != BTN_LEFT || e.state != WL_POINTER_BUTTON_STATE_PRESSED)
    return;

  // Super + drag and other modified clicks are keybinds; leave them be.
  g_pressHit = g_pInputManager->getModsFromAllKBs() == 0 ? edgeAt(g_pInputManager->getMouseCoordsInternal()) : SEdgeHit{};
  if (!g_pressHit.edge || !g_pEventLoopManager)
    return;

  // Whoever handles the press (Hyprland's border, or the title bar's band
  // above itself) starts a corner resize; restart it on the side pressed.
  g_pEventLoopManager->doLater([] {
    const auto hit = g_pressHit;
    g_pressHit = {};
    if (!g_layoutManager || !hit.window)
      return;
    const auto &controller = g_layoutManager->dragController();
    const auto mode = controller ? controller->mode() : MBIND_INVALID;
    const auto target = controller ? controller->target() : nullptr;
    if (mode == MBIND_INVALID || mode == MBIND_MOVE || !target || target->window() != hit.window)
      return;
    g_layoutManager->beginDragTarget(target, mode, static_cast<Layout::eRectCorner>(hit.edge));
    if (auto joint = jointAt(hit.window, hit.edge)) {
      g_joint = *joint;
      g_joint.active = true;
      Pointer::Cursor::overrideController->setOverride(jointCursor(g_joint.vertical), Pointer::Cursor::CURSOR_OVERRIDE_SPECIAL_ACTION);
    }
  });
}

} // namespace

void reportDragSoon() { checkSoon(); }

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
  PHANDLE = handle;

  if (std::string{__hyprland_api_get_hash()} != std::string{__hyprland_api_get_client_hash()}) {
    HyprlandAPI::addNotification(PHANDLE, "[windows-like] drag events: built for a different Hyprland. Run: omarchy-windows-like setup",
                                 CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
    throw std::runtime_error("[windows-like] version mismatch");
  }

  static auto moveListener = Event::bus()->m_events.input.mouse.move.listen([](Vector2D pos, Event::SCallbackInfo &) {
    check(true);
    jointTick();
    Tabs::onMouseMove(pos);
    updateCursorSoon();
  });
  static auto buttonListener = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo &) {
    onButton(e);
    checkSoon();
    if (e.state != WL_POINTER_BUTTON_STATE_PRESSED && g_pEventLoopManager)
      g_pEventLoopManager->doLater([] { jointTick(); });
  });

  Tabs::init(handle);
  // The Lua side styles the tab bar through plugin:windows_like:*, which only
  // exist from here on: read the config again so it finds them.
  HyprlandAPI::reloadConfig();

  return {"windows-like-drag-events", "omarchy-windows-like: drag events, side resizing and window tabs", "omarchy-windows-like", "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
  Tabs::exit();
  if (g_cursorSet)
    Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_WINDOW_EDGE);
  if (g_state.active)
    post("end", g_state.lastFields);
  g_state = {};
}
