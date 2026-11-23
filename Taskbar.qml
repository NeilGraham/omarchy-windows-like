pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TaskbarModel.js" as Model

// The taskbar, as two widgets in Omarchy's bar (bar.layout entries with
// "part": "start" or "apps"; `omarchy-windows-like apply` places them):
//   start - the Omarchy mark; opens the start menu. Tapping Super (or
//           Super + Alt + Space for All apps) opens the one on the focused
//           monitor.
//   desktops - right of Start: the number of the workspace shown, which
//           opens the workspaces to switch to, rename or add one
//           (Workspaces.qml).
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

  implicitWidth: part === "start" || part === "desktops" ? slot : appsRow.implicitWidth
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
    if (!appId)
      return null
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry)
      return entry
    var id = Model.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // ---------- Apps for windows that don't name theirs ----------

  // What each desktop entry runs, for matching processes to it.
  readonly property var entryCommands: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++)
      out.push({ id: values[i].id, name: values[i].name, command: values[i].command || [], workingDirectory: values[i].workingDirectory || "" })
    return out
  }

  // pid -> { exe, cwd, args }, read from /proc once per process.
  property var processInfo: ({})
  property var processWanted: []

  function entryForWindow(appId, pid, title) {
    var entry = appId ? root.entryForAppId(appId) : null
    if (entry || !(pid > 0))
      return entry
    var info = root.processInfo[pid]
    if (info === undefined) {
      Qt.callLater(root.wantProcess, pid)
      return null
    }
    var id = Model.entryForProcess(info, root.entryCommands, title, Quickshell.env("HOME"))
    return id ? DesktopEntries.byId(id) : null
  }

  function wantProcess(pid) {
    if (root.processInfo[pid] !== undefined || root.processWanted.indexOf(pid) >= 0)
      return
    root.processWanted = root.processWanted.concat([pid])
    processTimer.restart()
  }

  Timer {
    id: processTimer
    interval: 50
    onTriggered: {
      if (processReader.running || root.processWanted.length === 0)
        return
      processReader.pids = root.processWanted.map(String)
      root.processWanted = []
      processReader.running = true
    }
  }

  Process {
    id: processReader
    property var pids: []
    // pid, executable and working folder, then the arguments split by \x1f.
    command: ["sh", "-c", "for p in \"$@\"; do printf '%s\\t%s\\t%s\\t' \"$p\" \"$(readlink /proc/$p/exe 2>/dev/null)\" \"$(readlink /proc/$p/cwd 2>/dev/null)\"; tr '\\0' '\\037' < /proc/$p/cmdline 2>/dev/null; echo; done", "sh"].concat(pids)
    stdout: StdioCollector {
      onStreamFinished: {
        var next = Object.assign({}, root.processInfo)
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 4 || !(Number(f[0]) > 0))
            continue
          next[Number(f[0])] = { exe: f[1], cwd: f[2], args: f.slice(3).join("\t").split("\x1f").filter(function(a) { return a !== "" }) }
        }
        // A process that has gone, or can't be read, is not asked about again.
        for (var j = 0; j < processReader.pids.length; j++)
          if (next[Number(processReader.pids[j])] === undefined)
            next[Number(processReader.pids[j])] = {}
        root.processInfo = next
        if (root.processWanted.length > 0)
          processTimer.restart()
      }
    }
  }

  function iconFor(entry, appId) {
    var name = entry && entry.icon ? entry.icon : String(appId || "") || "application-x-executable"
    if (root.appLibrary)
      return root.appLibrary.iconSource(name)
    return Quickshell.iconPath(name, "application-x-executable")
  }

  // Looked up again when the desktop entries change (byId() is no binding
  // dependency), so an app installed after the shell started shows its pin.
  readonly property var pinned: {
    var revision = DesktopEntries.applications.values
    return (cfg.get("taskbar.pinned", []) || []).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })
  }

  readonly property var items: {
    if (root.part !== "apps")
      return []
    var revision = DesktopEntries.applications.values.length
    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i].wayland
      if (!t || t.parent)
        continue
      // A window whose app id names no app (some X11 apps set no class) is
      // matched to its app by the process behind it; failing that it still
      // gets a button, as every window does on Windows: its own, with its
      // title and a generic icon.
      var ws = toplevels[i].workspace
      var ipc = toplevels[i].lastIpcObject || {}
      var entry = root.entryForWindow(t.appId, ipc.pid, t.title)
      windows.push({
        // Its tabs (a Hyprland group), and which was focused last, for
        // showing a tabbed window once.
        group: ipc.grouped || [],
        focusHistoryID: ipc.focusHistoryID,
        pid: Number(ipc.pid) || 0,
        size: ipc.size || null,
        key: entry ? entry.id : (t.appId || "window:" + toplevels[i].address),
        appId: t.appId,
        address: toplevels[i].address,
        workspaceId: ws ? ws.id : -1,
        minimized: !!ws && Model.isMinimizedWorkspace(ws.name),
        activated: t.activated,
        title: t.title,
        toplevel: t
      })
    }
    return Model.buildItems(root.pinned, Model.collapseTabs(windows), root.workspaceId)
  }

  // Hyprland reports a window's tabs and focus order only when asked, so ask
  // again when they change: a tab opened, moved in or out, or picked.
  Connections {
    target: root.part === "apps" ? Hyprland : null
    function onRawEvent(event) {
      var name = event ? event.name : ""
      if (name === "openwindow" || name === "closewindow" || name === "activewindowv2" || name === "moveintogroup"
          || name === "moveoutofgroup" || name === "togglegroup" || name === "movewindowv2")
        toplevelRefresh.restart()
    }
  }
  Timer {
    id: toplevelRefresh
    interval: 60
    onTriggered: Hyprland.refreshToplevels()
  }

  // ---------- Order (drag a button to move it) ----------

  // The order buttons were dragged into. Pins also save theirs
  // (taskbar.pinned); running apps that aren't pinned keep theirs until the
  // shell restarts, as on Windows.
  property var order: []
  readonly property var arranged: Model.arrange(root.items, root.order)
  // What the buttons show: held still while a button is dragged, so a window
  // changing its title doesn't rebuild the row under the pointer.
  property var shownItems: []
  onArrangedChanged: if (root.dragFrom < 0) root.shownItems = root.arranged

  property int dragFrom: -1
  property int dragTo: -1
  property real dragDx: 0
  property real dragRoom: 0

  function beginDrag(index) {
    var held = appsRepeater.itemAt(index)
    if (!held)
      return
    root.dragRoom = held.width + appsRow.spacing
    root.dragDx = 0
    root.dragTo = index
    root.dragFrom = index
  }

  function moveDrag(dx) {
    var centers = []
    for (var i = 0; i < appsRepeater.count; i++) {
      var b = appsRepeater.itemAt(i)
      centers.push(b ? b.x + b.width / 2 : 0)
    }
    root.dragDx = dx
    root.dragTo = Model.dropIndex(centers, root.dragFrom, centers[root.dragFrom] + dx)
  }

  function endDrag(commit) {
    var from = root.dragFrom
    var to = root.dragTo
    var keys = root.shownItems.map(function(item) {
      return item.key
    })
    root.dragFrom = -1
    root.dragTo = -1
    root.dragDx = 0
    if (commit && from >= 0 && to >= 0 && to !== from) {
      var next = Model.move(keys, from, to)
      var saved = cfg.get("taskbar.pinned", []) || []
      var pins = Model.reorderPinned(saved, next)
      if (JSON.stringify(pins) !== JSON.stringify(saved))
        cfg.set("taskbar.pinned", pins)
      root.order = next
    }
    root.shownItems = root.arranged
  }

  // ---------- Room on the bar ----------

  // The bar's holder for this widget and the slot showing it; the bar hands
  // widgets no API for either, so they're found by their properties.
  property Item widgetHost: null
  readonly property Item barSlot: widgetHost && widgetHost.owner ? widgetHost.owner : null

  function findWidgetHost() {
    for (var p = root.parent; p; p = p.parent)
      if ("owner" in p && "activeItem" in p && "pool" in p)
        return p
    return null
  }

  // Omarchy's bar lays a pointer area over each widget that takes its left
  // presses (to drag the widget along the bar) and passes on only clicks.
  // The app buttons need the press to be dragged themselves, so the apps
  // widget's room in its slot is raised above that area.
  readonly property Item raisedRoom: part === "apps" && barSlot && barSlot.widgetRoom ? barSlot.widgetRoom : null
  property Item lastRaised: null
  onRaisedRoomChanged: {
    if (root.lastRaised)
      root.lastRaised.z = 0
    if (root.raisedRoom)
      root.raisedRoom.z = 1
    root.lastRaised = root.raisedRoom
  }

  Component.onCompleted: {
    root.widgetHost = root.findWidgetHost()
    root.shownItems = root.arranged
  }
  Component.onDestruction: if (root.lastRaised) root.lastRaised.z = 0

  // A section of the bar ("left", "right") the slot's bar surface holds.
  function barList(region) {
    for (var p = root.barSlot; p; p = p.parent) {
      var kids = p.children
      for (var i = 0; i < kids.length; i++)
        if (kids[i] && kids[i].region === region && "keys" in kids[i])
          return kids[i]
    }
    return null
  }
  readonly property Item leftList: barSlot ? barList("left") : null
  readonly property Item rightList: barSlot ? barList("right") : null

  // How wide the buttons may grow before they reach the bar's right section:
  // in the middle, the center stays centered, so the nearer side limits it;
  // on the left (classic), the right section does.
  readonly property real appsRoom: {
    if (part !== "apps" || vertical || !barSlot || !rightList || !rightList.parent)
      return Infinity
    var surface = rightList.parent
    var gap = Style.space(12)
    if (barSlot.region === "center") {
      var leftEnd = leftList ? leftList.x + leftList.width : 0
      var half = Math.min(surface.width / 2 - leftEnd, rightList.x - surface.width / 2) - gap
      // The rest of the center (Start) shares it.
      var row = barSlot.parent
      var others = 0
      var kids = row ? row.children : []
      for (var i = 0; i < kids.length; i++)
        if (kids[i] !== barSlot && kids[i].visible && "widgetKey" in kids[i] && kids[i].implicitWidth > 0)
          others += kids[i].implicitWidth + (row.spacing || 0)
      return Math.max(0, 2 * half - others)
    }
    if (barSlot.region === "left") {
      // Read so the binding re-runs as the slot moves; mapToItem() isn't.
      var moved = barSlot.x + leftList.x
      return Math.max(0, rightList.x - gap - barSlot.mapToItem(surface, 0, 0).x)
    }
    return Infinity
  }

  FontMetrics {
    id: labelMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  function labelFor(item) {
    if (item.windows.length > 0)
      return String(item.windows[0].title || "")
    var entry = DesktopEntries.byId(item.key)
    return entry ? entry.name : item.key
  }

  readonly property bool labeled: cfg.get("taskbar.showLabels", false)

  function buttonWidth(item) {
    if (!root.labeled)
      return root.slot
    return Math.min(root.slot * 5, Math.ceil(root.slot * 1.4 + labelMetrics.advanceWidth(root.labelFor(item))))
  }

  // The buttons that fit; the rest wait behind an overflow button, as on
  // Windows 11.
  readonly property int fitted: Model.fitCount(root.shownItems.map(root.buttonWidth), appsRow.spacing, root.appsRoom, root.slot)
  readonly property var rowItems: root.shownItems.slice(0, root.fitted)
  readonly property var overflowItems: root.shownItems.slice(root.fitted)
  property bool overflowOpen: false
  onOverflowItemsChanged: if (root.overflowItems.length === 0) root.overflowOpen = false

  function run(lua) {
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  function addressOf(window) {
    var a = String(window.address || "")
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  // Like Omarchy's dock: a minimized window comes back to this workspace
  // without animating in, then is focused and raised.
  // A tabbed window comes forward on the tab in front, whichever tab the
  // taskbar knew of: focusing another tab would switch to it.
  function bringForward(window) {
    var steps = ["local w = hl.get_window('address:" + root.addressOf(window) + "')",
                 "if not w then return end",
                 "if w.group and w.group.current then w = w.group.current end"]
    if (window.minimized && root.workspaceId >= 1)
      steps.push("hl.dispatch(hl.dsp.window.move({ workspace = '" + root.workspaceId + "', window = w }))")
    steps.push("hl.dispatch(hl.dsp.focus({ window = w }))")
    steps.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = 'top', window = w }))")
    root.run(steps.join("; "))
  }

  // Closing a window closes all its tabs, as closing a window does on Windows.
  function closeWindow(window) {
    var members = window.members && window.members.length ? window.members : [window]
    for (var i = 0; i < members.length; i++)
      if (members[i].toplevel)
        members[i].toplevel.close()
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
      root.closeWindow(item.windows[i])
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

  // Made with the shell and kept, so opening Start builds nothing and its
  // animation has every frame.
  Loader {
    active: root.part === "start"
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

  // ---------- Workspaces ----------

  Loader {
    active: root.part === "desktops"
    anchors.centerIn: parent
    sourceComponent: Workspaces {
      host: root
      settings: cfg
      slot: root.slot
    }
  }

  // ---------- App buttons ----------

  Row {
    id: appsRow
    visible: root.part === "apps"
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(root.barSize * 0.08)

    Repeater {
      id: appsRepeater
      model: root.rowItems
      onItemAdded: root.rowRevision++

      Rectangle {
        id: button
        required property var modelData
        required property int index
        readonly property var entry: DesktopEntries.byId(modelData.key)
        readonly property string indicator: Model.indicator(modelData)
        readonly property bool labeled: root.labeled
        readonly property string label: root.labelFor(modelData)
        readonly property bool held: root.dragFrom === index

        width: root.buttonWidth(modelData)
        height: root.slot
        z: held ? 1 : 0
        // Dragged, it follows the pointer and the others step aside.
        transform: Translate {
          x: button.held ? root.dragDx : Model.shiftFor(button.index, root.dragFrom, root.dragTo, root.dragRoom)
          Behavior on x {
            enabled: !button.held
            NumberAnimation {
              duration: Style.duration(150)
              easing.type: Easing.OutCubic
            }
          }
        }
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
          // Only a file loads off the main thread: an image://icon/ URL makes
          // Quickshell draw a QIcon into a QPixmap, which Qt allows only on the
          // main thread, and the shell crashes when it happens off it.
          asynchronous: String(source).indexOf("file:") === 0
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
          // Where the press was along the row, which the button's own
          // movement doesn't shift.
          property real pressX: 0
          property bool suppressClick: false
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          preventStealing: button.held
          onPressed: function(mouse) {
            suppressClick = false
            pressX = mapToItem(appsRow, mouse.x, 0).x
          }
          onPositionChanged: function(mouse) {
            if (!(mouse.buttons & Qt.LeftButton))
              return
            var dx = mapToItem(appsRow, mouse.x, 0).x - pressX
            if (!button.held) {
              if (root.dragFrom >= 0 || Math.abs(dx) < Style.space(8))
                return
              root.closePreview()
              root.beginDrag(button.index)
              if (root.bar)
                root.bar.hideTooltip(button)
            }
            root.moveDrag(dx)
          }
          // Settled after the click is swallowed: a new order rebuilds the row.
          onReleased: if (button.held) {
            suppressClick = true
            Qt.callLater(root.endDrag, true)
          }
          onCanceled: if (button.held) root.endDrag(false)
          onClicked: function(mouse) {
            if (suppressClick) {
              suppressClick = false
              return
            }
            root.closePreview()
            if (mouse.button === Qt.RightButton)
              root.openContext(button, button.modelData)
            else if (mouse.button === Qt.MiddleButton)
              root.launch(button.modelData.key)
            else
              root.activate(button.modelData)
          }
          onContainsMouseChanged: {
            if (root.dragFrom >= 0)
              return
            // A running app shows its windows; a pinned one its name.
            var previewed = root.hoverButton(button.modelData, containsMouse)
            if (!root.bar)
              return
            if (containsMouse && !previewed)
              root.bar.showTooltip(button, button.label)
            else
              root.bar.hideTooltip(button)
          }
        }
      }
    }

    // Windows 11's overflow button, for the apps that don't fit.
    Rectangle {
      id: moreButton
      visible: root.overflowItems.length > 0
      width: root.slot
      height: root.slot
      radius: Math.max(Style.cornerRadius, 4)
      color: moreMouse.pressed ? Style.pressedFill : (moreMouse.containsMouse || root.overflowOpen ? Style.hoverFill : "transparent")

      Row {
        anchors.centerIn: parent
        spacing: Math.max(2, Math.round(root.slot * 0.07))
        Repeater {
          model: 3
          Rectangle {
            width: Math.max(3, Math.round(root.slot * 0.08))
            height: width
            radius: width / 2
            color: root.bar ? root.bar.foreground : Commons.Color.foreground
          }
        }
      }

      MouseArea {
        id: moreMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.overflowOpen = !root.overflowOpen
      }
    }
  }

  // ---------- Window previews (Windows 11's thumbnails) ----------
  //
  // Resting on a running app's button shows its windows, each as it looks with
  // its title, even when there is just one: click one to bring it forward,
  // middle-click or × to close it. A tabbed window is one window here. The
  // previews follow the app's key, not a button, since the row is rebuilt as
  // windows change; moving along the bar switches app at once, as on Windows.

  property string previewKey: ""
  property string pendingKey: ""
  property string hoveredKey: ""
  property bool previewOpen: false
  property int rowRevision: 0

  function itemByKey(key) {
    for (var i = 0; i < root.rowItems.length; i++)
      if (root.rowItems[i].key === key)
        return root.rowItems[i]
    return null
  }

  readonly property var previewData: {
    var item = root.previewKey ? root.itemByKey(root.previewKey) : null
    return item && item.windows.length > 0 ? item : null
  }
  readonly property Item previewAnchor: {
    root.rowRevision
    for (var i = 0; i < root.rowItems.length; i++)
      if (root.rowItems[i].key === root.previewKey)
        return appsRepeater.itemAt(i)
    return null
  }
  onPreviewDataChanged: if (root.previewOpen && !root.previewData) root.closePreview()
  // The button the previews hang from, kept while the row is rebuilt.
  property Item shownAnchor: null
  onPreviewAnchorChanged: if (root.previewAnchor) root.shownAnchor = root.previewAnchor
  property bool previewUsed: false

  // Another popup of the bar's (Start, a menu) is open: leave it be.
  readonly property bool otherPopout: !!root.bar && !!root.bar.activePopout && root.bar.activePopout !== previewOwner

  // True when the button's windows show (so it needs no tooltip).
  function hoverButton(item, inside) {
    if (!inside) {
      if (root.hoveredKey === item.key)
        root.hoveredKey = ""
      previewOpenTimer.stop()
      previewCloseTimer.restart()
      return false
    }
    root.hoveredKey = item.key
    previewCloseTimer.stop()
    if (item.windows.length === 0 || root.contextOpen || root.otherPopout) {
      root.closePreview()
      return false
    }
    if (root.previewOpen) {
      root.previewKey = item.key
    } else {
      root.pendingKey = item.key
      previewOpenTimer.restart()
    }
    return true
  }

  function closePreview() {
    previewOpenTimer.stop()
    root.previewOpen = false
  }

  Timer {
    id: previewOpenTimer
    interval: 400
    onTriggered: {
      if (root.hoveredKey !== root.pendingKey || root.otherPopout)
        return
      root.previewKey = root.pendingKey
      if (root.previewData && root.previewAnchor) {
        // Fresh tabs and sizes for the cards.
        Hyprland.refreshToplevels()
        root.shownAnchor = root.previewAnchor
        root.previewUsed = true
        root.previewOpen = true
      }
    }
  }
  Timer {
    id: previewCloseTimer
    interval: 300
    onTriggered: if (root.hoveredKey === "" && !root.previewHovered) root.closePreview()
  }

  QtObject {
    id: previewOwner
    function close() {
      root.closePreview()
    }
  }

  readonly property bool previewHovered: previewLoader.item ? previewLoader.item.containsMouse : false
  onPreviewHoveredChanged: {
    if (root.previewHovered)
      previewCloseTimer.stop()
    else
      previewCloseTimer.restart()
  }

  readonly property int previewThumbHeight: Style.space(120)
  readonly property int previewThumbMaxWidth: Style.space(220)
  readonly property int previewTitleHeight: Style.space(26)
  readonly property int previewSpacing: Style.space(8)

  function previewThumbWidth(window) {
    var size = window && window.size
    var aspect = size && size[0] > 0 && size[1] > 0 ? size[0] / size[1] : 16 / 10
    return Math.round(Math.max(root.previewThumbHeight * 0.6, Math.min(root.previewThumbMaxWidth, root.previewThumbHeight * aspect)))
  }

  Loader {
    id: previewLoader
    // Built the first time it opens, then kept.
    active: root.part === "apps" && root.previewUsed
    sourceComponent: PopupCard {
      id: previewCard
      anchorItem: root.shownAnchor
      bar: root.bar
      owner: previewOwner
      triggerMode: "hover"
      open: root.previewOpen
      padding: Style.space(6)
      contentWidth: previewCard.fittedContentWidth(previewRow.implicitWidth + previewCard.padding * 2 + 2)
      contentHeight: previewCard.fittedContentHeight(previewRow.implicitHeight)
      onAnchorItemChanged: if (anchorItem) Qt.callLater(function() { if (previewCard.anchor) previewCard.anchor.updateAnchor() })
      onContentWidthChanged: Qt.callLater(function() { if (previewCard.anchor) previewCard.anchor.updateAnchor() })

      Row {
        id: previewRow
        spacing: root.previewSpacing

        Repeater {
          model: root.previewData ? root.previewData.windows : []

          Rectangle {
            id: thumb
            required property var modelData
            readonly property bool hovered: thumbMouse.containsMouse || closeMouse.containsMouse
            width: root.previewThumbWidth(modelData) + Style.space(12)
            height: root.previewTitleHeight + root.previewThumbHeight + Style.space(12)
            radius: Math.max(Style.cornerRadius, 4)
            color: thumbMouse.pressed ? Style.pressedFill : (thumb.hovered || thumb.modelData.activated ? Style.hoverFill : "transparent")

            MouseArea {
              id: thumbMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              cursorShape: Qt.PointingHandCursor
              onClicked: function(mouse) {
                var window = thumb.modelData
                root.closePreview()
                if (mouse.button === Qt.MiddleButton)
                  root.closeWindow(window)
                else
                  root.bringForward(window)
              }
            }

            Image {
              id: thumbIcon
              x: Style.space(6)
              y: Style.space(6) + Math.round((root.previewTitleHeight - height) / 2)
              width: Style.space(16)
              height: Style.space(16)
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: root.iconFor(root.entryForWindow(thumb.modelData.appId, thumb.modelData.pid, thumb.modelData.title), thumb.modelData.appId)
              asynchronous: String(source).indexOf("file:") === 0
            }

            Text {
              anchors.left: thumbIcon.right
              anchors.leftMargin: Style.space(6)
              anchors.right: closeButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: thumbIcon.verticalCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: String(thumb.modelData.title || "")
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Rectangle {
              id: closeButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: thumbIcon.verticalCenter
              width: Style.space(22)
              height: Style.space(22)
              radius: Math.max(Style.cornerRadius, 4)
              visible: thumb.hovered
              color: closeMouse.containsMouse ? "#c42b1c" : "transparent"

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "\u2715"
                color: closeMouse.containsMouse ? "white" : Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.body * 0.9)
              }

              MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.closeWindow(thumb.modelData)
              }
            }

            ScreencopyView {
              id: capture
              x: Style.space(6)
              y: Style.space(6) + root.previewTitleHeight
              width: root.previewThumbWidth(thumb.modelData)
              height: root.previewThumbHeight
              captureSource: root.previewOpen && thumb.modelData.toplevel ? thumb.modelData.toplevel : null
              live: root.previewOpen
              paintCursor: false
            }

            // A tabbed window says how many tabs it has.
            Rectangle {
              visible: thumb.modelData.tabs > 1
              anchors.right: capture.right
              anchors.bottom: capture.bottom
              anchors.margins: Style.space(4)
              width: tabsText.implicitWidth + Style.space(12)
              height: tabsText.implicitHeight + Style.space(4)
              radius: height / 2
              color: Commons.Util.alpha(Commons.Color.popups.background, 0.85)
              border.width: 1
              border.color: Commons.Util.alpha(Commons.Color.popups.text, 0.25)

              Text {
                id: tabsText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: thumb.modelData.tabs + " tabs"
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.body * 0.85)
              }
            }

            // Until the capture arrives (or for a window that can't be
            // captured), the app's icon.
            Image {
              anchors.centerIn: capture
              visible: !capture.hasContent
              width: Style.space(40)
              height: Style.space(40)
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: thumbIcon.source
              asynchronous: thumbIcon.asynchronous
            }
          }
        }
      }
    }
  }

  // ---------- Overflow flyout ----------

  QtObject {
    id: overflowOwner
    function close() {
      root.overflowOpen = false
    }
  }

  Loader {
    active: root.part === "apps" && (root.overflowOpen || item !== null)
    sourceComponent: KeyboardPanel {
      id: overflowPanel
      anchorItem: moreButton
      bar: root.bar
      owner: overflowOwner
      open: root.overflowOpen
      contentWidth: overflowPanel.fittedContentWidth(overflowGrid.implicitWidth)
      contentHeight: overflowPanel.fittedContentHeight(overflowGrid.implicitHeight)

      Grid {
        id: overflowGrid
        columns: Math.max(1, Math.min(5, root.overflowItems.length))
        spacing: Math.round(root.barSize * 0.08)

        Repeater {
          model: root.overflowItems

          Rectangle {
            id: cell
            required property var modelData
            readonly property var entry: DesktopEntries.byId(modelData.key)
            readonly property string indicator: Model.indicator(modelData)
            width: root.slot
            height: root.slot
            radius: Math.max(Style.cornerRadius, 4)
            color: cellMouse.pressed ? Style.pressedFill : (cellMouse.containsMouse ? Style.hoverFill : "transparent")

            Image {
              anchors.centerIn: parent
              width: root.iconSize
              height: root.iconSize
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: root.iconFor(cell.entry, cell.modelData.windows.length ? cell.modelData.windows[0].appId : cell.modelData.key)
              asynchronous: String(source).indexOf("file:") === 0
            }

            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 2
              visible: cell.indicator !== "none"
              width: cell.indicator === "active" ? Math.round(root.slot * 0.4) : Math.round(root.slot * 0.16)
              height: 3
              radius: 1.5
              color: cell.indicator === "active" ? Commons.Color.accent : Commons.Util.alpha(Commons.Color.popups.text, 0.55)
            }

            MouseArea {
              id: cellMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
              onClicked: function(mouse) {
                var item = cell.modelData
                root.overflowOpen = false
                if (mouse.button === Qt.RightButton)
                  root.openContext(moreButton, item)
                else if (mouse.button === Qt.MiddleButton)
                  root.launch(item.key)
                else
                  root.activate(item)
              }
            }
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
    root.closePreview()
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
