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
//   desktops - right of Start: the number of the desktop (workspace) shown,
//           which opens the desktops to switch to, rename or add one
//           (Desktops.qml).
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

  // ---------- Desktops ----------

  Loader {
    active: root.part === "desktops"
    anchors.centerIn: parent
    sourceComponent: Desktops {
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
            if (mouse.button === Qt.RightButton)
              root.openContext(button, button.modelData)
            else if (mouse.button === Qt.MiddleButton)
              root.launch(button.modelData.key)
            else
              root.activate(button.modelData)
          }
          onContainsMouseChanged: {
            if (!root.bar || root.dragFrom >= 0)
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
