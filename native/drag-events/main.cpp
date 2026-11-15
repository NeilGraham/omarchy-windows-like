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
  if (!*RESIZEONBORDER)
    return {};

  const auto w = Desktop::viewState()->hitTest().windowAt(
      pos, Desktop::View::ALLOW_FLOATING | Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
  if (!w || !validMapped(w) || !w->m_isFloating || (w->m_isX11 && w->isX11OverrideRedirect()) ||
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
  if (const auto name = cursorFor(hit.edge)) {
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
  });
}

} // namespace

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
  PHANDLE = handle;

  if (std::string{__hyprland_api_get_hash()} != std::string{__hyprland_api_get_client_hash()}) {
    HyprlandAPI::addNotification(PHANDLE, "[windows-like] drag events: built for a different Hyprland. Run: omarchy-windows-like setup",
                                 CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
    throw std::runtime_error("[windows-like] version mismatch");
  }

  static auto moveListener = Event::bus()->m_events.input.mouse.move.listen([](Vector2D pos, Event::SCallbackInfo &) {
    check(true);
    Tabs::onMouseMove(pos);
    updateCursorSoon();
  });
  static auto buttonListener = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo &) {
    onButton(e);
    checkSoon();
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
