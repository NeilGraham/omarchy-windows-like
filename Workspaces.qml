pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Workspaces, Omarchy's equivalent of Windows' virtual desktops: the
// taskbar's "desktops" part (its name in settings), right of Start. The
// button shows the number of the workspace this monitor shows; a click opens
// the workspaces along the taskbar, each with the apps open on it, to switch
// to, rename, or add one, or to drag a window from one to another.
//
// Each monitor has workspaces 1-10 of its own, which Hyprland numbers in a
// block of ten per monitor (see Omarchy's default/hypr/monitor-workspaces.lua),
// so workspace 2 on the second monitor is Hyprland's workspace 12. Names are
// saved by number in settings.json (desktops.names: { "2": "Work" }), so a
// name applies to that workspace on every monitor, as a Windows desktop spans
// them all.
Item {
  id: root

  required property var host      // the taskbar widget, for icons and the bar
  required property var settings  // Settings.qml
  required property int slot      // the button's size
  readonly property var bar: host ? host.bar : null

  implicitWidth: slot
  implicitHeight: slot

  readonly property int slots: 10
  // Omarchy keeps five workspaces on hand; more appear as they're used.
  readonly property int minimumShown: 5

  readonly property var hyprMonitor: host ? host.hyprMonitor : null
  readonly property string monitorName: hyprMonitor ? hyprMonitor.name : ""
  readonly property int activeId: hyprMonitor && hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1

  // Connector -> block, from the file Omarchy's Hyprland config keeps them in.
  property var blocks: ({})

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "")
        next[fields[1]] = parseInt(fields[0], 10)
    }
    root.blocks = next
  }

  function blockOf(id) {
    return Math.floor((id - 1) / root.slots)
  }

  function numberOf(id) {
    return (id - 1) % root.slots + 1
  }

  // Until Hyprland has written the file, the workspace a monitor shows is in
  // its own block.
  readonly property int block: {
    var b = root.blocks[root.monitorName]
    if (b !== undefined && !isNaN(b))
      return b
    return root.activeId > 0 ? root.blockOf(root.activeId) : 0
  }

  // The number on the button. A workspace visiting from an unplugged
  // monitor's block still shows its own number.
  readonly property int activeNumber: root.activeId > 0 ? root.numberOf(root.activeId) : 1

  // ---------- Names ----------

  readonly property var names: {
    var n = root.settings ? root.settings.get("desktops.names", {}) : {}
    return n && typeof n === "object" && !Array.isArray(n) ? n : {}
  }

  function nameOf(number) {
    var name = root.names[String(number)]
    return name ? String(name) : "Workspace " + number
  }

  function rename(number, name) {
    var next = Object.assign({}, root.names)
    name = String(name || "").trim()
    if (name === "" || name === "Workspace " + number)
      delete next[String(number)]
    else
      next[String(number)] = name
    root.settings.set("desktops.names", next)
  }

  // ---------- Workspaces and their windows ----------

  // The monitor's workspaces: the first five, then any more that exist, up to
  // the highest one open. Only a count, so the cards are built once and kept.
  readonly property int blockBase: root.block * root.slots
  readonly property int workspaceCount: {
    var values = Hyprland.workspaces.values
    var highest = root.minimumShown
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > root.blockBase && id <= root.blockBase + root.slots)
        highest = Math.max(highest, id - root.blockBase)
    }
    if (root.activeId > root.blockBase && root.activeId <= root.blockBase + root.slots)
      highest = Math.max(highest, root.activeId - root.blockBase)
    return highest
  }

  // ---------- Windows, kept up to date in place ----------
  //
  // The previews are the windows' captures, which take a moment to start, so
  // the rows are matched by address and updated where they are rather than
  // rebuilt: a window that moves keeps its preview, and only a new window
  // starts a capture. Hyprland reports positions a window at a time; they're
  // gathered and applied together on the next frame.

  ListModel { id: windowModel }  // address, wsId, wx, wy, ww, wh, stacking, appId
  // wsId -> number of windows, for the "Empty" label.
  property var windowCounts: ({})

  function toplevelFor(address) {
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++)
      if (String(values[i].address) === address)
        return values[i]
    return null
  }

  // Everything syncWindows reads, so any change to it schedules one.
  readonly property var windowState: {
    var values = Hyprland.toplevels.values
    var out = [root.blockBase, root.screenBox]
    for (var i = 0; i < values.length; i++)
      out.push(values[i].lastIpcObject, values[i].workspace)
    return out
  }
  onWindowStateChanged: syncTimer.restart()
  Timer {
    id: syncTimer
    interval: 0
    onTriggered: root.syncWindows()
  }

  function syncWindows() {
    var values = Hyprland.toplevels.values
    var wanted = []
    var counts = {}
    for (var i = 0; i < values.length; i++) {
      var top = values[i]
      var w = top.wayland
      var ws = top.workspace ? top.workspace.id : -1
      if (ws <= root.blockBase || ws > root.blockBase + root.slots || !w)
        continue
      var ipc = top.lastIpcObject || {}
      // A tab behind another (a Hyprland group) isn't on screen.
      if (ipc.hidden === true || !ipc.at || !ipc.size)
        continue
      counts[ws] = (counts[ws] || 0) + 1
      wanted.push({
        address: String(top.address),
        wsId: ws,
        wx: ipc.at[0] - root.screenBox.x,
        wy: ipc.at[1] - root.screenBox.y,
        ww: ipc.size[0],
        wh: ipc.size[1],
        // The most recently focused on top.
        stacking: ipc.focusHistoryID === undefined ? -1000 : -Number(ipc.focusHistoryID),
        appId: String(w.appId || "")
      })
    }
    var byAddress = {}
    for (var j = 0; j < wanted.length; j++)
      byAddress[wanted[j].address] = wanted[j]
    for (var r = windowModel.count - 1; r >= 0; r--) {
      var row = windowModel.get(r)
      var want = byAddress[row.address]
      if (!want) {
        windowModel.remove(r)
        continue
      }
      for (var key in want)
        if (row[key] !== want[key])
          windowModel.setProperty(r, key, want[key])
      delete byAddress[row.address]
    }
    for (var address in byAddress)
      windowModel.append(byAddress[address])
    root.windowCounts = counts
  }

  // The monitor in logical pixels, which window positions are given in.
  readonly property var screenBox: {
    var m = root.hyprMonitor
    if (!m)
      return { x: 0, y: 0, w: 1920, h: 1080 }
    var scale = Number(m.scale) || 1
    var ipc = m.lastIpcObject || {}
    var rotated = Number(ipc.transform) % 2 === 1
    return {
      x: Number(m.x),
      y: Number(m.y),
      w: (rotated ? m.height : m.width) / scale,
      h: (rotated ? m.width : m.height) / scale
    }
  }

  // ---------- Getting ready before the click ----------
  //
  // Resting the pointer on the button (and opening the workspaces) asks
  // Hyprland where the windows are and takes new previews, so by the time the
  // workspaces show, they're up to date. Captures start only after the first
  // time, not with the shell.
  property bool warm: false
  property int cardsRevision: 0
  property int captureRound: 0
  property double preparedAt: 0

  function prepare() {
    var now = Date.now()
    if (now - root.preparedAt < 700)
      return
    root.preparedAt = now
    root.warm = true
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    backgroundProc.running = true
    root.captureRound++
  }

  onOpenChanged: {
    if (open)
      root.prepare()
    else
      root.editing = -1
  }

  // The background, resolved from Omarchy's link so a new one is a new
  // address: decoded once and shared by every card.
  property string backgroundSource: ""
  Process {
    id: backgroundProc
    // Looked up when the shell starts too, so the cards (which are built
    // then) have it decoded before the first opening.
    running: true
    command: ["readlink", "-f", (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text).trim()
        if (path !== "")
          root.backgroundSource = "file://" + path
      }
    }
  }

  function goToWindow(address) {
    if (root.host)
      root.host.bringForward({ address: address, minimized: false })
  }

  // A new workspace is the first number after those shown, as on Windows.
  readonly property int nextNumber: root.workspaceCount < root.slots ? root.workspaceCount + 1 : -1

  // ---------- Dragging a window to another workspace ----------
  //
  // As in Windows' Task View: drag a window's preview onto another workspace
  // (or onto New workspace) and it moves there, keeping its place on the
  // screen, while you stay on the workspace you're on.
  property string dragAddress: ""
  property int dragFrom: -1     // the workspace number it came from
  property int dropNumber: -1   // the workspace under the pointer, or -1

  function moveWindow(address, number) {
    // Quickshell gives Hyprland's addresses without their 0x.
    address = String(address || "")
    if (address.indexOf("0x") !== 0)
      address = "0x" + address
    if (!/^0x[0-9a-fA-F]+$/.test(address) || number < 1 || number > root.slots)
      return
    var wsId = root.blockBase + number
    var lua = "hl.dispatch(hl.dsp.window.move({ workspace = '" + wsId + "', follow = false, window = 'address:" + address + "' }))"
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  function focusWorkspace(number) {
    if (number < 1 || number > root.slots || root.monitorName === "")
      return
    var expression = "o.workspaces.focus(" + number + ", \"" + root.monitorName.replace(/["\\]/g, "") + "\")"
    Quickshell.execDetached(["hyprctl", "dispatch", expression])
  }

  // ---------- The button ----------

  property bool open: false
  property int editing: -1  // the number of the workspace being renamed

  function close() {
    root.open = false
    root.dragAddress = ""
    root.dropNumber = -1
  }

  // `hyprctl dispatch 'hl.dsp.event("windows-like-desktops")'` opens them on
  // the focused monitor, for a key binding of your own.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "custom" && event.data === "windows-like-desktops" && root.host && root.host.onFocusedMonitor)
        root.open = !root.open
    }
  }

  readonly property color foreground: root.bar ? root.bar.foreground : Commons.Color.foreground

  Rectangle {
    id: button
    anchors.centerIn: parent
    width: root.slot
    height: root.slot
    radius: Math.max(Style.cornerRadius, 4)
    color: buttonMouse.pressed ? Style.pressedFill : (buttonMouse.containsMouse || root.open ? Style.hoverFill : "transparent")

    // Two screens, one behind the other (Windows' Task View), the front one
    // carrying the workspace's number. Of the screen behind, only what shows
    // past the front one is drawn: its top and right edges, and the stubs of
    // the other two.
    Item {
      id: glyph
      readonly property int w: Math.round(root.slot * 0.5)
      readonly property int h: Math.round(root.slot * 0.38)
      readonly property int d: Math.round(root.slot * 0.12)  // how far back the second screen sits
      readonly property int line: Math.max(1, Math.round(root.slot / 28))
      readonly property color ink: buttonMouse.containsMouse || root.open ? Commons.Color.accent : root.foreground
      readonly property color dim: Commons.Util.alpha(ink, 0.5)
      width: w + d
      height: h + d
      anchors.centerIn: parent

      // Behind: top, right, and the stubs of left and bottom.
      Rectangle { x: glyph.d; y: 0; width: glyph.w; height: glyph.line; color: glyph.dim }
      Rectangle { x: glyph.d + glyph.w - glyph.line; y: 0; width: glyph.line; height: glyph.h; color: glyph.dim }
      Rectangle { x: glyph.d; y: 0; width: glyph.line; height: glyph.d; color: glyph.dim }
      Rectangle { x: glyph.w; y: glyph.h - glyph.line; width: glyph.d; height: glyph.line; color: glyph.dim }

      // In front.
      Rectangle {
        x: 0
        y: glyph.d
        width: glyph.w
        height: glyph.h
        radius: 2
        color: "transparent"
        border.width: glyph.line
        border.color: glyph.ink

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(root.activeNumber)
          color: glyph.ink
          font.family: Style.font.family
          font.pixelSize: Math.max(8, Math.round(glyph.h * 0.66))
          font.bold: true
        }
      }
    }

    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.open = !root.open
        if (root.bar)
          root.bar.hideTooltip(button)
      }
      onWheel: function(wheel) {
        // A wheel notch steps through the workspaces, as on Omarchy's row.
        var step = wheel.angleDelta.y < 0 || wheel.angleDelta.x < 0 ? 1 : -1
        var next = Math.max(1, Math.min(root.workspaceCount, root.activeNumber + step))
        if (next !== root.activeNumber)
          root.focusWorkspace(next)
      }
      onContainsMouseChanged: {
        if (containsMouse)
          root.prepare()
        if (!root.bar || root.open)
          return
        if (containsMouse)
          root.bar.showTooltip(button, root.nameOf(root.activeNumber))
        else
          root.bar.hideTooltip(button)
      }
    }
  }

  // ---------- The flyout ----------

  // Cards shrink to keep every workspace, and New workspace, on the screen.
  property real room: Infinity  // the flyout's width inside its padding
  readonly property int cardSpacing: Style.space(10)
  readonly property int cardCount: root.workspaceCount + (root.nextNumber > 0 ? 1 : 0)
  readonly property int cardWidth: Math.max(Style.space(70), Math.min(Style.space(200),
      Math.floor((root.room - (root.cardCount - 1) * root.cardSpacing) / Math.max(1, root.cardCount))))
  readonly property int cardHeight: Math.round(root.cardWidth * Math.min(0.75, Math.max(0.3, root.screenBox.h / root.screenBox.w)))

  // Built with the shell and kept, so opening it builds nothing.
  Loader {
    active: true
    sourceComponent: KeyboardPanel {
      id: panel
      anchorItem: button
      bar: root.bar
      owner: root
      open: root.open
      centerOnBar: false
      focusTarget: keys
      // The card's size includes its padding and border, the same on every
      // side (the height helper adds them; the width one doesn't).
      contentWidth: panel.fittedContentWidth(strip.implicitWidth + panel.verticalContentInset)
      readonly property real room: panel.availableCardWidth - panel.verticalContentInset
      onRoomChanged: root.room = room
      Component.onCompleted: root.room = room
      contentHeight: panel.fittedContentHeight(strip.implicitHeight)

      Item {
        id: keys
        width: strip.implicitWidth
        height: strip.implicitHeight
        focus: true
        // The workspace whose card is under a point, New workspace's number for
        // that card, or -1.
        function workspaceAt(x, y) {
          for (var i = 0; i < cardRepeater.count; i++) {
            var card = cardRepeater.itemAt(i)
            if (card && card.contains(card.mapFromItem(keys, x, y)))
              return i + 1
          }
          if (newCard.visible && newCard.contains(newCard.mapFromItem(keys, x, y)))
            return root.nextNumber
          return -1
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }

        // The window previews, one per window for as long as it's open, each
        // placed in its workspace's card.
        Repeater {
          model: windowModel

          Rectangle {
            id: mini
            required property string address
            required property int wsId
            required property real wx
            required property real wy
            required property real ww
            required property real wh
            required property int stacking
            required property string appId
            readonly property Item layerItem: {
              root.cardsRevision
              var card = cardRepeater.itemAt(wsId - root.blockBase - 1)
              return card ? card.windowLayer : null
            }
            readonly property real k: layerItem ? layerItem.k : 0
            parent: layerItem ? layerItem : keys
            visible: layerItem !== null
            readonly property bool dragging: root.dragAddress === mini.address
            opacity: dragging ? 0.35 : 1
            z: stacking
            x: Math.round(wx * k)
            y: Math.round(wy * k)
            width: Math.max(4, Math.round(ww * k))
            height: Math.max(4, Math.round(wh * k))
            color: Commons.Color.popups.background
            border.width: miniMouse.containsMouse ? 2 : 1
            border.color: miniMouse.containsMouse ? Commons.Color.accent : Commons.Util.alpha(Commons.Color.popups.text, 0.35)

            ScreencopyView {
              id: capture
              anchors.fill: parent
              anchors.margins: 1
              readonly property var toplevel: { Hyprland.toplevels.values; return root.toplevelFor(mini.address) }
              captureSource: root.warm && toplevel && toplevel.wayland ? toplevel.wayland : null
              live: false
              paintCursor: false
              Connections {
                target: root
                function onCaptureRoundChanged() { if (capture.captureSource) capture.captureFrame() }
              }
            }

            // The app's icon over the window, as Windows does.
            Image {
              readonly property real size: Math.min(Style.space(22), mini.width * 0.5, mini.height * 0.5)
              // In the corner once the window shows, in the middle until then.
              x: capture.hasContent ? 3 : Math.round((mini.width - width) / 2)
              y: capture.hasContent ? mini.height - height - 3 : Math.round((mini.height - height) / 2)
              width: size
              height: size
              sourceSize.width: Style.space(44)
              sourceSize.height: Style.space(44)
              source: root.host ? root.host.iconFor(root.host.entryForAppId(mini.appId), mini.appId) : ""
              asynchronous: String(source).indexOf("file:") === 0
            }

            // A window: click to go to it, on its workspace; drag it onto
            // another workspace to move it there.
            MouseArea {
              id: miniMouse
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true
              cursorShape: mini.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              property point pressAt: Qt.point(0, 0)
              property point grabOffset: Qt.point(0, 0)
              property bool moved: false
              onPressed: function(mouse) {
                pressAt = Qt.point(mouse.x, mouse.y)
                moved = false
              }
              onPositionChanged: function(mouse) {
                if (!pressed || !(pressedButtons & Qt.LeftButton))
                  return
                if (!moved && Math.abs(mouse.x - pressAt.x) + Math.abs(mouse.y - pressAt.y) < 6)
                  return
                if (!moved) {
                  moved = true
                  grabOffset = pressAt
                  root.editing = -1
                  root.dragFrom = mini.wsId - root.blockBase
                  root.dragAddress = mini.address
                }
                var p = mapToItem(keys, mouse.x, mouse.y)
                ghost.x = p.x - grabOffset.x
                ghost.y = p.y - grabOffset.y
                root.dropNumber = keys.workspaceAt(p.x, p.y)
              }
              onReleased: function(mouse) {
                if (!moved)
                  return
                var target = root.dropNumber
                var address = root.dragAddress
                root.dragAddress = ""
                root.dropNumber = -1
                if (target > 0 && target !== root.dragFrom)
                  root.moveWindow(address, target)
              }
              onCanceled: {
                if (moved) {
                  root.dragAddress = ""
                  root.dropNumber = -1
                }
              }
              onClicked: function(mouse) {
                if (moved)
                  return
                if (mouse.button === Qt.RightButton) {
                  root.editing = mini.wsId - root.blockBase
                  return
                }
                root.goToWindow(mini.address)
                root.close()
              }
            }

            // The preview that follows the pointer while it's dragged, drawn
            // above the cards (which clip their own windows).
            ShaderEffectSource {
              id: ghost
              parent: keys
              visible: mini.dragging
              z: 1000
              width: mini.width
              height: mini.height
              sourceItem: mini.dragging ? mini : null
              live: true
              hideSource: false
              opacity: 0.9
            }
          }
        }

        Row {
          id: strip
          spacing: root.cardSpacing

          Repeater {
            id: cardRepeater
            model: root.workspaceCount
            onItemAdded: root.cardsRevision++
            onItemRemoved: root.cardsRevision++

            Item {
              id: card
              required property int index
              readonly property int number: index + 1
              readonly property int wsId: root.blockBase + number
              readonly property bool current: wsId === root.activeId
              readonly property bool renaming: root.editing === number
              readonly property bool dropTarget: root.dragAddress !== "" && root.dropNumber === number && number !== root.dragFrom
              // Where the window previews put themselves.
              readonly property Item windowLayer: windowLayer
              width: root.cardWidth
              height: root.cardHeight + nameRow.height + Style.space(6)

              // The workspace as a little screen: the background, and each
              // window where it is, as it looks (or its icon, if it can't
              // be captured).
              Rectangle {
                id: screen
                width: parent.width
                height: root.cardHeight
                radius: Math.max(Style.cornerRadius, 6)
                color: Commons.Util.alpha(Commons.Color.popups.text, 0.06)
                border.width: card.current || card.dropTarget || cardMouse.containsMouse ? 2 : 1
                border.color: card.current || card.dropTarget ? Commons.Color.accent
                    : cardMouse.containsMouse ? Commons.Util.alpha(Commons.Color.accent, 0.6)
                    : Commons.Util.alpha(Commons.Color.popups.text, 0.15)

                Item {
                  id: miniature
                  anchors.fill: parent
                  anchors.margins: screen.border.width
                  clip: true
                  readonly property real k: width / Math.max(1, root.screenBox.w)

                  // One size for every card, so they share one decoded image.
                  Image {
                    anchors.fill: parent
                    source: root.backgroundSource
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 480
                    asynchronous: true
                    opacity: 0.85
                  }

                  // Anywhere but on a window: go to the workspace.
                  MouseArea {
                    id: cardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        root.editing = card.number
                        return
                      }
                      root.focusWorkspace(card.number)
                      root.close()
                    }
                  }

                  Item {
                    id: windowLayer
                    anchors.fill: parent
                    readonly property real k: miniature.k
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !root.windowCounts[card.wsId]
                    textFormat: Text.PlainText
                    text: "Empty"
                    color: Commons.Color.popups.text
                    style: Text.Outline
                    styleColor: Commons.Util.alpha(Commons.Color.popups.background, 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }
              }

              // The name: click it to rename, as on Windows.
              Item {
                id: nameRow
                anchors.top: screen.bottom
                anchors.topMargin: Style.space(6)
                width: parent.width
                height: Style.space(28)

                Text {
                  id: nameText
                  anchors.fill: parent
                  visible: !card.renaming
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  elide: Text.ElideRight
                  text: root.nameOf(card.number)
                  color: nameMouse.containsMouse ? Commons.Color.accent : Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: card.current
                }

                MouseArea {
                  id: nameMouse
                  anchors.fill: parent
                  visible: !card.renaming
                  hoverEnabled: true
                  cursorShape: Qt.IBeamCursor
                  onClicked: root.editing = card.number
                }

                TextField {
                  id: field
                  anchors.fill: parent
                  visible: card.renaming
                  verticalPadding: 2
                  foreground: Commons.Color.popups.text
                  horizontalAlignment: TextInput.AlignHCenter
                  maximumLength: 40
                  onVisibleChanged: {
                    if (visible) {
                      text = root.nameOf(card.number)
                      forceActiveFocus()
                      selectAll()
                    }
                  }
                  onAccepted: {
                    root.rename(card.number, text)
                    root.editing = -1
                    keys.forceActiveFocus()
                  }
                  // Clicking elsewhere keeps what was typed, as on Windows.
                  onActiveFocusChanged: if (!activeFocus && card.renaming) {
                    root.rename(card.number, text)
                    root.editing = -1
                  }
                  Keys.onEscapePressed: function(event) {
                    root.editing = -1
                    keys.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
            }
          }

          // + New workspace
          Item {
            id: newCard
            visible: root.nextNumber > 0
            readonly property bool dropTarget: root.dragAddress !== "" && root.dropNumber === root.nextNumber
            width: root.cardWidth
            height: root.cardHeight + Style.space(34)

            Rectangle {
              width: parent.width
              height: root.cardHeight
              radius: Math.max(Style.cornerRadius, 6)
              color: newMouse.containsMouse || newCard.dropTarget ? Style.hoverFill : "transparent"
              border.width: newCard.dropTarget ? 2 : 1
              border.color: newCard.dropTarget ? Commons.Color.accent : Commons.Util.alpha(Commons.Color.popups.text, newMouse.containsMouse ? 0.4 : 0.2)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "+"
                color: newMouse.containsMouse ? Commons.Color.accent : Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(30)
              }

              MouseArea {
                id: newMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.focusWorkspace(root.nextNumber)
                  root.close()
                }
              }
            }

            Text {
              y: root.cardHeight + Style.space(6)
              width: parent.width
              height: Style.space(28)
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "New workspace"
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }
}
