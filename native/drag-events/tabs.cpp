// Tabs for any window, built on Hyprland groups.
//
// A window looks as it always has until it gets a second tab: then a tab bar
// appears under its title bar (inside the border), one tab per window in the
// group. Each tab has a close button (on the active tab, and on any tab under
// the pointer), there is a "+" at the right that opens another window of the
// same app as a new tab, and when the tabs no longer fit they keep a minimum
// width and the bar scrolls sideways (wheel or touchpad).
//
// Hyprland's own group bar is switched off by the Lua side
// (group.groupbar.enabled = false); this draws instead.
//
// Tabs of terminals get names from what runs in them, read from /proc: the
// current folder while the shell waits for input, the program (and its first
// argument) while one runs, or the program's own title when it sets one.
//
// Lua: hl.plugin.windows_like.tab(action[, n]) -> handled
//   action: "new" | "close" | "select" (n = 1..9, 9 = last) | "next" | "prev"
//   Acts on the focused window if its class matches plugin:windows_like:tab_apps
//   and returns false otherwise, so a keybind can pass the key on to the app.
// hyprctl windowslike-tabs: the visible tab bars as JSON (for tests).

#define WLR_USE_UNSTABLE

#include "tabs.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/config/supplementary/executor/Executor.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/desktop/state/FadingOutState.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Group.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/XWaylandManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>

extern "C" {
#include <lua.h>
}

#include <algorithm>
#include <chrono>
#include <cmath>
#include <format>
#include <fstream>
#include <regex>
#include <sstream>
#include <unistd.h>
#include <unordered_map>

using namespace Render;

namespace {

HANDLE g_handle = nullptr;

// ---------- Config ----------

struct {
  SP<Config::Values::CIntValue> height, minWidth, fontSize;
  SP<Config::Values::CStringValue> font, tabApps, terminals;
  SP<Config::Values::CColorValue> bar, active, hover, text, textInactive, separator, button;
} cfg;

void registerConfig() {
  using namespace Config::Values;
  cfg.height = makeShared<CIntValue>("plugin:windows_like:tab_height", "Height of the tab bar", 28);
  cfg.minWidth = makeShared<CIntValue>("plugin:windows_like:tab_min_width", "Narrowest a tab gets before the bar scrolls", 140);
  cfg.fontSize = makeShared<CIntValue>("plugin:windows_like:tab_font_size", "Tab title size", 11);
  cfg.font = makeShared<CStringValue>("plugin:windows_like:tab_font", "Tab title font", "sans-serif");
  cfg.tabApps = makeShared<CStringValue>("plugin:windows_like:tab_apps", "Classes (regex) whose tab shortcuts act on tabs",
                                         "^(foot|footclient)$");
  cfg.terminals = makeShared<CStringValue>("plugin:windows_like:terminals", "Classes (regex) of terminals, named after what runs in them",
                                           "^(foot|footclient|kitty|Alacritty|com\\.mitchellh\\.ghostty)$");
  cfg.bar = makeShared<CColorValue>("plugin:windows_like:col.bar", "Tab bar and inactive tab color", 0xff161618);
  cfg.active = makeShared<CColorValue>("plugin:windows_like:col.active", "Active tab color", 0xff2c2c2e);
  cfg.hover = makeShared<CColorValue>("plugin:windows_like:col.hover", "Inactive tab under the pointer", 0xff222224);
  cfg.text = makeShared<CColorValue>("plugin:windows_like:col.text", "Active tab title", 0xfff5f5f7);
  cfg.textInactive = makeShared<CColorValue>("plugin:windows_like:col.text_inactive", "Inactive tab title", 0xff98989d);
  cfg.separator = makeShared<CColorValue>("plugin:windows_like:col.separator", "Line between inactive tabs", 0xff3a3a3c);
  cfg.button = makeShared<CColorValue>("plugin:windows_like:col.button_hover", "Close and + buttons under the pointer", 0xff48484a);
  for (const SP<Config::Values::IValue> v : std::initializer_list<SP<Config::Values::IValue>>{
           cfg.height, cfg.minWidth, cfg.fontSize, cfg.font, cfg.tabApps, cfg.terminals, cfg.bar, cfg.active, cfg.hover, cfg.text,
           cfg.textInactive, cfg.separator, cfg.button})
    HyprlandAPI::addConfigValueV2(g_handle, v);
}

bool classMatches(const SP<Config::Values::CStringValue> &pattern, const std::string &cls) {
  static std::unordered_map<std::string, std::regex> cache;
  const auto p = pattern->value();
  auto it = cache.find(p);
  if (it == cache.end()) {
    try {
      it = cache.emplace(p, std::regex(p)).first;
    } catch (const std::regex_error &) {
      it = cache.emplace(p, std::regex("$^")).first;
    }
  }
  return std::regex_search(cls, it->second);
}

// ---------- Names from /proc ----------

std::string readFile(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

std::string readLink(const std::string &path) {
  char buf[4096];
  const auto n = readlink(path.c_str(), buf, sizeof(buf) - 1);
  return n > 0 ? std::string(buf, n) : "";
}

std::string baseName(const std::string &p) {
  const auto s = p.find_last_of('/');
  return s == std::string::npos ? p : p.substr(s + 1);
}

struct SStat {
  pid_t pgrp = 0, tpgid = 0;
};

std::optional<SStat> procStat(pid_t pid) {
  const auto s = readFile(std::format("/proc/{}/stat", pid));
  const auto close = s.rfind(')');
  if (close == std::string::npos)
    return std::nullopt;
  std::istringstream in(s.substr(close + 2));
  std::string state;
  long ppid, pgrp, session, tty, tpgid;
  if (!(in >> state >> ppid >> pgrp >> session >> tty >> tpgid))
    return std::nullopt;
  return SStat{static_cast<pid_t>(pgrp), static_cast<pid_t>(tpgid)};
}

std::vector<pid_t> children(pid_t pid) {
  std::vector<pid_t> out;
  std::istringstream in(readFile(std::format("/proc/{}/task/{}/children", pid, pid)));
  pid_t c;
  while (in >> c)
    out.push_back(c);
  return out;
}

std::vector<std::string> cmdline(pid_t pid) {
  const auto raw = readFile(std::format("/proc/{}/cmdline", pid));
  std::vector<std::string> args;
  std::string cur;
  for (char c : raw) {
    if (c == '\0') {
      args.push_back(cur);
      cur.clear();
    } else
      cur += c;
  }
  if (!cur.empty())
    args.push_back(cur);
  return args;
}

std::string prettyDir(const std::string &dir) {
  const char *home = getenv("HOME");
  if (dir.empty())
    return "";
  if (home && dir == home)
    return "~";
  if (dir == "/")
    return "/";
  return baseName(dir);
}

// "nvim README.md", "ssh server", "claude" (not "node /usr/bin/claude").
std::string prettyCommand(std::vector<std::string> args) {
  static const std::vector<std::string> interpreters = {"node", "python", "python3", "bun", "deno", "ruby", "perl", "sh", "bash", "zsh", "fish"};
  if (args.empty())
    return "";
  std::string prefix;
  if (baseName(args[0]) == "sudo" && args.size() > 1) {
    prefix = "sudo ";
    args.erase(args.begin());
  }
  size_t i = 0;
  if (std::ranges::find(interpreters, baseName(args[0])) != interpreters.end()) {
    for (size_t j = 1; j < args.size(); ++j)
      if (!args[j].starts_with("-")) {
        i = j;
        break;
      }
  }
  std::string out = prefix + baseName(args[i]);
  for (size_t j = i + 1; j < args.size(); ++j) {
    if (args[j].starts_with("-") || args[j].empty())
      continue;
    out += " " + baseName(args[j]);
    break;
  }
  return out;
}

// The shell a terminal window runs: its only child. A terminal that serves
// several windows from one process (foot --server) can't be told apart.
pid_t shellOf(PHLWINDOW w) {
  const auto pid = w->getPID();
  if (pid <= 0)
    return -1;
  const auto kids = children(pid);
  return kids.size() == 1 ? kids[0] : -1;
}

std::string terminalCwd(PHLWINDOW w) {
  const auto shell = shellOf(w);
  return shell > 0 ? readLink(std::format("/proc/{}/cwd", shell)) : "";
}

struct SLabel {
  std::string text;
  std::string shellTitle; // the title while the shell waits, so a program's own title stands out
};
std::unordered_map<const void *, SLabel> g_labels;

std::string computeLabel(PHLWINDOW w) {
  const std::string title = w->m_title;
  if (!classMatches(cfg.terminals, w->m_class))
    return title.empty() ? w->m_class : title;

  auto &label = g_labels[w.get()];
  const auto shell = shellOf(w);
  const auto st = shell > 0 ? procStat(shell) : std::nullopt;
  if (!st)
    return title.empty() ? w->m_class : title;

  if (st->tpgid <= 0 || st->tpgid == st->pgrp) {
    label.shellTitle = title;
    return prettyDir(readLink(std::format("/proc/{}/cwd", shell)));
  }

  const bool ownTitle = !title.empty() && title != label.shellTitle && title != w->m_class && title != "foot";
  if (ownTitle)
    return title;
  const auto cmd = prettyCommand(cmdline(st->tpgid));
  return cmd.empty() ? title : cmd;
}

// ---------- The tab bar ----------

class CTabBar;
std::vector<WP<CTabBar>> g_bars;
Vector2D g_pointer{-1, -1};
// Per group: how far the bar is scrolled, and which tab was last current.
struct SGroupState {
  std::optional<bool> barShown;
  double scroll = 0;
  size_t lastCurrent = SIZE_MAX, lastN = 0;
  double lastTabW = 0, lastAreaW = 0;
};
std::unordered_map<const Desktop::View::CGroup *, SGroupState> g_groups;

struct STextKey {
  std::string text;
  uint64_t color;
  int width, size;
  bool operator==(const STextKey &) const = default;
};
struct STextKeyHash {
  size_t operator()(const STextKey &k) const {
    return std::hash<std::string>{}(k.text) ^ (k.color * 31) ^ (static_cast<size_t>(k.width) << 16) ^ static_cast<size_t>(k.size);
  }
};
std::unordered_map<STextKey, SP<ITexture>, STextKeyHash> g_textures;

SP<ITexture> textTexture(const std::string &text, CHyprColor color, int sizePx, int maxWidthPx) {
  STextKey key{text, color.getAsHex(), maxWidthPx, sizePx};
  if (auto it = g_textures.find(key); it != g_textures.end())
    return it->second;
  if (g_textures.size() > 512)
    g_textures.clear();
  auto tex = g_pHyprRenderer->renderText(text, color, sizePx, false, cfg.font->value(), maxWidthPx);
  g_textures.emplace(key, tex);
  return tex;
}

enum class eHit { None, Tab, Close, Plus };
struct SHit {
  eHit kind = eHit::None;
  size_t index = 0;
};

class CTabBar : public IHyprWindowDecoration {
public:
  explicit CTabBar(PHLWINDOW w) : IHyprWindowDecoration(w), m_window(w) {}
  WP<CTabBar> m_self;

  PHLWINDOW owner() const { return m_window.lock(); }

  bool visible() const {
    const auto w = m_window.lock();
    return w && w->m_group && w->m_group->size() > 1 && !Fullscreen::controller()->isFullscreen(w);
  }

  SDecorationPositioningInfo getPositioningInfo() override {
    SDecorationPositioningInfo info;
    info.policy = DECORATION_POSITION_STICKY;
    info.edges = DECORATION_EDGE_TOP;
    // Above Omarchy's title bar (10005) and the border (10000) means closest
    // to the window: under the title bar, inside the border.
    info.priority = 10010;
    info.reserved = true;
    info.desiredExtents = {Vector2D{0.0, visible() ? static_cast<double>(cfg.height->value()) : 0.0}, Vector2D{0.0, 0.0}};
    return info;
  }

  void onPositioningReply(const SDecorationPositioningReply &reply) override { m_assignedBox = reply.assignedGeometry; }
  eDecorationType getDecorationType() override { return DECORATION_CUSTOM; }
  void updateWindow(PHLWINDOW) override { damageEntire(); }
  eDecorationLayer getDecorationLayer() override { return DECORATION_LAYER_OVER; }
  uint64_t getDecorationFlags() override { return DECORATION_ALLOWS_MOUSE_INPUT; }
  std::string getDisplayName() override { return "WindowsLikeTabs"; }

  CBox boxGlobal() const {
    const auto w = m_window.lock();
    CBox box = m_assignedBox;
    if (!w)
      return box;
    box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(DECORATION_EDGE_TOP, w));
    if (w->m_workspace && !w->m_pinned)
      box.translate(w->m_workspace->m_renderOffset->value());
    return box.round();
  }

  void damageEntire() override {
    const auto w = m_window.lock();
    if (!w)
      return;
    auto box = boxGlobal();
    box.translate(w->m_floatingOffset);
    g_pHyprRenderer->damageBox(box);
  }

  struct SLayout {
    CBox bar, area, plus;
    double tabW = 0, maxScroll = 0, scroll = 0;
    size_t n = 0, current = 0;
  };

  SLayout layout() const {
    SLayout l;
    const auto w = m_window.lock();
    if (!w || !w->m_group)
      return l;
    l.bar = boxGlobal();
    l.n = w->m_group->size();
    l.current = w->m_group->getCurrentIdx();
    const double plusW = l.bar.h;
    l.area = {l.bar.x, l.bar.y, std::max(0.0, l.bar.w - plusW), l.bar.h};
    l.plus = {l.bar.x + l.area.w, l.bar.y, plusW, l.bar.h};
    l.tabW = std::max(static_cast<double>(cfg.minWidth->value()), l.n ? l.area.w / l.n : l.area.w);
    l.tabW = std::min(l.tabW, std::max(l.area.w, 1.0));
    l.maxScroll = std::max(0.0, l.tabW * l.n - l.area.w);

    auto &gs = g_groups[w->m_group.get()];
    // Bring the current tab into view when it changes, or the tabs do.
    if (gs.lastCurrent != l.current || gs.lastN != l.n || gs.lastTabW != l.tabW || gs.lastAreaW != l.area.w) {
      gs.lastCurrent = l.current;
      gs.lastN = l.n;
      gs.lastTabW = l.tabW;
      gs.lastAreaW = l.area.w;
      const double left = l.current * l.tabW, right = left + l.tabW;
      if (left < gs.scroll)
        gs.scroll = left;
      else if (right > gs.scroll + l.area.w)
        gs.scroll = right - l.area.w;
    }
    gs.scroll = std::clamp(gs.scroll, 0.0, l.maxScroll);
    l.scroll = gs.scroll;
    return l;
  }

  static CBox tabBox(const SLayout &l, size_t i) { return {l.area.x + i * l.tabW - l.scroll, l.bar.y, l.tabW, l.bar.h}; }

  static CBox closeBox(const SLayout &l, size_t i) {
    const auto t = tabBox(l, i);
    const double s = std::round(l.bar.h * 0.6);
    return {t.x + 6, t.y + (t.h - s) / 2, s, s};
  }

  bool closeShown(const SLayout &l, size_t i) const {
    return i == l.current || (l.area.containsPoint(g_pointer) && tabBox(l, i).containsPoint(g_pointer));
  }

  SHit hit(const Vector2D &pos) const {
    const auto l = layout();
    if (!l.bar.containsPoint(pos) || l.n == 0)
      return {};
    if (l.plus.containsPoint(pos))
      return {eHit::Plus, 0};
    if (!l.area.containsPoint(pos))
      return {};
    const size_t i = std::min(l.n - 1, static_cast<size_t>((pos.x - l.area.x + l.scroll) / l.tabW));
    if (closeShown(l, i) && closeBox(l, i).containsPoint(pos))
      return {eHit::Close, i};
    return {eHit::Tab, i};
  }

  void draw(PHLMONITOR mon, float const &a) override {
    const bool VIS = visible();
    if (!m_lastVisible.has_value() || *m_lastVisible != VIS) {
      m_lastVisible = VIS;
      g_pDecorationPositioner->repositionDeco(this);
    }
    if (const auto w = m_window.lock(); w && w->m_group) {
      // The bar showing or going: keep the window's frame where it is, and
      // give the bar's room from (or back to) the content, like a Mac.
      auto &gs = g_groups[w->m_group.get()];
      if (gs.barShown.value_or(false) != VIS) {
        gs.barShown = VIS;
        keepFrame(w, VIS);
      }
    }
    if (!VIS)
      return;
    const auto w = m_window.lock();
    const auto l = layout();
    if (l.bar.w <= 0 || l.bar.h <= 0)
      return;

    const double scale = mon->m_scale;
    const Vector2D off = Vector2D{-mon->m_position.x, -mon->m_position.y} + w->m_floatingOffset;
    auto toMon = [&](CBox b) {
      b.translate(off);
      b.scale(scale);
      return b.round();
    };
    const CBox clip = toMon(l.area);

    auto rect = [&](const CBox &b, CHyprColor color, const CBox &clipBox, int round = 0) {
      if (b.w <= 0 || b.h <= 0)
        return;
      CRectPassElement::SRectData d;
      d.box = toMon(b);
      color.a *= a;
      d.color = color;
      d.clipBox = clipBox;
      d.round = round;
      g_pHyprRenderer->addPassElement(makeUnique<CRectPassElement>(d));
    };
    auto tex = [&](const SP<ITexture> &t, const Vector2D &centerGlobal, const CBox &clipBox) {
      if (!t)
        return;
      CTexPassElement::SRenderData d;
      d.tex = t;
      const Vector2D c = (centerGlobal + off) * scale;
      d.box = CBox{std::round(c.x - t->m_size.x / 2.0), std::round(c.y - t->m_size.y / 2.0), t->m_size.x, t->m_size.y};
      d.a = a;
      d.clipBox = clipBox;
      g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(std::move(d)));
    };

    const CHyprColor BAR(cfg.bar->value()), ACTIVE(cfg.active->value()), HOVER(cfg.hover->value()), TEXT(cfg.text->value()),
        TEXTIN(cfg.textInactive->value()), SEP(cfg.separator->value()), BUTTON(cfg.button->value());
    const int fontPx = std::round(cfg.fontSize->value() * scale);
    const auto pointerHit = hit(g_pointer);

    rect(l.bar, BAR, {});

    const auto windows = w->m_group->windows();
    for (size_t i = 0; i < l.n && i < windows.size(); ++i) {
      const auto tw = windows[i].lock();
      if (!tw)
        continue;
      const auto t = tabBox(l, i);
      if (t.x + t.w < l.area.x || t.x > l.area.x + l.area.w)
        continue;
      const bool isCurrent = i == l.current;
      const bool hovered = pointerHit.kind != eHit::None && pointerHit.kind != eHit::Plus && pointerHit.index == i;
      if (isCurrent)
        rect(t, ACTIVE, clip);
      else if (hovered)
        rect(t, HOVER, clip);

      // A line between two inactive tabs.
      if (i + 1 < l.n && !isCurrent && i + 1 != l.current)
        rect({t.x + t.w - 1, t.y + t.h * 0.25, 1, t.h * 0.5}, SEP, clip);

      // Title, centered in the space right of the close button.
      const double closeW = closeBox(l, i).w + 12;
      const int maxW = std::max(1, static_cast<int>((t.w - 2 * closeW) * scale));
      const auto label = labelFor(tw);
      tex(textTexture(label, isCurrent ? TEXT : TEXTIN, fontPx, maxW), {t.x + t.w / 2, t.y + t.h / 2}, clip);

      if (closeShown(l, i)) {
        const auto cb = closeBox(l, i);
        if (pointerHit.kind == eHit::Close && pointerHit.index == i)
          rect(cb, BUTTON, clip, std::round(3 * scale));
        tex(textTexture("×", isCurrent ? TEXT : TEXTIN, std::round(fontPx * 1.3), 0), {cb.x + cb.w / 2, cb.y + cb.h / 2}, clip);
      }
    }

    if (pointerHit.kind == eHit::Plus) {
      const CBox pb{l.plus.x + 4, l.plus.y + 4, l.plus.w - 8, l.plus.h - 8};
      rect(pb, BUTTON, {}, std::round(4 * scale));
    }
    tex(textTexture("+", TEXT, std::round(fontPx * 1.4), 0), {l.plus.x + l.plus.w / 2, l.plus.y + l.plus.h / 2}, {});
  }

  bool onInputOnDeco(const eInputType type, const Vector2D &pos, std::any data) override {
    if (!visible())
      return false;
    switch (type) {
    case INPUT_TYPE_BUTTON: return onButton(pos, std::any_cast<const IPointer::SButtonEvent &>(data));
    case INPUT_TYPE_AXIS: return onAxis(std::any_cast<const IPointer::SAxisEvent>(data));
    case INPUT_TYPE_DRAG_END: return onDrop(std::any_cast<PHLWINDOW>(data));
    default: return false;
    }
  }

  static std::string labelFor(PHLWINDOW w) {
    auto it = g_labels.find(w.get());
    if (it == g_labels.end() || it->second.text.empty())
      g_labels[w.get()].text = computeLabel(w);
    return g_labels[w.get()].text;
  }

private:
  PHLWINDOWREF m_window;
  CBox m_assignedBox;
  std::optional<bool> m_lastVisible;
  SHit m_pressed;
  uint32_t m_pressedButton = 0;

  bool onButton(const Vector2D &pos, const IPointer::SButtonEvent &e) {
    const auto w = m_window.lock();
    const auto h = hit(pos);
    if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
      m_pressed = h;
      m_pressedButton = e.button;
      if (e.button == BTN_LEFT) {
        if (h.kind == eHit::Tab)
          select(w, h.index);
        else if (h.kind == eHit::Plus)
          newTab(w->m_group ? w->m_group->current() : w);
      }
      return true;
    }
    // Closing waits for the release over the same tab, like a button.
    const bool same = h.kind == m_pressed.kind && h.index == m_pressed.index && e.button == m_pressedButton;
    if (same && w && w->m_group) {
      const bool close = (e.button == BTN_LEFT && h.kind == eHit::Close) || (e.button == BTN_MIDDLE && (h.kind == eHit::Tab || h.kind == eHit::Close));
      if (close)
        if (const auto target = w->m_group->fromIndex(h.index))
          g_pXWaylandManager->sendCloseWindow(target);
    }
    m_pressed = {};
    return true;
  }

  bool onAxis(const IPointer::SAxisEvent &e) {
    const auto w = m_window.lock();
    if (!w || !w->m_group)
      return true;
    auto &gs = g_groups[w->m_group.get()];
    const auto l = layout();
    // Wheel notches are coarse; touchpads send small, smooth steps.
    const double step = e.deltaDiscrete != 0 ? e.delta * 4 : e.delta * 1.5;
    gs.scroll = std::clamp(gs.scroll + step, 0.0, l.maxScroll);
    damageEntire();
    return true;
  }

  bool onDrop(PHLWINDOW dragged) {
    const auto w = m_window.lock();
    if (!w || !w->m_group || !dragged || dragged == w || !dragged->canBeGroupedInto(w->m_group))
      return false;
    w->m_group->add(dragged);
    return true;
  }

public:
  static void select(PHLWINDOW anyMember, size_t index) {
    if (!anyMember || !anyMember->m_group)
      return;
    const auto target = anyMember->m_group->fromIndex(index);
    if (!target)
      return;
    anyMember->m_group->setCurrent(target);
    Desktop::focusState()->rawWindowFocus(target, Desktop::FOCUS_REASON_CLICK);
    if (target->m_isFloating)
      Desktop::windowState()->raise(target);
  }

  static bool newTab(PHLWINDOW w);
  static void keepFrame(PHLWINDOW w, bool barShown);
};

// ---------- No animations for tabs ----------
//
// Opening or closing a tab is a window mapping or unmapping, and the tab bar
// appearing or going changes the window's size: all of which Hyprland would
// animate. Switching tabs doesn't animate, so neither should these. A window
// joining or leaving a tab group gets the no_anim property while it does (so
// it neither pops in nor fades out), and for a few frames afterwards any move,
// resize or fade on the group's windows is finished at once.

struct SQuiet {
  PHLWINDOWREF window;
  bool setNoAnim = false;
};
std::vector<SQuiet> g_quiet;
std::chrono::steady_clock::time_point g_quietUntil;
SP<CEventLoopTimer> g_quietTimer;

void finishAnimations(PHLWINDOW w) {
  w->positionAnimation()->warp();
  w->sizeAnimation()->warp();
  for (int i = 0; i < Desktop::View::WINDOW_ALPHA_LAST; ++i)
    w->alpha(static_cast<Desktop::View::eWindowAlpha>(i))->warp();
}

void quiet(PHLWINDOW w, bool noAnim) {
  if (!w)
    return;
  if (noAnim && !w->m_ruleApplicator->noAnim().valueOrDefault()) {
    w->m_ruleApplicator->noAnim().set(true, Desktop::Types::PRIORITY_SET_PROP);
    g_quiet.push_back({w, true});
  } else
    g_quiet.push_back({w, false});
  g_quietUntil = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
  if (g_quietTimer)
    g_quietTimer->updateTimeout(std::chrono::milliseconds(1));
}

void quietGroupOf(PHLWINDOW w, bool noAnim) {
  if (!w)
    return;
  quiet(w, noAnim);
  if (w->m_group)
    for (const auto &ref : w->m_group->windows())
      if (const auto m = ref.lock(); m && m != w)
        quiet(m, false);
}

void onQuietTick() {
  // Members of groups the quiet windows belong to now, as well as the windows.
  for (const auto &q : g_quiet) {
    const auto w = q.window.lock();
    if (!w)
      continue;
    finishAnimations(w);
    if (w->m_group)
      for (const auto &ref : w->m_group->windows())
        if (const auto m = ref.lock())
          finishAnimations(m);
  }
  if (std::chrono::steady_clock::now() < g_quietUntil) {
    g_quietTimer->updateTimeout(std::chrono::milliseconds(8));
    return;
  }
  for (const auto &q : g_quiet)
    if (const auto w = q.window.lock(); w && q.setNoAnim)
      w->m_ruleApplicator->noAnim().unset(Desktop::Types::PRIORITY_SET_PROP);
  g_quiet.clear();
}

// Hyprland adds a decoration's room outside the window's content, so the tab
// bar appearing would push the window's top (title bar) up by its height.
// Floating windows move their content down and shrink it instead; tiled ones
// keep their tile and lay out inside it already.
void CTabBar::keepFrame(PHLWINDOW w, bool barShown) {
  const PHLWINDOWREF ref = w;
  g_pEventLoopManager->doLater([ref, barShown] {
    const auto w = ref.lock();
    if (!validMapped(w))
      return;
    const auto target = w->layoutTarget();
    if (!target || !target->floating() || !target->space())
      return;
    const double h = cfg.height->value();
    CBox box = target->position();
    const double delta = barShown ? h : -h;
    if (box.h - delta < 50)
      return;
    box.y += delta;
    box.h -= delta;
    g_layoutManager->setTargetGeom(box, target);
    quietGroupOf(w, false);
  });
}

// ---------- New tabs ----------

struct SPending {
  PHLWINDOWREF anchor;
  std::string cls;
  std::chrono::steady_clock::time_point until;
};
std::optional<SPending> g_pending;

std::string shellQuote(const std::string &s) {
  std::string out = "'";
  for (char c : s)
    out += c == '\'' ? std::string("'\\''") : std::string(1, c);
  return out + "'";
}

// Opens another window of w's app; the next window of that class to open
// becomes a tab of w's group. Terminals open in the current tab's folder.
bool CTabBar::newTab(PHLWINDOW w) {
  if (!w)
    return false;
  const auto pid = w->getPID();
  if (pid <= 0)
    return false;
  const auto exe = readLink(std::format("/proc/{}/exe", pid));
  if (exe.empty())
    return false;
  std::string cmd = shellQuote(exe);
  const auto base = baseName(exe);
  if (classMatches(cfg.terminals, w->m_class)) {
    const auto cwd = terminalCwd(w);
    if (!cwd.empty()) {
      if (base == "foot" || base == "footclient" || base == "alacritty" || base == "ghostty")
        cmd += " --working-directory=" + shellQuote(cwd);
      else if (base == "kitty")
        cmd += " --directory=" + shellQuote(cwd);
    }
    if (base == "foot" || base == "footclient")
      cmd += " --app-id=" + shellQuote(w->m_class);
  }
  g_pending = SPending{w, w->m_class, std::chrono::steady_clock::now() + std::chrono::seconds(10)};
  Config::Supplementary::executor()->spawn(cmd);
  return true;
}

void adoptIfPending(PHLWINDOW w) {
  if (!g_pending || !w)
    return;
  if (std::chrono::steady_clock::now() > g_pending->until) {
    g_pending.reset();
    return;
  }
  if (w->m_class != g_pending->cls || w == g_pending->anchor.lock())
    return;
  const PHLWINDOWREF anchorRef = g_pending->anchor;
  const PHLWINDOWREF newRef = w;
  g_pending.reset();
  // Before Hyprland starts the window's open animation.
  quiet(w, true);
  quietGroupOf(anchorRef.lock(), false);
  // Let the window finish opening (and Omarchy's rules place it) first.
  g_pEventLoopManager->doLater([anchorRef, newRef] {
    const auto anchor = anchorRef.lock();
    const auto nw = newRef.lock();
    if (!validMapped(anchor) || !validMapped(nw))
      return;
    if (!anchor->m_group)
      (void)Config::Actions::toggleGroup(anchor);
    if (!anchor->m_group)
      return;
    anchor->m_group->add(nw);
    CTabBar::select(nw, anchor->m_group->size() - 1);
    quietGroupOf(nw, false);
  });
}

// ---------- Shortcuts ----------

bool tabAction(const std::string &action, long n) {
  const auto w = Desktop::focusState()->window();
  if (!w || !classMatches(cfg.tabApps, w->m_class))
    return false;
  const auto &group = w->m_group;
  if (action == "new")
    return CTabBar::newTab(w);
  if (action == "close") {
    g_pXWaylandManager->sendCloseWindow(w);
    return true;
  }
  if (!group || group->size() < 2)
    return false;
  if (action == "select") {
    if (n < 1)
      return false;
    const size_t idx = n >= 9 ? group->size() - 1 : static_cast<size_t>(n - 1);
    if (idx >= group->size())
      return true;
    CTabBar::select(w, idx);
    return true;
  }
  if (action == "next" || action == "prev") {
    const size_t size = group->size(), cur = group->getCurrentIdx();
    CTabBar::select(w, action == "next" ? (cur + 1) % size : (cur + size - 1) % size);
    return true;
  }
  return false;
}

int luaTab(lua_State *L) {
  const char *action = lua_tostring(L, 1);
  const long n = lua_isnumber(L, 2) ? static_cast<long>(lua_tonumber(L, 2)) : 0;
  lua_pushboolean(L, action && tabAction(action, n));
  return 1;
}

// ---------- Bookkeeping ----------

void addBar(PHLWINDOW w) {
  if (!w || std::ranges::any_of(w->m_windowDecorations, [](const auto &d) { return d->getDisplayName() == "WindowsLikeTabs"; }))
    return;
  auto bar = makeUnique<CTabBar>(w);
  WP<CTabBar> weak = bar;
  bar->m_self = weak;
  g_bars.emplace_back(weak);
  HyprlandAPI::addWindowDecoration(g_handle, w, std::move(bar));
}

// Names change as programs start and stop in terminals; check once a second.
SP<CEventLoopTimer> g_labelTimer;
void refreshLabels() {
  std::erase_if(g_bars, [](const auto &b) { return !b || !b->owner(); });
  for (const auto &b : g_bars) {
    if (!b->visible())
      continue;
    const auto w = b->owner();
    bool changed = false;
    for (const auto &ref : w->m_group->windows()) {
      const auto m = ref.lock();
      if (!m)
        continue;
      const auto text = computeLabel(m);
      auto &label = g_labels[m.get()];
      if (label.text != text) {
        label.text = text;
        changed = true;
      }
    }
    if (changed)
      b->damageEntire();
  }
}

std::string jsonEscape(const std::string &s) {
  std::string o;
  for (char c : s) {
    if (c == '"' || c == '\\')
      o += '\\', o += c;
    else if (static_cast<unsigned char>(c) < 0x20)
      o += std::format("\\u{:04x}", static_cast<int>(c));
    else
      o += c;
  }
  return o;
}

std::string boxJson(const CBox &b) { return std::format("[{},{},{},{}]", std::lround(b.x), std::lround(b.y), std::lround(b.w), std::lround(b.h)); }

std::string tabsJson(eHyprCtlOutputFormat, std::string) {
  refreshLabels();
  std::string out = "[";
  bool first = true;
  for (const auto &b : g_bars) {
    if (!b || !b->visible())
      continue;
    const auto w = b->owner();
    if (w->m_group->current() != w)
      continue;
    const auto l = b->layout();
    std::string tabs;
    const auto windows = w->m_group->windows();
    for (size_t i = 0; i < windows.size(); ++i) {
      const auto m = windows[i].lock();
      if (!m)
        continue;
      tabs += std::format("{}{{\"address\":\"0x{:x}\",\"label\":\"{}\",\"box\":{},\"close\":{}}}", tabs.empty() ? "" : ",",
                          reinterpret_cast<uintptr_t>(m.get()), jsonEscape(CTabBar::labelFor(m)), boxJson(CTabBar::tabBox(l, i)),
                          boxJson(CTabBar::closeBox(l, i)));
    }
    out += std::format("{}{{\"window\":\"0x{:x}\",\"current\":{},\"bar\":{},\"area\":{},\"plus\":{},\"scroll\":{},\"maxScroll\":{},\"tabs\":[{}]}}",
                       first ? "" : ",", reinterpret_cast<uintptr_t>(w.get()), l.current, boxJson(l.bar), boxJson(l.area), boxJson(l.plus),
                       std::lround(l.scroll), std::lround(l.maxScroll), tabs);
    first = false;
  }
  return out + "]";
}

CHyprSignalListener g_openListener, g_closeListener, g_unmapListener;

// For tests: what is animating or fading out right now.
std::string animJson(eHyprCtlOutputFormat, std::string) {
  std::string animating;
  for (const auto &w : Desktop::windowState()->windows()) {
    if (!w || !w->m_isMapped)
      continue;
    bool busy = w->positionAnimation()->isBeingAnimated() || w->sizeAnimation()->isBeingAnimated();
    for (int i = 0; i < Desktop::View::WINDOW_ALPHA_LAST; ++i)
      busy = busy || w->alpha(static_cast<Desktop::View::eWindowAlpha>(i))->isBeingAnimated();
    if (busy)
      animating += std::format("{}\"0x{:x}\"", animating.empty() ? "" : ",", reinterpret_cast<uintptr_t>(w.get()));
  }
  return std::format("{{\"fadeouts\":{},\"animating\":[{}]}}", Desktop::fadingOutState()->fadeouts().size(), animating);
}
SP<SHyprCtlCommand> g_animCommand;
SP<SHyprCtlCommand> g_ctlCommand;

} // namespace

namespace Tabs {

void init(HANDLE handle) {
  g_handle = handle;
  registerConfig();
  HyprlandAPI::addLuaFunction(handle, "windows_like", "tab", ::luaTab);
  g_ctlCommand = HyprlandAPI::registerHyprCtlCommand(handle, SHyprCtlCommand{.name = "windowslike-tabs", .exact = true, .fn = tabsJson});

  g_openListener = Event::bus()->m_events.window.open.listen([](PHLWINDOW w) {
    addBar(w);
    adoptIfPending(w);
  });
  // A tab closing: no fade-out, and no resize as the tab bar goes.
  g_unmapListener = Event::bus()->m_events.window.close.listen([](PHLWINDOW w) {
    if (w && w->m_group && w->m_group->size() > 1)
      quietGroupOf(w, true);
  });
  g_closeListener = Event::bus()->m_events.window.destroy.listen([](PHLWINDOWREF w) {
    if (const auto p = w.lock())
      g_labels.erase(p.get());
  });

  for (const auto &w : Desktop::windowState()->windows())
    if (validMapped(w))
      addBar(w);

  g_labelTimer = makeShared<CEventLoopTimer>(
      std::chrono::milliseconds(1000),
      [](SP<CEventLoopTimer> self, void *) {
        refreshLabels();
        self->updateTimeout(std::chrono::milliseconds(1000));
      },
      nullptr);
  g_pEventLoopManager->addTimer(g_labelTimer);

  g_quietTimer = makeShared<CEventLoopTimer>(std::nullopt, [](SP<CEventLoopTimer>, void *) { onQuietTick(); }, nullptr);
  g_pEventLoopManager->addTimer(g_quietTimer);
  g_animCommand = HyprlandAPI::registerHyprCtlCommand(handle, SHyprCtlCommand{.name = "windowslike-anim", .exact = true, .fn = animJson});
}

void exit() {
  if (g_labelTimer) {
    g_labelTimer->cancel();
    g_pEventLoopManager->removeTimer(g_labelTimer);
    g_labelTimer.reset();
  }
  if (g_quietTimer) {
    g_quietTimer->cancel();
    g_pEventLoopManager->removeTimer(g_quietTimer);
    g_quietTimer.reset();
  }
  for (const auto &q : g_quiet)
    if (const auto w = q.window.lock(); w && q.setNoAnim)
      w->m_ruleApplicator->noAnim().unset(Desktop::Types::PRIORITY_SET_PROP);
  g_quiet.clear();
  g_openListener.reset();
  g_unmapListener.reset();
  g_closeListener.reset();
  g_bars.clear();
  g_textures.clear();
  g_labels.clear();
  g_groups.clear();
  g_pending.reset();
}

void onMouseMove(const Vector2D &pos) {
  const auto old = g_pointer;
  g_pointer = pos;
  for (const auto &b : g_bars) {
    if (!b || !b->visible())
      continue;
    const auto box = b->boxGlobal();
    if (box.containsPoint(pos) || box.containsPoint(old))
      b->damageEntire();
  }
}

} // namespace Tabs
