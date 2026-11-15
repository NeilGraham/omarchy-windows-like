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
// Coordinates are global logical pixels. The plugin never cancels or changes
// any input, so with nothing listening it does nothing at all.

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

} // namespace

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
  PHANDLE = handle;

  if (std::string{__hyprland_api_get_hash()} != std::string{__hyprland_api_get_client_hash()}) {
    HyprlandAPI::addNotification(PHANDLE, "[windows-like] drag events: built for a different Hyprland. Run: omarchy-windows-like setup",
                                 CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
    throw std::runtime_error("[windows-like] version mismatch");
  }

  static auto onMove = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo &) { check(true); });
  static auto onButton = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent, Event::SCallbackInfo &) { checkSoon(); });

  return {"windows-like-drag-events", "Reports window drags to the omarchy-windows-like shell plugin", "omarchy-windows-like", "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
  if (g_state.active)
    post("end", g_state.lastFields);
  g_state = {};
}
