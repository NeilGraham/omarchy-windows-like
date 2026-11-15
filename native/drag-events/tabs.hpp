#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/helpers/math/Math.hpp>

// Tabs: Hyprland groups drawn as a tab bar under the title bar, with a close
// button on each tab, a "+" for a new tab of the same app, and horizontal
// scrolling when the tabs don't fit. See tabs.cpp.
namespace Tabs {
  void init(HANDLE handle);
  void exit();
  void onMouseMove(const Vector2D &pos);
}
