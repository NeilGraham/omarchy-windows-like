pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TaskbarModel.js" as Model

// The taskbar, as two widgets in Omarchy's bar (bar.layout entries with
// "part": "start" or "apps"; `omarchy-windows-like apply` places them):
//   start - the Omarchy mark; opens the start menu. Tapping Super (or
//           Super + Alt + Space for All apps) opens the one on the focused
//           monitor.
//   apps  - pinned and running apps, one button per app, with Windows 11's
//           running/active lines underneath. Click to launch, bring forward,
//           minimize, or step through an app's windows; right-click for
//           pin, new window and close.
BarWidget {
  id: root
  moduleName: "io.github.neilgraham.windows-like"

  readonly property string part: String(setting("part", "apps"))
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.neilgraham.windows-like"
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null
  readonly property bool classic: cfg.get("taskbar.style", "windows11") === "classic"
  readonly property int slot: Math.round(barSize * 0.9)
  readonly property int iconSize: Math.round(barSize * 0.56)

  Settings {
    id: cfg
  }

  implicitWidth: part === "start" ? slot : appsRow.implicitWidth
  implicitHeight: barSize

  // ---------- Which monitor, which workspace ----------

  readonly property var hyprMonitor: QsWindow.window && QsWindow.window.screen ? Hyprland.monitorFor(QsWindow.window.screen) : null
  readonly property int workspaceId: hyprMonitor && hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
  readonly property bool onFocusedMonitor: !!hyprMonitor && !!Hyprland.focusedMonitor && Hyprland.focusedMonitor.name === hyprMonitor.name

  // ---------- Apps and windows ----------

  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (e.runInTerminal || String(e.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: e.id, execString: e.execString, command: e.command, runInTerminal: e.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry)
      return entry
    var id = Model.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  function iconFor(entry, appId) {
    var name = entry && entry.icon ? entry.icon : String(appId || "")
    if (root.appLibrary)
      return root.appLibrary.iconSource(name)
    return Quickshell.iconPath(name, "application-x-executable")
  }

  readonly property var pinned: (cfg.get("taskbar.pinned", []) || []).filter(function(id) {
    return !!DesktopEntries.byId(id)
  })

  readonly property var items: {
    if (root.part !== "apps")
      return []
    var revision = DesktopEntries.applications.values.length
    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i].wayland
      if (!t || !t.appId || t.parent)
        continue
      var entry = root.entryForAppId(t.appId)
      var ws = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : t.appId,
        appId: t.appId,
        address: toplevels[i].address,
        workspaceId: ws ? ws.id : -1,
        minimized: !!ws && Model.isMinimizedWorkspace(ws.name),
        activated: t.activated,
        title: t.title,
        toplevel: t
      })
    }
    return Model.buildItems(root.pinned, windows, root.workspaceId)
  }

  function run(lua) {
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  function addressOf(window) {
    var a = String(window.address || "")
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  // Like Omarchy's dock: a minimized window comes back to this workspace
  // without animating in, then is focused and raised.
  function bringForward(window) {
    var target = "window = 'address:" + root.addressOf(window) + "'"
    var steps = []
    if (window.minimized && root.workspaceId >= 1)
      steps.push("hl.dispatch(hl.dsp.window.move({ workspace = '" + root.workspaceId + "', " + target + " }))")
    steps.push("hl.dispatch(hl.dsp.focus({ " + target + " }))")
    steps.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = 'top', " + target + " }))")
    root.run(steps.join("; "))
  }

  function launch(id) {
    var entry = DesktopEntries.byId(id)
    if (root.appLibrary && entry)
      root.appLibrary.launch(entry.id, entry.name)
    else
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", String(id)])
  }

  function activate(item) {
    var decision = Model.clickAction(item, root.workspaceId)
    if (decision.action === "launch")
      root.launch(item.key)
    else if (decision.action === "minimize")
      Quickshell.execDetached(["omarchy-hyprland-window-minimize", root.addressOf(item.windows[decision.index])])
    else
      root.bringForward(item.windows[decision.index])
  }

  function closeAll(item) {
    for (var i = 0; i < item.windows.length; i++)
      item.windows[i].toplevel.close()
  }

  function togglePin(listName, id) {
    var list = (cfg.get(listName, []) || []).slice()
    var at = list.indexOf(id)
    if (at >= 0)
      list.splice(at, 1)
    else
      list.push(id)
    cfg.set(listName, list)
  }

  // ---------- Recently used apps (for the start menu) ----------

  // One widget keeps the list: the apps part on the first screen.
  readonly property bool keepsRecents: part === "apps" && QsWindow.window && QsWindow.window.screen === Quickshell.screens[0]
  property var recents: []

  FileView {
    id: recentFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy-windows-like/recent.json"
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        root.recents = JSON.parse(text()) || []
      } catch (e) {
        root.recents = []
      }
    }
    onFileChanged: reload()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event)
        return
      if (event.name === "openwindow" && root.keepsRecents) {
        var fields = String(event.data).split(",")
        var entry = fields.length >= 3 ? root.entryForAppId(fields[2]) : null
        if (entry && !entry.noDisplay) {
          root.recents = Model.pushRecent(root.recents, entry.id, 12)
          recentFile.setText(JSON.stringify(root.recents) + "\n")
        }
      } else if (event.name === "custom" && root.part === "start" && root.onFocusedMonitor) {
        if (event.data === "windows-like-start")
          root.toggleMenu("")
        else if (event.data === "windows-like-start-apps")
          root.toggleMenu("all")
      }
    }
  }

  // ---------- Start ----------

  property bool menuOpen: false
  property string menuView: ""

  function toggleMenu(view) {
    if (root.menuOpen && (view === "" || view === root.menuView)) {
      root.menuOpen = false
      return
    }
    root.menuView = view
    root.menuOpen = true
  }

  // The popup's owner: it closes through here.
  function close() {
    root.menuOpen = false
  }

  Rectangle {
    id: startButton
    visible: root.part === "start"
    anchors.centerIn: parent
    width: root.slot
    height: root.slot
    radius: Math.max(Style.cornerRadius, 4)
    color: startMouse.pressed ? Style.pressedFill : (startMouse.containsMouse || root.menuOpen ? Style.hoverFill : "transparent")

    Image {
      id: mark
      anchors.centerIn: parent
      width: Math.round(root.iconSize * 0.95)
      height: width
      source: root.part === "start" ? "file://" + root.pluginDir + "/assets/omarchy-mark.svg" : ""
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      visible: false
    }

    MultiEffect {
      anchors.fill: mark
      source: mark
      colorization: 1.0
      colorizationColor: startMouse.containsMouse || root.menuOpen ? Commons.Color.accent : (root.bar ? root.bar.foreground : Commons.Color.foreground)
    }

    MouseArea {
      id: startMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleMenu("")
    }
  }

  Loader {
    active: root.part === "start" && (root.menuOpen || item !== null)
    sourceComponent: StartMenu {
      anchorItem: startButton
      bar: root.bar
      owner: root
      open: root.menuOpen
      settings: cfg
      host: root
      view: root.menuView
      recents: root.recents
    }
  }

  // ---------- App buttons ----------

  Row {
    id: appsRow
    visible: root.part === "apps"
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(root.barSize * 0.08)

    Repeater {
      model: root.items

      Rectangle {
        id: button
        required property var modelData
        readonly property var entry: DesktopEntries.byId(modelData.key)
        readonly property string indicator: Model.indicator(modelData)
        readonly property bool labeled: cfg.get("taskbar.showLabels", false)
        readonly property string label: modelData.windows.length > 0 ? String(modelData.windows[0].title || "") : (entry ? entry.name : modelData.key)

        width: labeled ? Math.min(root.slot * 5, root.slot + labelText.implicitWidth + root.slot * 0.4) : root.slot
        height: root.slot
        radius: Math.max(Style.cornerRadius, 4)
        color: buttonMouse.pressed ? Style.pressedFill
             : buttonMouse.containsMouse ? Style.hoverFill
             : indicator === "active" ? Commons.Util.alpha(Commons.Color.foreground, 0.08) : "transparent"

        Image {
          id: icon
          x: button.labeled ? Math.round(root.slot * 0.2) : Math.round((button.width - width) / 2)
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -Math.round(root.barSize * 0.03)
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          source: root.iconFor(button.entry, button.modelData.windows.length ? button.modelData.windows[0].appId : button.modelData.key)
          asynchronous: true
        }

        Text {
          id: labelText
          visible: button.labeled
          textFormat: Text.PlainText
          anchors.left: icon.right
          anchors.leftMargin: Math.round(root.slot * 0.15)
          anchors.right: parent.right
          anchors.rightMargin: Math.round(root.slot * 0.15)
          anchors.verticalCenter: icon.verticalCenter
          text: button.label
          elide: Text.ElideRight
          color: root.bar ? root.bar.foreground : Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // Windows 11: a short line under a running app, a longer accent line
        // under the focused one.
        Rectangle {
          anchors.horizontalCenter: button.labeled ? undefined : parent.horizontalCenter
          x: button.labeled ? Math.round((parent.width - width) / 2) : 0
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 2
          visible: button.indicator !== "none"
          width: button.indicator === "active" ? Math.round(root.slot * 0.4) : Math.round(root.slot * 0.16)
          height: 3
          radius: 1.5
          color: button.indicator === "active" ? Commons.Color.accent : Commons.Util.alpha(root.bar ? root.bar.foreground : Commons.Color.foreground, 0.55)
          Behavior on width {
            NumberAnimation {
              duration: Style.duration(120)
              easing.type: Easing.OutCubic
            }
          }
        }

        MouseArea {
          id: buttonMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton)
              root.openContext(button, button.modelData)
            else if (mouse.button === Qt.MiddleButton)
              root.launch(button.modelData.key)
            else
              root.activate(button.modelData)
          }
          onContainsMouseChanged: {
            if (!root.bar)
              return
            if (containsMouse)
              root.bar.showTooltip(button, button.modelData.windows.length > 1
                  ? (button.entry ? button.entry.name : button.label) + " · " + button.modelData.windows.length + " windows"
                  : button.label)
            else
              root.bar.hideTooltip(button)
          }
        }
      }
    }
  }

  // ---------- Right-click menu on a taskbar button ----------

  property var contextItem: null
  property Item contextAnchor: null
  property bool contextOpen: false

  function openContext(anchor, item) {
    root.contextAnchor = anchor
    root.contextItem = item
    root.contextOpen = true
  }

  QtObject {
    id: contextOwner
    function close() {
      root.contextOpen = false
    }
  }

  Loader {
    active: root.part === "apps" && root.contextAnchor !== null
    sourceComponent: KeyboardPanel {
      id: contextPanel
      anchorItem: root.contextAnchor
      bar: root.bar
      owner: contextOwner
      open: root.contextOpen
      // Both sizes are the card's, padding and border included: the
      // panel's helpers add those to the rows' own height.
      contentWidth: contextPanel.fittedContentWidth(Style.space(240))
      contentHeight: contextPanel.fittedContentHeight(contextColumn.implicitHeight)

      Column {
        id: contextColumn
        width: parent.width
        spacing: Style.spacing.xxs

        Repeater {
          model: {
            var item = root.contextItem
            if (!item)
              return []
            var rows = []
            var entry = DesktopEntries.byId(item.key)
            if (entry) {
              rows.push({ id: "new", text: entry.name })
              rows.push({ id: "pin", text: item.pinned ? "Unpin from taskbar" : "Pin to taskbar" })
            }
            if (item.windows.length > 0)
              rows.push({ id: "close", text: item.windows.length > 1 ? "Close all windows" : "Close window" })
            return rows
          }

          Rectangle {
            required property var modelData
            width: contextColumn.width
            height: Style.spacing.popupRowHeight || 32
            radius: Style.cornerRadius
            color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.spacing.rowPaddingX || 10
              textFormat: Text.PlainText
              text: parent.modelData.text
              color: Commons.Color.popups.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var item = root.contextItem
                var id = parent.modelData.id
                root.contextOpen = false
                if (!item)
                  return
                if (id === "new")
                  root.launch(item.key)
                else if (id === "pin")
                  root.togglePin("taskbar.pinned", item.key)
                else if (id === "close")
                  root.closeAll(item)
              }
            }
          }
        }
      }
    }
  }
}
