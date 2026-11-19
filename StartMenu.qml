pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TaskbarModel.js" as Model

// The start menu, opened from the taskbar's start button (Taskbar.qml).
//
// Windows 11 (centered over the taskbar): search; then pinned apps (or All
// apps), and Recommended: recently used and recently installed apps; your
// name and power along the bottom.
// Classic (from the bottom-left): power, settings and you down the left;
// every app, A-Z with letter headings; pinned tiles on the right.
//
// Typing searches. Arrows and Enter pick, Esc closes; right-click an app to
// pin or unpin it.
KeyboardPanel {
  id: root

  property var settings: null
  property var host: null
  property string view: ""
  property var recents: []

  readonly property bool classic: settings && settings.get("taskbar.style", "windows11") === "classic"
  readonly property var appLibrary: host ? host.appLibrary : null

  contentWidth: Style.space(classic ? 600 : 640)
  contentHeight: Math.min(Style.space(classic ? 560 : 660), roomOnScreen)
  centerOnBar: !classic
  focusTarget: search

  // ---------- Data ----------

  property string query: ""
  property string page: view === "all" ? "all" : "home"
  property int selected: 0
  property bool powerOpen: false

  // The taskbar makes the menu when the shell starts and keeps it, so opening
  // it builds nothing: this only resets what the last opening left.
  function prepare() {
    query = ""
    search.text = ""
    pageMotion = false
    page = view === "all" || classic ? "all" : "home"
    pageMotion = true
    selected = 0
    powerOpen = false
    pinTarget = null
    installedProc.running = true
  }
  onOpenChanged: {
    if (open)
      prepare()
    slideOnOpen()
  }
  Component.onCompleted: {
    moveWithSlide()
    installedProc.running = true
    if (open)
      prepare()
  }

  // ---------- Motion ----------

  // Start slides up from the taskbar (down from a bar at the top) as it fades
  // in, as on Windows 11, and goes back quicker than it came. Only a
  // transform on the window's content moves, so nothing is laid out again,
  // and the slide starts once the surface is on screen, so none of its frames
  // go to mapping it. Durations go through Style.duration, which Omarchy's
  // "animations off" makes 0; animations.enabled turns the slide off.
  readonly property bool animated: !settings || settings.get("animations.enabled", true)
  readonly property real slideDistance: animated ? Style.space(48) * (barPos === "top" ? -1 : 1) : 0
  // 1 while away (below the bar), 0 in place.
  property real slide: 0

  property NumberAnimation slideIn: NumberAnimation {
    id: slideIn
    target: root
    property: "slide"
    to: 0
    duration: Style.duration(250)
    easing.type: Easing.Bezier
    // Windows' "decelerate" curve.
    easing.bezierCurve: [0.1, 0.9, 0.2, 1, 1, 1]
  }
  property NumberAnimation slideOut: NumberAnimation {
    id: slideOut
    target: root
    property: "slide"
    to: 1
    // Done before the panel's own 120 ms fade-out unmaps it.
    duration: Style.duration(110)
    easing.type: Easing.InCubic
  }

  function slideOnOpen() {
    slideIn.stop()
    slideOut.stop()
    if (!open)
      slideOut.start()
    else if (backingWindowVisible)
      slideIn.start()
    else
      slide = 1
  }
  onBackingWindowVisibleChanged: if (backingWindowVisible && open && !slideIn.running) slideIn.start()

  property Translate slideShift: Translate {
    y: root.slide * root.slideDistance
  }
  // The window's own content item: the top of the card's parents.
  function moveWithSlide() {
    var top = card
    while (top.parent)
      top = top.parent
    top.transform = [root.slideShift]
  }
  Component.onDestruction: slideIn.stop()

  // Home and All apps slide across and cross-fade as they swap; not when
  // opening resets the page.
  property bool pageMotion: true

  // Never taller than the room above (or below) the bar.
  readonly property int roomOnScreen: screen ? screen.height - (bar ? bar.barSize : 0) - 4 * Style.gapsOut : 900

  // The app library ranks entries as { entry, score, ... } rows.
  function entriesOf(rows) {
    return (rows || []).map(function(r) {
      return r && r.entry ? r.entry : r
    })
  }

  function allApps() {
    if (root.appLibrary)
      return entriesOf(root.appLibrary.sortedEntries(""))
    return DesktopEntries.applications.values.filter(function(e) {
      return !e.noDisplay
    })
  }

  function nameOf(entry) {
    if (!entry)
      return ""
    return root.appLibrary ? root.appLibrary.entryName(entry) : String(entry.name || entry.id)
  }

  function iconOf(entry) {
    if (!entry)
      return ""
    return root.host ? root.host.iconFor(entry, entry.id) : Quickshell.iconPath(entry.icon, "application-x-executable")
  }

  readonly property var results: query === "" ? [] : (root.appLibrary ? entriesOf(root.appLibrary.sortedEntries(query)) : allApps().filter(function(e) {
    return String(e.name).toLowerCase().indexOf(query.toLowerCase()) >= 0
  })).slice(0, 9)

  // DesktopEntries.byId() is no binding dependency, and a rescan (any
  // .desktop file changing) replaces the object of an id that is in more than
  // one data dir (foot: ~/.local/share and /usr/share), leaving a held one
  // null. Reading applications.values looks the ids up again after each.
  readonly property var pinnedApps: {
    var revision = DesktopEntries.applications.values
    return ((settings ? settings.get("start.pinned", []) : []) || []).map(function(id) {
      return DesktopEntries.byId(id)
    }).filter(function(e) {
      return !!e
    })
  }

  readonly property var allRows: Model.withLetterHeaders(allApps(), nameOf)

  property var installed: []
  property Process installedProc: Process {
    id: installedProc
    command: ["sh", "-c", "find /usr/share/applications \"$HOME/.local/share/applications\" -maxdepth 1 -name '*.desktop' -printf '%C@ %f\\n' 2>/dev/null | sort -rn | head -60"]
    stdout: StdioCollector {
      // Plenty: Recommended skips apps pinned to Start, and the next fill in.
      // Set only when it changed, so Recommended isn't rebuilt as Start opens.
      onStreamFinished: {
        var next = Model.recentlyInstalled(text, root.allApps().map(function(e) {
          return e.id
        }), 20)
        if (JSON.stringify(next) !== JSON.stringify(root.installed))
          root.installed = next
      }
    }
  }

  // At most 8; the grid shows as many rows of them as fit.
  readonly property var recommended: {
    var revision = DesktopEntries.applications.values
    var recent = settings ? settings.get("start.showRecent", true) : true
    var fresh = settings ? settings.get("start.showRecentlyInstalled", true) : true
    var pinned = (settings ? settings.get("start.pinned", []) : []) || []
    var rows = Model.recommendations(fresh ? root.installed : [], recent ? (root.recents || []) : [], pinned, function(id) {
      var entry = DesktopEntries.byId(id)
      return entry && !entry.noDisplay ? String(entry.id) : ""
    }, 8)
    return rows.map(function(r) {
      return { entry: DesktopEntries.byId(r.id), why: r.why === "installed" ? "Recently installed" : "Recently used" }
    })
  }

  // ---------- Actions ----------

  function launch(entry) {
    if (!entry)
      return
    if (root.host)
      root.host.launch(entry.id)
    root.close()
  }

  function togglePin(listName, entry) {
    if (root.host && entry)
      root.host.togglePin(listName, entry.id)
  }

  function power(action) {
    var commands = {
      lock: ["omarchy-system-lock"],
      suspend: ["systemctl", "suspend"],
      logout: ["omarchy-system", "logout"],
      reboot: ["omarchy-system", "reboot"],
      shutdown: ["omarchy-system", "shutdown"]
    }
    root.close()
    Quickshell.execDetached(commands[action])
  }

  function openSettings() {
    root.close()
    Quickshell.execDetached(["sh", "-c", "command -v windows-like-settings >/dev/null && exec uwsm-app -- windows-like-settings || exec omarchy-menu toggle setup"])
  }

  // ---------- Pin menu (right-click on an app) ----------

  property var pinTarget: null
  property point pinAt: Qt.point(0, 0)

  function openPinMenu(entry, item, mouse) {
    root.pinTarget = entry
    root.pinAt = item.mapToItem(card, mouse.x, mouse.y)
  }

  // ---------- Pieces ----------

  component Label: Text {
    textFormat: Text.PlainText
    color: Commons.Color.popups.text
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component AppTile: Rectangle {
    id: tile
    required property var entry
    property string subtitle: ""
    property bool wide: false
    property bool current: false
    signal activated()

    radius: Math.max(Style.cornerRadius, 6)
    color: tileMouse.pressed ? Style.pressedFill : (tileMouse.containsMouse || current ? Style.hoverFill : "transparent")

    Image {
      id: tileIcon
      width: tile.wide ? Style.space(28) : Style.space(32)
      height: width
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      x: tile.wide ? Style.space(10) : Math.round((tile.width - width) / 2)
      y: tile.wide ? Math.round((tile.height - height) / 2) : Style.space(12)
      source: root.iconOf(tile.entry)
      // Only a file loads off the main thread: an image://icon/ URL makes
      // Quickshell draw a QIcon into a QPixmap, which Qt allows only on the
      // main thread, and the shell crashes when it happens off it.
      asynchronous: String(source).indexOf("file:") === 0
    }

    Column {
      visible: tile.wide
      anchors.left: tileIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      Label {
        width: parent.width
        text: root.nameOf(tile.entry)
      }
      Label {
        width: parent.width
        visible: tile.subtitle !== ""
        text: tile.subtitle
        opacity: 0.6
        font.pixelSize: Style.font.caption
      }
    }

    Label {
      visible: !tile.wide
      anchors.top: tileIcon.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      horizontalAlignment: Text.AlignHCenter
      text: root.nameOf(tile.entry)
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton)
          root.openPinMenu(tile.entry, tile, mouse)
        else
          tile.activated()
      }
    }
  }

  component SectionTitle: Item {
    property alias text: title.text
    property string action: ""
    signal actionClicked()
    height: Style.space(30)
    Label {
      id: title
      anchors.verticalCenter: parent.verticalCenter
      font.bold: true
    }
    Rectangle {
      visible: parent.action !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: actionLabel.implicitWidth + Style.space(20)
      height: Style.space(24)
      radius: Math.max(Style.cornerRadius, 4)
      color: actionMouse.containsMouse ? Style.hoverFill : Style.normalFill
      Label {
        id: actionLabel
        anchors.centerIn: parent
        text: parent.parent.action
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        id: actionMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: parent.parent.actionClicked()
      }
    }
  }

  component AllAppsList: ListView {
    id: list
    clip: true
    model: root.allRows
    boundsBehavior: Flickable.StopAtBounds
    Connections {
      target: root
      function onOpenChanged() {
        if (root.open)
          list.positionViewAtBeginning()
      }
    }
    delegate: Item {
      id: row
      required property var modelData
      width: list.width
      height: row.modelData.header !== undefined ? Style.space(30) : Style.space(40)
      Label {
        visible: row.modelData.header !== undefined
        anchors.verticalCenter: parent.verticalCenter
        x: Style.space(10)
        text: row.modelData.header || ""
        color: Commons.Color.accent
        font.bold: true
      }
      AppTile {
        visible: row.modelData.app !== undefined
        anchors.fill: parent
        entry: row.modelData.app || null
        wide: true
        onActivated: root.launch(row.modelData.app)
      }
    }
  }

  // ---------- Layout ----------

  Item {
    id: card
    anchors.fill: parent

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.pinTarget)
          root.pinTarget = null
        else if (root.query === "" && root.page === "all" && !root.classic && root.view !== "all")
          root.page = "home"
        else
          root.close()
        event.accepted = true
      } else if (root.query !== "" && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
        var n = root.results.length
        if (n > 0)
          root.selected = (root.selected + (event.key === Qt.Key_Down ? 1 : n - 1)) % n
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (root.query !== "" && root.results.length > 0)
          root.launch(root.results[Math.min(root.selected, root.results.length - 1)])
        event.accepted = true
      }
    }

    // Search
    Rectangle {
      id: searchBox
      x: root.classic ? Style.space(56) : 0
      width: parent.width - x
      height: Style.space(38)
      radius: Math.max(Style.cornerRadius, 6)
      color: Style.normalFill
      border.color: search.activeFocus ? Commons.Color.accent : Style.normalBorderColor
      border.width: 1

      Label {
        anchors.verticalCenter: parent.verticalCenter
        x: Style.space(14)
        visible: search.text === ""
        text: "Search for apps"
        opacity: 0.55
      }
      FilterInput {
        id: search
        keyHandler: card
        anchors.verticalCenter: parent.verticalCenter
        x: Style.space(14)
        width: parent.width - Style.space(28)
        color: Commons.Color.popups.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        onTextChanged: {
          root.query = text
          root.selected = 0
        }
      }
    }

    // Search results (either style)
    Column {
      visible: root.query !== ""
      anchors.top: searchBox.bottom
      anchors.topMargin: Style.space(14)
      x: searchBox.x
      width: searchBox.width
      spacing: Style.space(2)
      SectionTitle {
        width: parent.width
        text: root.results.length ? "Best matches" : "No apps match"
      }
      Repeater {
        model: root.results
        AppTile {
          required property var modelData
          required property int index
          width: parent.width
          height: Style.space(42)
          wide: true
          entry: modelData
          current: index === root.selected
          onActivated: root.launch(modelData)
        }
      }
    }

    // ----- Windows 11 -----
    Item {
      id: home
      visible: !root.classic && root.query === ""
      anchors.top: searchBox.bottom
      anchors.topMargin: Style.space(14)
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.space(10)
      width: parent.width
      clip: true

      // Pinned, then Recommended
      Column {
        id: homePage
        visible: opacity > 0
        opacity: root.page === "home" ? 1 : 0
        Behavior on opacity {
          enabled: root.pageMotion
          NumberAnimation {
            duration: Style.duration(root.animated ? 200 : 0)
            easing.type: Easing.OutCubic
          }
        }
        transform: Translate {
          x: (1 - homePage.opacity) * -Style.space(40)
        }
        width: parent.width
        spacing: Style.space(6)

        SectionTitle {
          width: parent.width
          text: "Pinned"
          action: "All apps  ›"
          onActionClicked: root.page = "all"
        }
        Grid {
          id: pinnedGrid
          columns: 6
          width: parent.width
          readonly property real cell: width / columns
          Repeater {
            model: root.pinnedApps
            AppTile {
              required property var modelData
              width: pinnedGrid.cell
              height: Style.space(84)
              entry: modelData
              onActivated: root.launch(modelData)
            }
          }
        }
        Label {
          visible: root.pinnedApps.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.6
          text: "Right-click an app in All apps to pin it here."
        }

        Item {
          width: 1
          height: Style.space(10)
        }

        SectionTitle {
          visible: root.recommended.length > 0
          width: parent.width
          text: "Recommended"
        }
        Grid {
          id: recGrid
          columns: 2
          width: parent.width
          // Whole rows only, in the room left above the footer.
          readonly property int rowHeight: Style.space(52)
          readonly property int room: Math.max(0, Math.floor((home.height - y) / rowHeight)) * columns
          Repeater {
            model: root.recommended.slice(0, recGrid.room)
            AppTile {
              required property var modelData
              width: recGrid.width / 2
              height: recGrid.rowHeight
              wide: true
              entry: modelData.entry
              subtitle: modelData.why
              onActivated: root.launch(modelData.entry)
            }
          }
        }
      }

      // All apps
      Item {
        id: allPage
        visible: opacity > 0
        opacity: root.page === "all" ? 1 : 0
        Behavior on opacity {
          enabled: root.pageMotion
          NumberAnimation {
            duration: Style.duration(root.animated ? 200 : 0)
            easing.type: Easing.OutCubic
          }
        }
        transform: Translate {
          x: (1 - allPage.opacity) * Style.space(40)
        }
        anchors.fill: parent
        SectionTitle {
          id: allTitle
          width: parent.width
          text: "All apps"
          action: "‹  Back"
          onActionClicked: root.page = "home"
        }
        AllAppsList {
          anchors.top: allTitle.bottom
          anchors.bottom: parent.bottom
          width: parent.width
        }
      }
    }

    // ----- Classic -----
    Item {
      visible: root.classic && root.query === ""
      anchors.top: searchBox.bottom
      anchors.topMargin: Style.space(10)
      anchors.bottom: parent.bottom
      x: Style.space(56)
      width: parent.width - x

      AllAppsList {
        id: classicList
        width: Math.round(parent.width * 0.55)
        height: parent.height
      }

      Column {
        anchors.left: classicList.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        spacing: Style.space(6)
        SectionTitle {
          width: parent.width
          text: "Pinned"
        }
        Grid {
          id: tiles
          columns: 3
          width: parent.width
          spacing: Style.space(4)
          readonly property real cell: (width - spacing * (columns - 1)) / columns
          Repeater {
            model: root.pinnedApps
            AppTile {
              required property var modelData
              width: tiles.cell
              height: tiles.cell
              color: Commons.Util.alpha(Commons.Color.accent, 0.18)
              entry: modelData
              onActivated: root.launch(modelData)
            }
          }
        }
      }
    }

    // Classic: user, settings and power down the left.
    Column {
      visible: root.classic
      anchors.bottom: parent.bottom
      width: Style.space(44)
      spacing: Style.space(4)
      Repeater {
        model: [
          { icon: "system-users", tip: Quickshell.env("USER") || "You", act: "" },
          { icon: "preferences-system", tip: "Settings", act: "settings" },
          { icon: "system-shutdown", tip: "Power", act: "power" }
        ]
        Rectangle {
          required property var modelData
          width: Style.space(44)
          height: width
          radius: Math.max(Style.cornerRadius, 4)
          color: sideMouse.containsMouse ? Style.hoverFill : "transparent"
          Image {
            anchors.centerIn: parent
            width: Style.space(22)
            height: width
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            source: Quickshell.iconPath(parent.modelData.icon, "application-x-executable")
          }
          MouseArea {
            id: sideMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (parent.modelData.act === "settings")
                root.openSettings()
              else if (parent.modelData.act === "power")
                root.powerOpen = !root.powerOpen
            }
          }
        }
      }
    }

    // Windows 11 footer: you on the left, settings and power on the right.
    Rectangle {
      id: footer
      visible: !root.classic
      anchors.bottom: parent.bottom
      width: parent.width
      height: Style.space(48)
      color: "transparent"
      Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: 1
        color: Commons.Color.popups.border
        opacity: 0.4
      }
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)
        Rectangle {
          width: Style.space(30)
          height: width
          radius: width / 2
          color: Commons.Util.alpha(Commons.Color.accent, 0.25)
          Label {
            anchors.centerIn: parent
            text: String(Quickshell.env("USER") || "?").charAt(0).toUpperCase()
            font.bold: true
          }
        }
        Label {
          anchors.verticalCenter: parent.verticalCenter
          text: Quickshell.env("USER") || ""
        }
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        Repeater {
          model: [{ icon: "preferences-system", act: "settings" }, { icon: "system-shutdown", act: "power" }]
          Rectangle {
            required property var modelData
            width: Style.space(36)
            height: width
            radius: Math.max(Style.cornerRadius, 4)
            color: footMouse.containsMouse ? Style.hoverFill : "transparent"
            Image {
              anchors.centerIn: parent
              width: Style.space(20)
              height: width
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: Quickshell.iconPath(parent.modelData.icon, "application-x-executable")
            }
            MouseArea {
              id: footMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: parent.modelData.act === "settings" ? root.openSettings() : (root.powerOpen = !root.powerOpen)
            }
          }
        }
      }
    }

    // Power choices, over the bottom of the menu.
    Rectangle {
      visible: root.powerOpen
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.classic ? 0 : footer.height
      x: root.classic ? Style.space(52) : parent.width - width
      width: Style.space(190)
      height: powerColumn.implicitHeight + Style.space(12)
      radius: Math.max(Style.cornerRadius, 6)
      color: Commons.Color.popups.background
      border.color: Commons.Color.popups.border
      border.width: 1
      Column {
        id: powerColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(12)
        Repeater {
          model: [
            { id: "lock", text: "Lock" },
            { id: "suspend", text: "Sleep" },
            { id: "logout", text: "Sign out" },
            { id: "reboot", text: "Restart" },
            { id: "shutdown", text: "Shut down" }
          ]
          Rectangle {
            required property var modelData
            width: powerColumn.width
            height: Style.space(34)
            radius: Math.max(Style.cornerRadius, 4)
            color: powerMouse.containsMouse ? Style.hoverFill : "transparent"
            Label {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(10)
              text: parent.modelData.text
            }
            MouseArea {
              id: powerMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.power(parent.modelData.id)
            }
          }
        }
      }
    }

    // Right-click on an app: pin or unpin.
    Rectangle {
      visible: root.pinTarget !== null
      x: Math.min(root.pinAt.x, card.width - width)
      y: Math.min(root.pinAt.y, card.height - height)
      width: Style.space(200)
      height: pinColumn.implicitHeight + Style.space(12)
      radius: Math.max(Style.cornerRadius, 6)
      color: Commons.Color.popups.background
      border.color: Commons.Color.popups.border
      border.width: 1
      z: 10
      Column {
        id: pinColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(12)
        Repeater {
          model: {
            var e = root.pinTarget
            if (!e || !root.settings)
              return []
            var start = (root.settings.get("start.pinned", []) || []).indexOf(e.id) >= 0
            var bar = (root.settings.get("taskbar.pinned", []) || []).indexOf(e.id) >= 0
            return [
              { list: "start.pinned", text: start ? "Unpin from Start" : "Pin to Start" },
              { list: "taskbar.pinned", text: bar ? "Unpin from taskbar" : "Pin to taskbar" }
            ]
          }
          Rectangle {
            required property var modelData
            width: pinColumn.width
            height: Style.space(34)
            radius: Math.max(Style.cornerRadius, 4)
            color: pinMouse.containsMouse ? Style.hoverFill : "transparent"
            Label {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(10)
              text: parent.modelData.text
            }
            MouseArea {
              id: pinMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.togglePin(parent.modelData.list, root.pinTarget)
                root.pinTarget = null
              }
            }
          }
        }
      }
    }
  }
}
