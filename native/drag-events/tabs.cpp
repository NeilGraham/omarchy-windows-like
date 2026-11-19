// Tabs for any window, built on Hyprland groups.
//
// The tabs sit in Omarchy's title bar: the app's logo where its name was,
// then one tab per window in the group, then a "+" that opens another window
// of the same app as a new tab, leaving the title bar's buttons free at the
// right. Apps with tab shortcuts (foot) show their tab from the start; other
// windows once they have a second tab. Each tab has a close button (on the
// active tab, and on any tab under the pointer), and when the tabs no longer
// fit they keep a minimum width and scroll sideways (wheel or touchpad). A
// window without a title bar (a tiled one) gets a bar of its own under the
// border instead, once it has a second tab.
//
// Clicks reach the tabs before the title bar does, through a hook on
// CInputManager::onMouseButton, and presses on a tab, its close button or "+"
// stay with the tabs (the logo and the empty title bar are the title bar's).
// A press on a tab selects it; dragged a few pixels, the tab follows the
// pointer along the strip to a new place among the tabs, or out of the strip
// it tears off into a window of its own that goes on being dragged; a window
// carried by its tab over another window's tabs joins them where it is
// dropped. See "Dragging tabs" below.
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
#include <hyprland/src/config/ConfigManager.hpp>
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
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/XWaylandManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
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

#include <hyprgraphics/image/Image.hpp>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <filesystem>
#include <cmath>
#include <format>
#include <fstream>
#include <regex>
#include <sstream>
#include <typeinfo>
#include <unistd.h>
#include <unordered_map>

using namespace Render;

namespace {

HANDLE g_handle = nullptr;

// ---------- Config ----------

struct {
  SP<Config::Values::CIntValue> height, minWidth, maxWidth, buttonsWidth, fontSize, enabled, terminalNames, sideResize, jointResize;
  SP<Config::Values::CStringValue> font, tabApps, terminals, tabPrograms, terminalPrograms;
  SP<Config::Values::CColorValue> bar, titlebar, active, hover, text, textInactive, separator, button;
} cfg;

void registerConfig() {
  using namespace Config::Values;
  cfg.enabled = makeShared<CIntValue>("plugin:windows_like:tabs", "Tabs on (1) or off (0)", 1);
  cfg.jointResize = makeShared<CIntValue>("plugin:windows_like:joint_resize", "Resize windows that share an edge together (1) or one at a time (0)", 1);
  cfg.sideResize = makeShared<CIntValue>("plugin:windows_like:side_resize", "Resize from the side pressed and show the top-edge cursor (1), or leave it to Hyprland (0)", 1);
  cfg.terminalNames = makeShared<CIntValue>("plugin:windows_like:terminal_names", "Name terminal tabs after what runs in them (1) or use titles (0)", 1);
  cfg.height = makeShared<CIntValue>("plugin:windows_like:tab_height", "Height of the tab bar of a window without a title bar", 28);
  cfg.minWidth = makeShared<CIntValue>("plugin:windows_like:tab_min_width", "Narrowest a tab gets before the tabs scroll", 140);
  cfg.maxWidth = makeShared<CIntValue>("plugin:windows_like:tab_max_width", "Widest a tab gets", 220);
  cfg.buttonsWidth = makeShared<CIntValue>("plugin:windows_like:tab_buttons_width",
                                           "Room kept free at the right of the title bar for its buttons (Omarchy's: three of 20 px, 8 px apart, 10 px in)", 94);
  cfg.fontSize = makeShared<CIntValue>("plugin:windows_like:tab_font_size", "Tab title size", 11);
  cfg.font = makeShared<CStringValue>("plugin:windows_like:tab_font", "Tab title font", "sans-serif");
  cfg.tabApps = makeShared<CStringValue>("plugin:windows_like:tab_apps", "Classes (regex) whose tab shortcuts act on tabs",
                                         "^(foot|footclient)$");
  cfg.terminals = makeShared<CStringValue>("plugin:windows_like:terminals", "Classes (regex) of terminals, named after what runs in them",
                                           "^(foot|footclient|kitty|Alacritty|com\\.mitchellh\\.ghostty)$");
  cfg.tabPrograms = makeShared<CStringValue>("plugin:windows_like:tab_programs",
                                             "Programs (regex on the executable's name) whose tab shortcuts act on tabs, whatever their class",
                                             "^(foot|footclient)$");
  cfg.terminalPrograms = makeShared<CStringValue>("plugin:windows_like:terminal_programs", "Programs (regex on the executable's name) that are terminals",
                                                  "^(foot|footclient|kitty|alacritty|ghostty)$");
  cfg.bar = makeShared<CColorValue>("plugin:windows_like:col.bar", "Tab bar of a window without a title bar", 0xff161618);
  cfg.titlebar = makeShared<CColorValue>("plugin:windows_like:col.titlebar", "The title bar's color, laid over its title", 0xff2c2c2e);
  cfg.active = makeShared<CColorValue>("plugin:windows_like:col.active", "Active tab color", 0xff2c2c2e);
  cfg.hover = makeShared<CColorValue>("plugin:windows_like:col.hover", "Inactive tab under the pointer", 0xff222224);
  cfg.text = makeShared<CColorValue>("plugin:windows_like:col.text", "Active tab title", 0xfff5f5f7);
  cfg.textInactive = makeShared<CColorValue>("plugin:windows_like:col.text_inactive", "Inactive tab title", 0xff98989d);
  cfg.separator = makeShared<CColorValue>("plugin:windows_like:col.separator", "Line between inactive tabs", 0xff3a3a3c);
  cfg.button = makeShared<CColorValue>("plugin:windows_like:col.button_hover", "Close and + buttons under the pointer", 0xff48484a);
  for (const SP<Config::Values::IValue> v : std::initializer_list<SP<Config::Values::IValue>>{
           cfg.enabled, cfg.terminalNames, cfg.sideResize, cfg.jointResize, cfg.height, cfg.minWidth, cfg.maxWidth, cfg.buttonsWidth, cfg.fontSize, cfg.font, cfg.tabApps,
           cfg.terminals, cfg.tabPrograms, cfg.terminalPrograms, cfg.bar, cfg.titlebar, cfg.active, cfg.hover, cfg.text,
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

// The executable a window's process runs, e.g. "foot" for a foot window with
// an app id of its own (Omarchy's agent terminal is one).
std::string programOf(PHLWINDOW w) {
  const auto pid = w ? w->getPID() : -1;
  return pid > 0 ? baseName(readLink(std::format("/proc/{}/exe", pid))) : "";
}

pid_t parentOf(pid_t pid) {
  const auto s = readFile(std::format("/proc/{}/stat", pid));
  const auto close = s.rfind(')');
  if (close == std::string::npos)
    return -1;
  std::istringstream in(s.substr(close + 2));
  std::string state;
  long ppid = -1;
  in >> state >> ppid;
  return static_cast<pid_t>(ppid);
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

bool isTerminal(PHLWINDOW w) { return classMatches(cfg.terminals, w->m_class) || classMatches(cfg.terminalPrograms, programOf(w)); }

bool hasTabShortcuts(PHLWINDOW w) { return classMatches(cfg.tabApps, w->m_class) || classMatches(cfg.tabPrograms, programOf(w)); }

struct SLabel {
  std::string text;
  std::string shellTitle; // the title while the shell waits, so a program's own title stands out
};
std::unordered_map<const void *, SLabel> g_labels;

std::string computeLabel(PHLWINDOW w) {
  const std::string title = w->m_title;
  if (!cfg.terminalNames->value() || !isTerminal(w))
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

// ---------- App logos ----------
//
// The logo at the left of the tabs is the app's icon: the Icon= of its
// .desktop file (found by name or StartupWMClass), looked up in the icon
// theme GTK is set to, the themes it inherits, and hicolor.

std::string lower(std::string s) {
  std::ranges::transform(s, s.begin(), [](unsigned char c) { return std::tolower(c); });
  return s;
}

std::vector<std::string> dataDirs() {
  std::vector<std::string> out;
  const char *home = getenv("HOME");
  const char *dataHome = getenv("XDG_DATA_HOME");
  if (dataHome && *dataHome)
    out.emplace_back(dataHome);
  else if (home)
    out.emplace_back(std::string(home) + "/.local/share");
  const char *dirs = getenv("XDG_DATA_DIRS");
  std::stringstream ss(dirs && *dirs ? dirs : "/usr/local/share:/usr/share");
  std::string d;
  while (std::getline(ss, d, ':'))
    if (!d.empty())
      out.push_back(d);
  return out;
}

// key=value from the [Desktop Entry] (or [Icon Theme]) group of an ini file.
std::string iniValue(const std::string &text, const std::string &key) {
  std::istringstream in(text);
  std::string line;
  bool mainGroup = false;
  while (std::getline(in, line)) {
    if (line.starts_with("[")) {
      if (mainGroup)
        break;
      mainGroup = line == "[Desktop Entry]" || line == "[Icon Theme]" || line == "[Settings]";
      continue;
    }
    if (mainGroup && line.starts_with(key + "=")) {
      auto v = line.substr(key.size() + 1);
      while (!v.empty() && (v.back() == '\r' || v.back() == ' '))
        v.pop_back();
      return v;
    }
  }
  return "";
}

// The .desktop file of a window class: named after it, or else claiming it
// with StartupWMClass. Empty when there is none.
std::string desktopEntryFor(const std::string &cls) {
  if (cls.empty())
    return "";
  const auto want = lower(cls);
  std::string byWmClass;
  for (const auto &dir : dataDirs()) {
    const auto apps = dir + "/applications/";
    for (const auto &name : {cls, want})
      if (auto text = readFile(apps + name + ".desktop"); !iniValue(text, "Icon").empty() || !iniValue(text, "Name").empty())
        return text;
    if (!byWmClass.empty())
      continue;
    std::error_code ec;
    for (const auto &entry : std::filesystem::directory_iterator(apps, ec)) {
      if (entry.path().extension() != ".desktop")
        continue;
      auto text = readFile(entry.path());
      if (lower(iniValue(text, "StartupWMClass")) == want) {
        byWmClass = std::move(text);
        break;
      }
    }
  }
  return byWmClass;
}

struct SAppInfo {
  std::string name, iconPath; // iconPath "" when there is none
};
std::unordered_map<std::string, SAppInfo> g_apps; // class -> app

std::string iconPathFor(const std::string &icon);

const SAppInfo &appFor(const std::string &cls) {
  auto it = g_apps.find(cls);
  if (it != g_apps.end())
    return it->second;
  const auto entry = desktopEntryFor(cls);
  auto icon = iniValue(entry, "Icon");
  auto name = iniValue(entry, "Name");
  return g_apps.emplace(cls, SAppInfo{name.empty() ? cls : name, iconPathFor(icon.empty() ? lower(cls) : icon)}).first->second;
}

// GTK's settings.ini, or else gsettings (where Omarchy sets it), read once.
std::string iconThemeName() {
  static std::optional<std::string> theme;
  if (theme)
    return *theme;
  theme = "hicolor";
  if (const char *home = getenv("HOME"))
    for (const auto &file : {"/.config/gtk-4.0/settings.ini", "/.config/gtk-3.0/settings.ini"})
      if (const auto v = iniValue(readFile(std::string(home) + file), "gtk-icon-theme-name"); !v.empty())
        return *(theme = v);
  if (FILE *p = popen("timeout 2 gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null", "r")) {
    char buf[256] = {};
    const auto n = fread(buf, 1, sizeof(buf) - 1, p);
    pclose(p);
    std::string v(buf, n);
    std::erase_if(v, [](char c) { return c == '\'' || c == '\n' || c == ' '; });
    if (!v.empty())
      theme = v;
  }
  return *theme;
}

std::string iconPathFor(const std::string &icon) {
  if (icon.empty())
    return "";
  if (icon.starts_with("/"))
    return std::filesystem::exists(icon) ? icon : "";
  std::vector<std::string> bases;
  if (const char *home = getenv("HOME"))
    bases.push_back(std::string(home) + "/.icons");
  for (const auto &d : dataDirs())
    bases.push_back(d + "/icons");

  // The theme, what it inherits, then hicolor.
  std::vector<std::string> themes{iconThemeName()};
  for (size_t i = 0; i < themes.size() && i < 8; ++i)
    for (const auto &base : bases) {
      const auto index = readFile(base + "/" + themes[i] + "/index.theme");
      if (index.empty())
        continue;
      std::stringstream inherits(iniValue(index, "Inherits"));
      std::string t;
      while (std::getline(inherits, t, ','))
        if (!t.empty() && std::ranges::find(themes, t) == themes.end())
          themes.push_back(t);
      break;
    }
  if (std::ranges::find(themes, "hicolor") == themes.end())
    themes.push_back("hicolor");

  for (const auto &theme : themes) {
    std::string best;
    int bestScore = -1;
    for (const auto &base : bases) {
      const auto root = base + "/" + theme;
      const auto index = readFile(root + "/index.theme");
      std::stringstream dirs(iniValue(index, "Directories") + "," + iniValue(index, "ScaledDirectories"));
      std::string dir;
      while (std::getline(dirs, dir, ',')) {
        if (dir.empty() || dir.find("symbolic") != std::string::npos)
          continue;
        for (const auto ext : {".svg", ".png"}) {
          const auto path = root + "/" + dir + "/" + icon + ext;
          if (!std::filesystem::exists(path))
            continue;
          // Scalable first, then the size nearest 64 from at least 32.
          int size = 0;
          for (char c : dir) {
            if (!std::isdigit(static_cast<unsigned char>(c))) {
              if (size)
                break;
              continue;
            }
            size = size * 10 + (c - '0');
          }
          const int score = std::string(ext) == ".svg" ? 1000 : size >= 32 ? 500 - std::abs(size - 64) : size;
          if (score > bestScore) {
            bestScore = score;
            best = path;
          }
        }
      }
    }
    if (!best.empty())
      return best;
  }
  for (const auto &d : dataDirs())
    for (const auto ext : {".svg", ".png"})
      if (const auto path = d + "/pixmaps/" + icon + ext; std::filesystem::exists(path))
        return path;
  return "";
}

std::unordered_map<std::string, SP<ITexture>> g_icons; // file@px -> texture (null when it didn't load)

SP<ITexture> logoTexture(PHLWINDOW w, int px) {
  const auto &path = appFor(w->m_class).iconPath;
  if (path.empty())
    return nullptr;
  const auto key = std::format("{}@{}", path, px);
  if (auto t = g_icons.find(key); t != g_icons.end())
    return t->second;
  SP<ITexture> tex;
  Hyprgraphics::CImage image(path, Vector2D{static_cast<double>(px), static_cast<double>(px)});
  if (image.success() && image.cairoSurface())
    tex = g_pHyprRenderer->createTexture(image.cairoSurface()->cairo());
  g_icons.emplace(key, tex);
  return tex;
}

// ---------- The tab bar ----------
//
// Where Omarchy draws a title bar (hyprbars) the tabs sit in it: the app's
// logo where its name was, then the tabs, then "+", leaving the title bar's
// buttons at the right (and a little room to drag the window by). A window
// without a title bar (a tiled one) gets a bar of its own under the border
// instead, once it has a second tab.

class CTabBar;
std::vector<WP<CTabBar>> g_bars;
Vector2D g_pointer{-1, -1};
// The app's name, shown under the logo after the pointer rests on it.
WP<CTabBar> g_tipBar;
bool g_tipShown = false;
SP<CEventLoopTimer> g_tipTimer;
constexpr auto TIP_DELAY = std::chrono::milliseconds(500);
// Per group (or per window, for a window with one tab): how far the tabs are
// scrolled, and which tab was last current.
struct SGroupState {
  std::optional<bool> ownBar;
  double scroll = 0;
  size_t lastCurrent = SIZE_MAX, lastN = 0;
  double lastTabW = 0, lastAreaW = 0;
};
std::unordered_map<const void *, SGroupState> g_groups;

// A tab being dragged, Windows Terminal style. A press on a tab that moves a
// few pixels becomes a drag: along its own strip the tab follows the pointer
// and the others move aside (reordering the group); out of the strip (or out
// of the window) it tears off into a window of its own, which is then carried
// like a title bar drag. A window carried by its tab (or a window with one
// tab, which is carried from the start) shows as a tab in any other tab strip
// it passes over, and joins those tabs if dropped there.
struct STabDrag {
  enum class eState { Pending, Reorder, Carry };
  eState state = eState::Pending;
  PHLWINDOWREF window;  // the dragged tab's window
  Vector2D start;       // where the press was
  double grabX = 0;     // the pointer's distance from the tab's left
  double grabY = 0;     // and from the bar's top
  double tabX = 0;      // from the bar's left to its first tab (the logo's room)
  PHLWINDOWREF over;    // carried: the window whose tabs it is over, if any
  size_t slot = 0;      // where among those tabs it would go
  bool hidden = false;  // the carried window hides while its tab shows there
};
std::optional<STabDrag> g_drag;
constexpr double DRAG_THRESHOLD = 6; // how far a press moves before it is a drag
constexpr double TEAR_DISTANCE = 20; // how far out of its bar a tab tears off
// The last press on a tab, for a double click (which the title bar would see).
struct SLastPress {
  PHLWINDOWREF window;
  std::chrono::steady_clock::time_point at;
};
std::optional<SLastPress> g_lastTabPress;
constexpr auto DOUBLE_CLICK = std::chrono::milliseconds(400);

const void *groupKey(PHLWINDOW w) { return w->m_group ? static_cast<const void *>(w->m_group.get()) : static_cast<const void *>(w.get()); }

std::vector<PHLWINDOW> tabsOf(PHLWINDOW w) {
  std::vector<PHLWINDOW> out;
  if (!w->m_group) {
    out.push_back(w);
    return out;
  }
  for (const auto &ref : w->m_group->windows())
    if (const auto m = ref.lock())
      out.push_back(m);
  return out;
}

// Omarchy's title bar on w, if it draws one.
IHyprWindowDecoration *titleBarOf(PHLWINDOW w) {
  if (!w || !w->m_ruleApplicator->decorate().valueOrDefault())
    return nullptr;
  for (const auto &d : w->m_windowDecorations) {
    if (d->getDisplayName() != "Hyprbar")
      continue;
    const auto info = d->getPositioningInfo();
    return info.policy == DECORATION_POSITION_STICKY && info.desiredExtents.topLeft.y > 0 ? d.get() : nullptr;
  }
  return nullptr;
}

// Apps whose tabs show from the first one (foot): their windows always have
// a tab and a "+". Asked once per window, as it reads /proc.
std::unordered_map<const void *, bool> g_alone;
bool showsAlone(PHLWINDOW w) {
  if (w->m_class.empty())
    return false;
  auto it = g_alone.find(w.get());
  if (it == g_alone.end())
    it = g_alone.emplace(w.get(), hasTabShortcuts(w)).first;
  return it->second;
}

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

enum class eMode { Hidden, TitleBar, OwnBar };

// Room left free between the "+" and the title bar's buttons, to drag the
// window by when the tabs fill the bar.
constexpr double DRAG_ROOM = 24;

class CTabBar : public IHyprWindowDecoration {
public:
  explicit CTabBar(PHLWINDOW w) : IHyprWindowDecoration(w), m_window(w) {}
  WP<CTabBar> m_self;

  PHLWINDOW owner() const { return m_window.lock(); }

  eMode mode() const {
    const auto w = m_window.lock();
    if (!cfg.enabled->value() || !w)
      return eMode::Hidden;
    const bool tabs = w->m_group && w->m_group->size() > 1;
    if (titleBarOf(w) && !Fullscreen::controller()->isFullscreen(w, Fullscreen::FSMODE_FULLSCREEN))
      return tabs || showsAlone(w) ? eMode::TitleBar : eMode::Hidden;
    return tabs && !Fullscreen::controller()->isFullscreen(w) ? eMode::OwnBar : eMode::Hidden;
  }

  bool visible() const { return mode() != eMode::Hidden; }

  // Its tab is being dragged along it (the tab is the current one).
  bool reordering() const {
    const auto w = m_window.lock();
    return w && g_drag && g_drag->state == STabDrag::eState::Reorder && g_drag->window.lock() == w;
  }

  // A carried tab is over it: it makes room for one more tab.
  bool dropTarget() const {
    const auto w = m_window.lock();
    return w && g_drag && g_drag->state == STabDrag::eState::Carry && g_drag->over.lock() == w;
  }

  SDecorationPositioningInfo getPositioningInfo() override {
    SDecorationPositioningInfo info;
    info.policy = DECORATION_POSITION_STICKY;
    info.edges = DECORATION_EDGE_TOP;
    // Above Omarchy's title bar (10005) and the border (10000) means closest
    // to the window: under the title bar, inside the border. Tabs in the
    // title bar take no room of their own.
    info.priority = 10010;
    info.reserved = true;
    info.desiredExtents = {Vector2D{0.0, mode() == eMode::OwnBar ? static_cast<double>(cfg.height->value()) : 0.0}, Vector2D{0.0, 0.0}};
    return info;
  }

  void onPositioningReply(const SDecorationPositioningReply &reply) override { m_assignedBox = reply.assignedGeometry; }
  eDecorationType getDecorationType() override { return DECORATION_CUSTOM; }
  void updateWindow(PHLWINDOW) override { damageEntire(); }
  eDecorationLayer getDecorationLayer() override { return DECORATION_LAYER_OVER; }
  uint64_t getDecorationFlags() override { return DECORATION_ALLOWS_MOUSE_INPUT; }
  std::string getDisplayName() override { return "WindowsLikeTabs"; }

  // The bar the tabs sit in, in global coordinates: the title bar, or the
  // tab bar's own room.
  CBox boxGlobal() const {
    const auto w = m_window.lock();
    if (!w)
      return {};
    CBox box;
    if (const auto title = mode() == eMode::TitleBar ? titleBarOf(w) : nullptr)
      box = g_pDecorationPositioner->getWindowDecorationBox(title);
    else {
      box = m_assignedBox;
      box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(DECORATION_EDGE_TOP, w));
    }
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
    if (m_tipBox.w > 0) {
      auto tip = m_tipBox;
      g_pHyprRenderer->damageBox(tip.translate(w->m_floatingOffset).expand(2));
    }
  }

  struct SLayout {
    CBox bar;   // the whole bar
    CBox strip; // the part of it the tabs own: all of it but the title bar's buttons
    CBox logo, area, plus;
    bool inTitleBar = false;
    double tabW = 0, maxScroll = 0, scroll = 0;
    size_t n = 0, current = 0;
  };

  SLayout layout() const {
    SLayout l;
    const auto w = m_window.lock();
    const auto MODE = mode();
    if (!w || MODE == eMode::Hidden)
      return l;
    l.inTitleBar = MODE == eMode::TitleBar;
    l.bar = boxGlobal();
    l.n = (w->m_group ? w->m_group->size() : 1) + (dropTarget() ? 1 : 0);
    l.current = w->m_group ? w->m_group->getCurrentIdx() : 0;
    const double h = l.bar.h;
    const double right = l.inTitleBar ? l.bar.x + l.bar.w - cfg.buttonsWidth->value() - DRAG_ROOM : l.bar.x + l.bar.w;
    l.strip = {l.bar.x, l.bar.y, std::max(0.0, right - l.bar.x), h};
    // The logo in a square cell, its middle where the title's start was.
    l.logo = {l.bar.x + 4, l.bar.y, std::min(h, l.strip.w), h};
    const double plusW = h;
    const double areaX = l.logo.x + l.logo.w + 2;
    const double avail = std::max(0.0, l.strip.x + l.strip.w - areaX - plusW);
    const double minW = cfg.minWidth->value(), maxW = std::max<double>(minW, cfg.maxWidth->value());
    l.tabW = std::clamp(l.n ? avail / l.n : avail, minW, maxW);
    l.tabW = std::min(l.tabW, std::max(avail, 1.0));
    l.area = {areaX, l.bar.y, std::min(avail, l.tabW * l.n), h};
    l.plus = {l.area.x + l.area.w, l.bar.y, plusW, h};
    l.maxScroll = std::max(0.0, l.tabW * l.n - l.area.w);

    auto &gs = g_groups[groupKey(w)];
    // Bring the current tab into view when it changes, or the tabs do.
    if (gs.lastCurrent != l.current || gs.lastN != l.n || gs.lastTabW != l.tabW || gs.lastAreaW != l.area.w) {
      gs.lastCurrent = l.current;
      gs.lastN = l.n;
      gs.lastTabW = l.tabW;
      gs.lastAreaW = l.area.w;
      const double left = l.current * l.tabW, rightEdge = left + l.tabW;
      if (left < gs.scroll)
        gs.scroll = left;
      else if (rightEdge > gs.scroll + l.area.w)
        gs.scroll = rightEdge - l.area.w;
    }
    gs.scroll = std::clamp(gs.scroll, 0.0, l.maxScroll);
    l.scroll = gs.scroll;
    return l;
  }

  // Where the tooltip goes for text of a width: under the logo.
  CBox tipBox(const SLayout &l, double textW, double textH) const {
    return CBox{l.logo.x, l.bar.y + l.bar.h + 4, textW + 16, textH + 8}.round();
  }

  static CBox tabBox(const SLayout &l, size_t i) { return {l.area.x + i * l.tabW - l.scroll, l.bar.y, l.tabW, l.bar.h}; }

  static CBox closeBoxAt(const SLayout &l, const CBox &t) {
    const double s = std::round(std::min(l.bar.h, 30.0) * 0.6);
    return {t.x + 6, t.y + (t.h - s) / 2, s, s};
  }

  static CBox closeBox(const SLayout &l, size_t i) { return closeBoxAt(l, tabBox(l, i)); }

  bool closeShown(const SLayout &l, size_t i) const {
    return i == l.current || (l.area.containsPoint(g_pointer) && tabBox(l, i).containsPoint(g_pointer));
  }

  SHit hit(const Vector2D &pos) const { return hit(layout(), pos); }

  SHit hit(const SLayout &l, const Vector2D &pos) const {
    if (l.n == 0 || !l.strip.containsPoint(pos))
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
    const auto MODE = mode();
    const bool own = MODE == eMode::OwnBar;
    if (!m_lastOwn.has_value() || *m_lastOwn != own) {
      m_lastOwn = own;
      g_pDecorationPositioner->repositionDeco(this);
    }
    const auto w = m_window.lock();
    if (w) {
      // A bar of its own showing or going: keep the window's frame where it
      // is, and give the bar's room from (or back to) the content, like a Mac.
      auto &gs = g_groups[groupKey(w)];
      if (gs.ownBar.value_or(false) != own) {
        gs.ownBar = own;
        keepFrame(w, own);
      }
    }
    if (MODE == eMode::Hidden || !w)
      return;
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
    const CBox stripClip = toMon(l.strip);

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
    // A texture centered on a point, at its own size or at `size`.
    auto tex = [&](const SP<ITexture> &t, const Vector2D &centerGlobal, const CBox &clipBox, std::optional<Vector2D> size = std::nullopt) {
      if (!t)
        return;
      CTexPassElement::SRenderData d;
      d.tex = t;
      const Vector2D c = (centerGlobal + off) * scale;
      const Vector2D sz = size.value_or(t->m_size);
      d.box = CBox{std::round(c.x - sz.x / 2.0), std::round(c.y - sz.y / 2.0), sz.x, sz.y};
      d.a = a;
      d.clipBox = clipBox;
      g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(std::move(d)));
    };

    const CHyprColor BAR(cfg.bar->value()), TITLEBAR(cfg.titlebar->value()), ACTIVE(cfg.active->value()), HOVER(cfg.hover->value()),
        TEXT(cfg.text->value()), TEXTIN(cfg.textInactive->value()), SEP(cfg.separator->value()), BUTTON(cfg.button->value());
    const int fontPx = std::round(cfg.fontSize->value() * scale);
    const auto pointerHit = hit(l, g_pointer);

    if (l.inTitleBar) {
      // Over the title bar's own title, up to its buttons.
      const double coverRight = l.bar.x + std::max(0.0, l.bar.w - cfg.buttonsWidth->value());
      rect({l.bar.x, l.bar.y, coverRight - l.bar.x, l.bar.h}, TITLEBAR, {});
    } else
      rect(l.bar, BAR, {});

    // The app's logo, or its initial when it has none.
    const double logoSize = std::round(std::min(18.0, l.bar.h - 8));
    const Vector2D logoCenter{l.logo.x + l.logo.w / 2, l.logo.y + l.logo.h / 2};
    const int logoPx = std::max(1, static_cast<int>(std::round(logoSize * scale)));
    if (const auto logo = logoTexture(w, logoPx))
      tex(logo, logoCenter, stripClip, Vector2D{static_cast<double>(logoPx), static_cast<double>(logoPx)});
    else if (!w->m_class.empty())
      tex(textTexture(std::string(1, std::toupper(static_cast<unsigned char>(w->m_class[0]))), TEXT, std::round(fontPx * 1.2), 0), logoCenter, stripClip);

    auto drawTab = [&](PHLWINDOW tw, const CBox &t, bool isCurrent, bool hovered, bool showClose, bool closeHovered, bool separator) {
      if (t.x + t.w < l.area.x || t.x > l.area.x + l.area.w)
        return;
      if (isCurrent)
        rect(t, ACTIVE, clip);
      else if (hovered)
        rect(t, HOVER, clip);

      // A line between two inactive tabs.
      if (separator)
        rect({t.x + t.w - 1, t.y + t.h * 0.25, 1, t.h * 0.5}, SEP, clip);

      // Title, centered in the space right of the close button.
      const auto cb = closeBoxAt(l, t);
      const double closeW = cb.w + 12;
      const int maxW = std::max(1, static_cast<int>((t.w - 2 * closeW) * scale));
      tex(textTexture(labelFor(tw), isCurrent ? TEXT : TEXTIN, fontPx, maxW), {t.x + t.w / 2, t.y + t.h / 2}, clip);

      if (showClose) {
        if (closeHovered)
          rect(cb, BUTTON, clip, std::round(3 * scale));
        tex(textTexture("×", isCurrent ? TEXT : TEXTIN, std::round(fontPx * 1.3), 0), {cb.x + cb.w / 2, cb.y + cb.h / 2}, clip);
      }
    };

    // While a tab is dragged along this bar, or a carried one is over it, the
    // others slide to their new places; otherwise every tab stands in its slot.
    const auto windows = tabsOf(w);
    const bool reorder = reordering(), drop = dropTarget();
    const bool interactive = !reorder && !drop;
    const auto dragged = g_drag ? g_drag->window.lock() : nullptr;
    const size_t dropSlot = drop ? std::min(g_drag->slot, l.n - 1) : SIZE_MAX;
    const size_t draggedIdx = reorder ? l.current : SIZE_MAX;
    const auto now = std::chrono::steady_clock::now();
    const double dt = std::clamp(std::chrono::duration<double>(now - m_lastFrame).count(), 0.0, 0.1);
    m_lastFrame = now;
    if (interactive)
      m_shown.clear();
    bool sliding = false;
    auto slotBox = [&](const void *key, size_t slot) {
      CBox t = tabBox(l, slot);
      if (interactive)
        return t;
      // Positions along the strip as if unscrolled, eased towards the slot.
      const double want = t.x + l.scroll;
      auto [it, fresh] = m_shown.try_emplace(key, want);
      double &x = it->second;
      if (!fresh) {
        x += (want - x) * (1 - std::exp(-dt / 0.04));
        if (std::abs(want - x) < 0.5)
          x = want;
        else
          sliding = true;
      }
      t.x = x - l.scroll;
      return t;
    };

    // The tabs in order; a carried tab's stand-in at the slot it would drop
    // into (as the current tab, which it would be), and nothing where the
    // dragged tab was: it is drawn over the others, under the pointer.
    const size_t currentSlot = drop ? dropSlot : l.current;
    for (size_t s = 0; s < l.n; ++s) {
      const size_t i = dropSlot != SIZE_MAX && s > dropSlot ? s - 1 : s;
      const auto tw = s == dropSlot ? dragged : i < windows.size() && i != draggedIdx ? windows[i] : nullptr;
      if (!tw)
        continue;
      const bool isCurrent = s == currentSlot;
      const bool hovered = interactive && pointerHit.kind != eHit::None && pointerHit.kind != eHit::Plus && pointerHit.index == i;
      const bool showClose = isCurrent || (interactive && closeShown(l, i));
      const bool closeHovered = interactive && pointerHit.kind == eHit::Close && pointerHit.index == i;
      const bool separator = !isCurrent && s + 1 < l.n && s + 1 != currentSlot;
      drawTab(tw, slotBox(tw.get(), s), isCurrent, hovered, showClose, closeHovered, separator);
    }
    if (reorder && draggedIdx < windows.size()) {
      CBox t = tabBox(l, draggedIdx);
      t.x = std::clamp(g_pointer.x - g_drag->grabX, l.area.x, std::max(l.area.x, l.area.x + l.area.w - l.tabW));
      drawTab(windows[draggedIdx], t, true, false, true, false, false);
    }
    if (sliding)
      g_pEventLoopManager->doLater([self = m_self] {
        if (self)
          self->damageEntire();
      });

    if (pointerHit.kind == eHit::Plus) {
      const CBox pb{l.plus.x + 4, l.plus.y + 4, l.plus.w - 8, l.plus.h - 8};
      rect(pb, BUTTON, stripClip, std::round(4 * scale));
    }
    tex(textTexture("+", TEXT, std::round(fontPx * 1.4), 0), {l.plus.x + l.plus.w / 2, l.plus.y + l.plus.h / 2}, stripClip);

    if (g_tipShown && g_tipBar.get() == this) {
      const auto name = textTexture(appFor(w->m_class).name, TEXT, fontPx, 0);
      if (name) {
        m_tipBox = tipBox(l, name->m_size.x / scale, name->m_size.y / scale);
        rect(m_tipBox, SEP, {}, std::round(5 * scale));
        rect(m_tipBox.copy().expand(-1), TITLEBAR, {}, std::round(4 * scale));
        tex(name, m_tipBox.middle(), {});
      }
    }
  }

  CBox m_tipBox; // where the tooltip was last drawn, to clear it
  // While tabs slide aside for a dragged one: where each is drawn, by window.
  std::unordered_map<const void *, double> m_shown;
  std::chrono::steady_clock::time_point m_lastFrame;

  // Presses and releases come through the button hook (see tabButton below),
  // before the title bar sees them; scrolling through the axis event.
  bool onInputOnDeco(const eInputType type, const Vector2D &pos, std::any) override {
    return type == INPUT_TYPE_BUTTON && mode() == eMode::OwnBar && boxGlobal().containsPoint(pos);
  }

  static std::string labelFor(PHLWINDOW w) {
    auto it = g_labels.find(w.get());
    if (it == g_labels.end() || it->second.text.empty())
      g_labels[w.get()].text = computeLabel(w);
    return g_labels[w.get()].text;
  }

  bool scroll(const IPointer::SAxisEvent &e) {
    const auto w = m_window.lock();
    if (!w)
      return false;
    const auto l = layout();
    if (!l.area.containsPoint(g_pointer) && !l.plus.containsPoint(g_pointer))
      return false;
    auto &gs = g_groups[groupKey(w)];
    // Wheel notches are coarse; touchpads send small, smooth steps.
    const double step = e.deltaDiscrete != 0 ? e.delta * 4 : e.delta * 1.5;
    gs.scroll = std::clamp(gs.scroll + step, 0.0, l.maxScroll);
    damageEntire();
    return true;
  }

private:
  PHLWINDOWREF m_window;
  CBox m_assignedBox;
  std::optional<bool> m_lastOwn;

public:
  // Makes the tab at index current, and focuses and raises it (a window with
  // one tab and no group: just focuses and raises it).
  static void select(PHLWINDOW anyMember, size_t index) {
    if (!anyMember)
      return;
    const auto target = anyMember->m_group ? anyMember->m_group->fromIndex(index) : anyMember;
    if (!target)
      return;
    if (anyMember->m_group)
      anyMember->m_group->setCurrent(target);
    Desktop::focusState()->rawWindowFocus(target, Desktop::FOCUS_REASON_CLICK);
    if (target->m_isFloating)
      Desktop::windowState()->raise(target);
  }

  static bool newTab(PHLWINDOW w);
  static void keepFrame(PHLWINDOW w, bool barShown);
};

// The tab bar under the pointer, if nothing is above it there: no other
// window (but `ignore`, a window being carried), popup, panel or menu.
WP<CTabBar> barAt(const Vector2D &pos, PHLWINDOW ignore = nullptr) {
  const auto w = Desktop::viewState()->hitTest().windowAt(
      pos, Desktop::View::ALLOW_FLOATING | Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS, ignore);
  if (!w || !validMapped(w) || w->hasPopupAt(pos))
    return {};
  if (g_pSeatManager->m_seatGrab && !g_pSeatManager->m_seatGrab->accepts(w->resource()))
    return {};
  if (const auto mon = w->m_monitor.lock()) {
    for (const auto layer : {ZWLR_LAYER_SHELL_V1_LAYER_TOP, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY}) {
      Vector2D coords;
      PHLLS found;
      Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[layer], &coords, &found);
      if (found)
        return {};
    }
  }
  for (const auto &b : g_bars)
    if (b && b->owner() == w && b->visible())
      return b;
  return {};
}

// A press the tab bar took, so its release is the tab bar's too.
struct SPress {
  WP<CTabBar> bar;
  SHit hit;
  uint32_t button = 0;
};
std::optional<SPress> g_press;

WP<CTabBar> barOf(PHLWINDOW w) {
  for (const auto &b : g_bars)
    if (w && b && b->owner() == w)
      return b;
  return {};
}

void finishDrag();
void doubleClick(PHLWINDOW w);

// Every pointer button, before Hyprland (or the title bar) sees it. Returns
// true when the tab bar takes it.
bool tabButton(const IPointer::SButtonEvent &e) {
  const auto pos = g_pInputManager->getMouseCoordsInternal();
  // A click puts the tooltip away until the pointer comes back to the logo.
  if (g_tipBar && e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
    if (g_tipShown)
      g_tipBar->damageEntire();
    g_tipShown = false;
    if (g_tipTimer)
      g_tipTimer->updateTimeout(std::nullopt);
  }
  if (e.state != WL_POINTER_BUTTON_STATE_PRESSED) {
    const bool dragged = e.button == BTN_LEFT && g_drag;
    if (dragged)
      finishDrag();
    if (!g_press || g_press->button != e.button)
      return dragged;
    const auto press = *g_press;
    g_press.reset();
    const auto bar = barAt(pos);
    const auto w = bar ? bar->owner() : nullptr;
    if (!w || bar != press.bar)
      return true;
    // Closing waits for the release over the same tab, like a button.
    const auto h = bar->hit(pos);
    if (h.kind != press.hit.kind || h.index != press.hit.index)
      return true;
    const bool close = (e.button == BTN_LEFT && h.kind == eHit::Close) || (e.button == BTN_MIDDLE && (h.kind == eHit::Tab || h.kind == eHit::Close));
    if (close) {
      const auto tabs = tabsOf(w);
      if (h.index < tabs.size())
        g_pXWaylandManager->sendCloseWindow(tabs[h.index]);
    }
    return true;
  }

  // Other buttons while a tab is dragged are the drag's.
  if (g_drag && g_drag->state != STabDrag::eState::Pending)
    return true;
  const auto bar = barAt(pos);
  if (!bar)
    return false;
  const auto w = bar->owner();
  const auto l = bar->layout();
  const auto h = bar->hit(l, pos);
  if (h.kind == eHit::None)
    return false; // the logo and the empty title bar move the window, as ever
  if (h.kind == eHit::Tab && e.button == BTN_LEFT) {
    const auto tabs = tabsOf(w);
    const auto tab = h.index < tabs.size() ? tabs[h.index] : nullptr;
    CTabBar::select(w, h.index);
    if (g_drag)
      finishDrag();
    // The title bar never sees this press, so a double click on a tab does
    // here what one on the title bar does (Omarchy: maximize).
    const auto now = std::chrono::steady_clock::now();
    if (l.inTitleBar && tab && g_lastTabPress && g_lastTabPress->window.lock() == tab && now - g_lastTabPress->at < DOUBLE_CLICK) {
      g_lastTabPress.reset();
      doubleClick(tab);
    } else if (tab) {
      g_lastTabPress = SLastPress{tab, now};
      STabDrag d;
      d.window = tab;
      d.start = pos;
      d.grabX = pos.x - CTabBar::tabBox(l, h.index).x;
      d.grabY = pos.y - l.bar.y;
      d.tabX = l.area.x - l.bar.x;
      g_drag = d;
    }
  }
  if (h.kind == eHit::Plus && e.button == BTN_LEFT)
    CTabBar::newTab(w->m_group ? w->m_group->current() : w);
  g_press = SPress{bar, h, e.button};
  return true;
}

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

// ---------- Dragging tabs ----------
//
// The press on a tab stays with the tab bar (see tabButton), so the drag is
// run from here: the pointer's moves come through Tabs::onMouseMove, and the
// release ends it. A carried window is moved by Hyprland's own drag (as the
// title bar's is), so main.cpp reports it to the shell, which snaps it.

void damageBarOf(PHLWINDOW w) {
  if (const auto b = barOf(w))
    b->damageEntire();
}

// Hides (or shows again) a carried window while its tab shows in another
// window's tabs, like the tab it would become.
void hideCarried(STabDrag &d, PHLWINDOW w, bool hide) {
  if (d.hidden == hide)
    return;
  d.hidden = hide;
  w->alpha(Desktop::View::WINDOW_ALPHA_LAYOUT)->setValueAndWarp(hide ? 0.F : 1.F);
  w->updateWindowDecos();
}

// Puts a floating window under the pointer, holding its first tab where the
// dragged tab was held.
void placeUnder(const STabDrag &d, PHLWINDOW w, const Vector2D &size, const Vector2D &pos) {
  const auto target = w->layoutTarget();
  if (!target || !target->floating() || !target->space())
    return;
  const double top = w->getFullWindowReservedArea().topLeft.y;
  g_layoutManager->setTargetGeom(CBox{pos.x - d.tabX - d.grabX, pos.y - d.grabY + top, size.x, size.y}.round(), target);
  target->warpPositionSize();
}

// Hyprland's move drag, as the title bar starts one. A tiled window is
// floated while it moves, and tiled again where it is dropped.
void startCarry(STabDrag &d, PHLWINDOW w) {
  d.state = STabDrag::eState::Carry;
  g_layoutManager->beginDragTarget(w->layoutTarget(), MBIND_MOVE);
}

// A window with one tab: carried as it is (a maximized one is restored
// first, under the pointer, as the title bar does).
void carry(STabDrag &d, PHLWINDOW w, const Vector2D &pos) {
  const auto target = w->layoutTarget();
  if (Fullscreen::controller()->isFullscreen(w, Fullscreen::FSMODE_MAXIMIZED)) {
    Fullscreen::controller()->setFullscreenMode(w, Fullscreen::FSMODE_NONE);
    placeUnder(d, w, target->position().size(), pos);
  } else if (target->floating() && target->space()) {
    // Where it would be had it followed the pointer from the press.
    CBox box = target->position();
    box.translate(pos - d.start);
    g_layoutManager->setTargetGeom(box, target);
    target->warpPositionSize();
  }
  startCarry(d, w);
}

// A tab out of its strip: a window of its own, as big as the tabbed window
// (restored, if that is maximized; the other tabs stay maximized), carried
// under the pointer.
void tearOff(STabDrag &d, PHLWINDOW w, const Vector2D &pos) {
  const auto group = w->m_group;
  const auto fs = Fullscreen::controller()->getFullscreenModes(w).internal;
  if (fs != Fullscreen::FSMODE_NONE)
    Fullscreen::controller()->setFullscreenMode(w, Fullscreen::FSMODE_NONE);
  const auto size = w->layoutTarget()->position().size();
  quietGroupOf(w, true);
  group->remove(w);
  if (fs != Fullscreen::FSMODE_NONE && group->current())
    Fullscreen::controller()->setFullscreenMode(group->current(), fs);
  damageBarOf(group->current());
  placeUnder(d, w, size, pos);
  startCarry(d, w);
}

// While carried: the tab strip under the pointer (another window's, one the
// window may join) and the slot there it would drop into.
void carryOver(STabDrag &d, PHLWINDOW w, const Vector2D &pos) {
  const auto oldOver = d.over.lock();
  const size_t oldSlot = d.slot;
  PHLWINDOW over;
  if (const auto bar = barAt(pos, w)) {
    const auto o = bar->owner();
    if (o && o != w && !(o->m_group && o->m_group->has(w)) && (!o->m_group || w->canBeGroupedInto(o->m_group))) {
      // Laid out as it is drawn: with room for the tab.
      d.over = o;
      const auto l = bar->layout();
      if (l.n > 0 && l.strip.containsPoint(pos)) {
        over = o;
        d.slot = std::min(l.n - 1, static_cast<size_t>(std::max(0.0, (pos.x - l.area.x + l.scroll) / l.tabW)));
      }
    }
  }
  d.over = over;
  if (over != oldOver || (over && d.slot != oldSlot)) {
    damageBarOf(oldOver);
    damageBarOf(over);
  }
  hideCarried(d, w, over != nullptr);
}

// Every move of the pointer while a tab is held.
void dragMotion(const Vector2D &pos) {
  if (!g_drag)
    return;
  auto &d = *g_drag;
  const auto w = d.window.lock();
  if (!validMapped(w)) {
    g_drag.reset();
    return;
  }

  if (d.state == STabDrag::eState::Pending) {
    if (pos.distance(d.start) < DRAG_THRESHOLD)
      return;
    g_lastTabPress.reset();
    if (!w->m_group || w->m_group->size() < 2) {
      carry(d, w, pos);
      return;
    }
    d.state = STabDrag::eState::Reorder;
  }

  if (d.state == STabDrag::eState::Carry) {
    carryOver(d, w, pos);
    return;
  }

  // Along the strip: the tab takes the slot nearest where it is drawn.
  const auto bar = barOf(w);
  if (!bar || !bar->visible() || !w->m_group || w->m_group->current() != w) {
    g_drag.reset();
    return;
  }
  const auto l = bar->layout();
  if (!l.bar.copy().expand(TEAR_DISTANCE).containsPoint(pos)) {
    tearOff(d, w, pos);
    return;
  }
  const double x = std::clamp(pos.x - d.grabX, l.area.x, std::max(l.area.x, l.area.x + l.area.w - l.tabW));
  const size_t want = std::min(l.n - 1, static_cast<size_t>(std::max(0.0, std::round((x - l.area.x + l.scroll) / l.tabW))));
  const auto group = w->m_group;
  while (group->getCurrentIdx() < want)
    group->swapWithNext();
  while (group->getCurrentIdx() > want)
    group->swapWithLast();
  bar->damageEntire();
}

// A carried window dropped on another window's tabs: one of them, at slot.
bool joinTabs(PHLWINDOW w, PHLWINDOW over, size_t slot) {
  if (over->m_group && !w->canBeGroupedInto(over->m_group))
    return false;
  quiet(w, false);
  quietGroupOf(over, false);
  if (!over->m_group)
    (void)Config::Actions::toggleGroup(over);
  if (!over->m_group)
    return false;
  const auto group = over->m_group;
  group->add(w, slot);
  const auto &members = group->windows();
  const auto it = std::ranges::find(members, PHLWINDOWREF{w});
  CTabBar::select(w, it == members.end() ? group->getCurrentIdx() : static_cast<size_t>(it - members.begin()));
  quietGroupOf(w, false);
  return true;
}

// As the title bar does after a drag: a window dropped with its title bar
// under a top bar or off the screen couldn't be dragged back.
void keepReachable(PHLWINDOW w) {
  const auto target = w->layoutTarget();
  const auto mon = w->m_monitor.lock();
  if (!w->m_isFloating || !target || !target->space() || !mon)
    return;
  const auto work = mon->logicalBoxMinusReserved();
  const double top = w->getFullWindowReservedArea().topLeft.y;
  CBox box = target->position();
  const double y = std::clamp(box.y - top, work.y, std::max(work.y, work.y + work.h - top));
  if (std::abs(y - (box.y - top)) < 0.5)
    return;
  box.y = y + top;
  g_layoutManager->setTargetGeom(box, target);
}

// The left button let go: a carried window is dropped (on another window's
// tabs, or wherever it is).
void finishDrag() {
  if (!g_drag)
    return;
  auto d = *g_drag;
  g_drag.reset();
  const auto w = d.window.lock();
  damageBarOf(w);
  if (d.state != STabDrag::eState::Carry || !validMapped(w))
    return;
  const auto over = d.over.lock();
  damageBarOf(over);
  const auto &controller = g_layoutManager->dragController();
  if (controller && controller->mode() != MBIND_INVALID && controller->target() == w->layoutTarget())
    g_layoutManager->endDragTarget();
  if (!validMapped(over) || !joinTabs(w, over, d.slot)) {
    hideCarried(d, w, false);
    keepReachable(w);
  }
  reportDragSoon();
}

// A double click on a tab: plugin:hyprbars:on_double_click, for the window.
void doubleClick(PHLWINDOW w) {
  const auto value = Config::mgr()->getConfigValue("plugin:hyprbars:on_double_click");
  if (!value.dataptr || !value.type || *value.type != typeid(Config::STRING))
    return;
  auto cmd = *static_cast<const Config::STRING *>(*value.dataptr);
  if (cmd.empty() || cmd == "[[EMPTY]]")
    return;
  const auto address = std::format("0x{:x}", reinterpret_cast<uintptr_t>(w.get()));
  for (size_t at = 0; (at = cmd.find("%WINDOW%", at)) != std::string::npos; at += address.size())
    cmd.replace(at, 8, address);
  (void)Config::Supplementary::executor()->spawn(cmd);
}

// ---------- New tabs ----------

struct SPending {
  PHLWINDOWREF anchor;
  std::string cls;
  pid_t pid = -1;
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
  // A new terminal tab is a plain terminal (default app id) in the current
  // tab's folder, even from a terminal opened under an app id of its own.
  std::string cls = w->m_class;
  if (isTerminal(w)) {
    const auto cwd = terminalCwd(w);
    if (!cwd.empty()) {
      if (base == "foot" || base == "footclient" || base == "alacritty" || base == "ghostty")
        cmd += " --working-directory=" + shellQuote(cwd);
      else if (base == "kitty")
        cmd += " --directory=" + shellQuote(cwd);
    }
    if (base == "foot" || base == "footclient")
      cls = base;
  }
  const auto spawned = Config::Supplementary::executor()->spawn(cmd);
  g_pending = SPending{w, cls, spawned ? static_cast<pid_t>(*spawned) : -1, std::chrono::steady_clock::now() + std::chrono::seconds(10)};
  return true;
}

void adoptIfPending(PHLWINDOW w) {
  if (!g_pending || !w)
    return;
  if (std::chrono::steady_clock::now() > g_pending->until) {
    g_pending.reset();
    return;
  }
  if (w == g_pending->anchor.lock())
    return;
  // The window of the process we started (or a child of it), or failing that,
  // one of the app's class: apps that open their windows from an already
  // running process (a file manager, a browser) only match by class.
  bool ours = false;
  for (pid_t p = w->getPID(), i = 0; p > 1 && i < 4 && g_pending->pid > 0; p = parentOf(p), ++i)
    if (p == g_pending->pid) {
      ours = true;
      break;
    }
  if (!ours && w->m_class != g_pending->cls)
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
  if (!cfg.enabled->value() || !w || !hasTabShortcuts(w))
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
    for (const auto &m : tabsOf(w)) {
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
    if (w->m_group && w->m_group->current() != w)
      continue;
    const auto l = b->layout();
    std::string tabs;
    const auto windows = tabsOf(w);
    for (size_t i = 0; i < windows.size(); ++i) {
      const auto &m = windows[i];
      tabs += std::format("{}{{\"address\":\"0x{:x}\",\"label\":\"{}\",\"box\":{},\"close\":{}}}", tabs.empty() ? "" : ",",
                          reinterpret_cast<uintptr_t>(m.get()), jsonEscape(CTabBar::labelFor(m)), boxJson(CTabBar::tabBox(l, i)),
                          boxJson(CTabBar::closeBox(l, i)));
    }
    // While a tab is dragged: the one dragged along this bar, and the slot
    // a carried tab would drop into here (-1 for neither).
    const long dragging = b->reordering() ? static_cast<long>(l.current) : -1;
    const long drop = b->dropTarget() ? static_cast<long>(g_drag->slot) : -1;
    out += std::format("{}{{\"window\":\"0x{:x}\",\"current\":{},\"dragging\":{},\"drop\":{},\"titleBar\":{},\"bar\":{},\"strip\":{},\"logo\":{},\"logoLoaded\":{},\"tip\":\"{}\",\"area\":{},"
                       "\"plus\":{},\"scroll\":{},\"maxScroll\":{},\"tabs\":[{}]}}",
                       first ? "" : ",", reinterpret_cast<uintptr_t>(w.get()), l.current, dragging, drop, l.inTitleBar, boxJson(l.bar), boxJson(l.strip), boxJson(l.logo),
                       !appFor(w->m_class).iconPath.empty(), g_tipShown && g_tipBar.get() == b.get() ? jsonEscape(appFor(w->m_class).name) : "",
                       boxJson(l.area), boxJson(l.plus), std::lround(l.scroll), std::lround(l.maxScroll), tabs);
    first = false;
  }
  return out + "]";
}

CHyprSignalListener g_openListener, g_closeListener, g_unmapListener, g_axisListener;

// Pointer buttons reach Hyprland's event listeners, Omarchy's title bar
// among them, all at once: the title bar would take a click on a tab's close
// button or on "+" as a click on itself (a double click maximizing the
// window). So the tab bar looks at each button first, from a hook on
// CInputManager::onMouseButton, and keeps the presses it acts on.
CFunctionHook *g_buttonHook = nullptr;
using FOnMouseButton = void (*)(void *, IPointer::SButtonEvent, SP<IPointer>);
void hkOnMouseButton(void *self, IPointer::SButtonEvent e, SP<IPointer> mouse) {
  if (tabButton(e))
    return;
  reinterpret_cast<FOnMouseButton>(g_buttonHook->m_original)(self, e, mouse);
}

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

// For main.cpp's side resizing.
bool sideResizeEnabled() { return !cfg.sideResize || cfg.sideResize->value(); }
bool jointResizeEnabled() { return !cfg.jointResize || cfg.jointResize->value(); }

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
    if (const auto p = w.lock()) {
      g_labels.erase(p.get());
      g_alone.erase(p.get());
      g_groups.erase(p.get());
    }
  });
  // The wheel or touchpad over the tabs scrolls them.
  g_axisListener = Event::bus()->m_events.input.mouse.axis.listen([](IPointer::SAxisEvent e, Event::SCallbackInfo &info) {
    if (const auto bar = barAt(g_pInputManager->getMouseCoordsInternal()); bar && bar->scroll(e))
      info.cancelled = true;
  });
  for (const auto &match : HyprlandAPI::findFunctionsByName(handle, "onMouseButton"))
    if (match.demangled.find("CInputManager::onMouseButton") != std::string::npos) {
      g_buttonHook = HyprlandAPI::createFunctionHook(handle, match.address, reinterpret_cast<void *>(&hkOnMouseButton));
      if (g_buttonHook && !g_buttonHook->hook())
        g_buttonHook = nullptr;
      break;
    }
  if (!g_buttonHook)
    HyprlandAPI::addNotification(handle, "[windows-like] tabs: couldn't watch the mouse buttons; tab clicks may not work", CHyprColor{1.0, 0.6, 0.2, 1.0},
                                 8000);

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
  g_tipTimer = makeShared<CEventLoopTimer>(
      std::nullopt,
      [](SP<CEventLoopTimer>, void *) {
        if (g_tipBar && g_tipBar->visible() && g_tipBar->layout().logo.containsPoint(g_pointer)) {
          g_tipShown = true;
          g_tipBar->damageEntire();
          // Damage again once drawn, now that the tooltip's box is known.
          g_pEventLoopManager->doLater([] {
            if (g_tipBar)
              g_tipBar->damageEntire();
          });
        }
      },
      nullptr);
  g_pEventLoopManager->addTimer(g_tipTimer);
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
  if (g_tipTimer) {
    g_tipTimer->cancel();
    g_pEventLoopManager->removeTimer(g_tipTimer);
    g_tipTimer.reset();
  }
  g_tipBar.reset();
  g_tipShown = false;
  for (const auto &q : g_quiet)
    if (const auto w = q.window.lock(); w && q.setNoAnim)
      w->m_ruleApplicator->noAnim().unset(Desktop::Types::PRIORITY_SET_PROP);
  g_quiet.clear();
  g_openListener.reset();
  g_unmapListener.reset();
  g_closeListener.reset();
  g_axisListener.reset();
  if (g_buttonHook) {
    HyprlandAPI::removeFunctionHook(g_handle, g_buttonHook);
    g_buttonHook = nullptr;
  }
  g_press.reset();
  if (g_drag) {
    if (const auto w = g_drag->window.lock(); w && g_drag->hidden)
      hideCarried(*g_drag, w, false);
    g_drag.reset();
  }
  g_lastTabPress.reset();
  g_bars.clear();
  g_icons.clear();
  g_apps.clear();
  g_alone.clear();
  g_textures.clear();
  g_labels.clear();
  g_groups.clear();
  g_pending.reset();
}

void onMouseMove(const Vector2D &pos) {
  const auto old = g_pointer;
  g_pointer = pos;
  dragMotion(pos);
  // The tooltip: the bar whose logo the pointer is on, if any.
  WP<CTabBar> onLogo;
  for (const auto &b : g_bars)
    if (b && b->visible() && b->layout().logo.containsPoint(pos)) {
      onLogo = b;
      break;
    }
  if (onLogo != g_tipBar) {
    // (Tab bars belong to their windows as unique pointers: weak ones to
    // them are used as they are, never locked.)
    if (g_tipBar && g_tipShown) {
      g_tipBar->damageEntire();
      g_tipBar->m_tipBox = {};
    }
    g_tipBar = onLogo;
    g_tipShown = false;
    if (g_tipTimer)
      g_tipTimer->updateTimeout(onLogo ? std::optional{std::chrono::duration_cast<std::chrono::steady_clock::duration>(TIP_DELAY)} : std::nullopt);
  }
  for (const auto &b : g_bars) {
    if (!b || !b->visible())
      continue;
    const auto box = b->boxGlobal();
    if (box.containsPoint(pos) || box.containsPoint(old))
      b->damageEntire();
  }
}

} // namespace Tabs
