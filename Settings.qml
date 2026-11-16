import QtQuick
import Quickshell
import Quickshell.Io

// omarchy-windows-like settings: the user's
// ~/.config/omarchy-windows-like/settings.json laid over config/defaults.json,
// reloaded live as either changes (Windows-like Settings writes the first).
//
//   Settings { id: s }   ...   s.get("taskbar.style")
QtObject {
  id: root

  // Where the plugin lives, for config/defaults.json. Plugins get it from
  // their manifest (__sourceDir); the fallback is the usual install path.
  // OMARCHY_WINDOWS_LIKE_ROOT and OMARCHY_WINDOWS_LIKE_SETTINGS_JSON point
  // tests at a checkout and a settings file of their own.
  property string sourceDir: ""
  readonly property string defaultsPath: (Quickshell.env("OMARCHY_WINDOWS_LIKE_ROOT") || (sourceDir !== "" ? sourceDir
      : Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.neilgraham.windows-like")) + "/config/defaults.json"
  readonly property string userPath: Quickshell.env("OMARCHY_WINDOWS_LIKE_SETTINGS_JSON")
      || Quickshell.env("HOME") + "/.config/omarchy-windows-like/settings.json"

  property var defaults: ({})
  property var user: ({})
  // The merged settings; bind to this (or call get()) so changes propagate.
  readonly property var values: merge(defaults, user)

  function merge(base, over) {
    var out = {}
    var key
    for (key in base)
      out[key] = base[key]
    for (key in over) {
      var b = out[key], o = over[key]
      out[key] = b && o && typeof b === "object" && typeof o === "object" && !Array.isArray(b) && !Array.isArray(o) ? merge(b, o) : o
    }
    return out
  }

  // get("snapping.edges", true)
  function get(path, fallback) {
    var v = root.values
    var parts = String(path).split(".")
    for (var i = 0; i < parts.length; i++) {
      if (v === null || v === undefined || typeof v !== "object")
        return fallback
      v = v[parts[i]]
    }
    return v === undefined || v === null ? fallback : v
  }

  // Writes one value into the user's file (creating it), e.g. pinned apps.
  function set(path, value) {
    var next = JSON.parse(JSON.stringify(root.user || {}))
    var parts = String(path).split(".")
    var node = next
    for (var i = 0; i < parts.length - 1; i++) {
      if (!node[parts[i]] || typeof node[parts[i]] !== "object")
        node[parts[i]] = {}
      node = node[parts[i]]
    }
    node[parts[parts.length - 1]] = value
    root.user = next
    userFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function parse(text) {
    try {
      var v = JSON.parse(text)
      return v && typeof v === "object" ? v : {}
    } catch (e) {
      return {}
    }
  }

  property FileView defaultsFile: FileView {
    path: root.defaultsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.defaults = root.parse(text())
    onFileChanged: reload()
  }

  property FileView userFile: FileView {
    path: root.userPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.user = root.parse(text())
    onLoadFailed: root.user = ({})
    onFileChanged: reload()
  }
}
