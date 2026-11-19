import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Shapes
import "Icons.js" as Icons

// This PC, like Windows 11's: the user's folders, then devices and drives
// with the space on each, then network locations. Double-click or Enter
// opens one in Files (mounting it first if need be); right-click or the Menu
// key offers Eject and Properties.
ApplicationWindow {
    id: win
    width: 1140
    height: 720
    minimumWidth: 400
    minimumHeight: 360
    visible: true
    title: qsTr("This PC")
    color: theme.window

    Material.theme: theme.dark ? Material.Dark : Material.Light
    Material.accent: theme.accent
    Material.background: theme.card
    Material.foreground: theme.foreground
    Material.roundedScale: theme.radius

    property bool helpVisible: false
    // The tile with the keyboard focus, by id, so a refresh that rebuilds the
    // tiles gives it back.
    property string focusedId: ""
    // What the menu and Properties are about.
    property var target: ({})

    readonly property color tint: Material.foreground

    readonly property var sections: [
        { title: qsTr("Folders"), items: drives.folders },
        { title: qsTr("Devices and drives"), items: drives.drives },
        { title: qsTr("Network locations"), items: drives.network }
    ]

    function tiles() {
        const out = []
        const walk = item => {
            for (let i = 0; i < item.children.length; ++i) {
                const child = item.children[i]
                if (child.isTile === true)
                    out.push(child)
                else
                    walk(child)
            }
        }
        walk(content)
        return out
    }

    // Arrow keys: along the row with Left and Right (on to the next row at
    // the end), and to the nearest tile above or below with Up and Down.
    function move(from, key) {
        const all = tiles()
        const index = all.indexOf(from)
        if (key === Qt.Key_Left || key === Qt.Key_Right) {
            const step = (key === Qt.Key_Right) !== (Qt.application.layoutDirection === Qt.RightToLeft) ? 1 : -1
            focusTile(all[Math.max(0, Math.min(all.length - 1, index + step))])
            return
        }
        const center = t => t.mapToItem(content, t.width / 2, t.height / 2)
        const here = center(from)
        let best = null, bestScore = Infinity
        for (const t of all) {
            const there = center(t)
            const dy = key === Qt.Key_Down ? there.y - here.y : here.y - there.y
            if (dy < from.height / 2)
                continue
            const score = dy * 4 + Math.abs(there.x - here.x)
            if (score < bestScore) {
                best = t
                bestScore = score
            }
        }
        if (best)
            focusTile(best)
    }

    function focusTile(tile) {
        if (!tile)
            return
        tile.forceActiveFocus()
        // Scroll it into view.
        const flick = scroll.contentItem
        const y = tile.mapToItem(content, 0, 0).y
        if (y < flick.contentY)
            flick.contentY = Math.max(0, y - 40)
        else if (y + tile.height > flick.contentY + flick.height)
            flick.contentY = y + tile.height - flick.height + 16
    }

    function showMenu(tile, x, y) {
        target = tile.entry
        menu.popup(tile, x, y)
    }

    function showProperties(entry) {
        target = entry
        properties.open()
    }

    function kindName(item) {
        return ({ folder: qsTr("Folder"), system: qsTr("System drive"), drive: qsTr("Local disk"),
                  usb: qsTr("USB drive"), sdcard: qsTr("SD card"), optical: qsTr("Disc drive"),
                  phone: qsTr("Portable device"), network: qsTr("Network location") })[item.kind] || ""
    }

    function bytes(value) {
        return qsTr("%1 bytes").arg(Number(value).toLocaleString(Qt.locale(), "f", 0))
    }

    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; onActivated: win.helpVisible = !win.helpVisible }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; onActivated: Qt.quit() }
    Shortcut { sequence: "Esc"; context: Qt.ApplicationShortcut; enabled: win.helpVisible; onActivated: win.helpVisible = false }
    Shortcut { sequences: ["F5", "Ctrl+R"]; context: Qt.ApplicationShortcut; onActivated: drives.refresh() }
    // Right-to-left languages mirror the window; the Translator sets the
    // application's layout direction.
    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true

        ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: 24
            anchors.leftMargin: 28
            anchors.rightMargin: 12
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.rightMargin: 16
                Layout.bottomMargin: 8
                spacing: 12
                Icon {
                    path: Icons.display
                    color: theme.accent
                    size: 28
                }
                Label {
                    Layout.fillWidth: true
                    text: win.title
                    font.pixelSize: 28
                    font.bold: true
                    elide: Text.ElideRight
                }
                BusyIndicator {
                    visible: drives.busy
                    running: visible
                    implicitWidth: 24
                    implicitHeight: 24
                }
                ToolButton {
                    focusPolicy: Qt.NoFocus
                    Accessible.name: qsTr("Refresh")
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Refresh (F5)")
                    onClicked: drives.refresh()
                    contentItem: Item {
                        Icon {
                            anchors.centerIn: parent
                            path: Icons.refresh
                            color: Material.foreground
                            size: 18
                        }
                    }
                }
            }

            // What went wrong mounting, opening or ejecting.
            Rectangle {
                Layout.fillWidth: true
                Layout.rightMargin: 16
                Layout.topMargin: 4
                Layout.bottomMargin: 4
                visible: drives.error !== ""
                implicitHeight: errorRow.implicitHeight + 20
                radius: theme.radius
                readonly property color danger: theme.danger
                color: Qt.tint(theme.card, Qt.rgba(danger.r, danger.g, danger.b, 0.18))
                border.color: danger
                RowLayout {
                    id: errorRow
                    anchors.fill: parent
                    anchors.margins: 10
                    anchors.leftMargin: 12
                    spacing: 12
                    Icon {
                        path: Icons.info
                        color: theme.danger
                        size: 20
                    }
                    Label {
                        Layout.fillWidth: true
                        text: drives.error
                        wrapMode: Text.WordWrap
                    }
                    ToolButton {
                        focusPolicy: Qt.NoFocus
                        implicitWidth: 32
                        implicitHeight: 32
                        Accessible.name: qsTr("Dismiss")
                        onClicked: drives.clearError()
                        contentItem: Item {
                            Icon {
                                anchors.centerIn: parent
                                path: Icons.close
                                color: Material.foreground
                                size: 14
                            }
                        }
                    }
                }
            }

            ScrollView {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                contentHeight: content.implicitHeight + 24
                clip: true

                ColumnLayout {
                    id: content
                    width: scroll.availableWidth - 16
                    spacing: 4

                    Repeater {
                        model: win.sections
                        ColumnLayout {
                            id: section
                            required property var modelData
                            Layout.fillWidth: true
                            visible: modelData.items.length > 0
                            spacing: 6

                            SectionHeader {
                                text: section.modelData.title
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 6
                                Repeater {
                                    model: section.modelData.items
                                    Tile {
                                        id: tile
                                        required property var modelData
                                        entry: modelData
                                        Keys.onLeftPressed: win.move(tile, Qt.Key_Left)
                                        Keys.onRightPressed: win.move(tile, Qt.Key_Right)
                                        Keys.onUpPressed: win.move(tile, Qt.Key_Up)
                                        Keys.onDownPressed: win.move(tile, Qt.Key_Down)
                                        onActivated: drives.open(entry)
                                        onMenuRequested: (x, y) => win.showMenu(tile, x, y)
                                        onPropertiesRequested: win.showProperties(entry)
                                        onActiveFocusChanged: if (activeFocus) win.focusedId = entry.id
                                    }
                                }
                            }
                        }
                    }

                    Label {
                        visible: drives.drives.length === 0 && drives.network.length === 0
                        Layout.topMargin: 20
                        text: qsTr("No drives found.")
                        opacity: 0.6
                    }
                }
            }

            Label {
                Layout.topMargin: 6
                Layout.bottomMargin: 10
                text: qsTr("? for shortcuts")
                opacity: 0.5
            }
        }

        // A refresh rebuilds the tiles: give the focus back to the same one
        // (the first one, the first time), unless a menu or dialog has it.
        Connections {
            target: drives
            function onChanged() {
                Qt.callLater(() => {
                    if (menu.visible || properties.visible || win.helpVisible)
                        return
                    const all = win.tiles()
                    win.focusTile(all.find(t => t.entry.id === win.focusedId) || all[0])
                })
            }
        }

        Menu {
            id: menu
            MenuItem {
                text: win.target.mounted === false && !win.target.locked ? qsTr("Mount and open") : qsTr("Open")
                font.bold: true
                onTriggered: drives.open(win.target)
            }
            MenuItem {
                // Removable drives only, as in Windows.
                visible: win.target.removable === true && (win.target.mounted === true || win.target.cryptDevice !== "")
                height: visible ? implicitHeight : 0
                text: qsTr("Eject")
                onTriggered: drives.eject(win.target)
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Properties")
                onTriggered: win.showProperties(win.target)
            }
        }

        // Properties, like a drive's General tab in Windows: what it is, and
        // the space used and free with the ring beside them.
        Dialog {
            id: properties
            anchors.centerIn: parent
            width: Math.min(460, parent.width - 32)
            modal: true
            padding: 24
            title: win.target.title || ""
            standardButtons: Dialog.Close

            ColumnLayout {
                width: parent.width
                spacing: 16

                RowLayout {
                    spacing: 14
                    Icon {
                        path: win.target.kind ? Icons.forItem(win.target) : ""
                        color: theme.accent
                        size: 36
                    }
                    Label {
                        Layout.fillWidth: true
                        text: win.kindName(win.target)
                        opacity: 0.7
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 20
                    rowSpacing: 6
                    Repeater {
                        // Label, then value: two cells per row; empty rows are left out.
                        model: {
                            const t = win.target
                            const rows = [
                                [qsTr("Location"), t.mounted ? t.path : qsTr("Not mounted")],
                                [qsTr("File system"), (t.fstype || "").toUpperCase()],
                                [qsTr("Device"), t.device || ""],
                                [qsTr("Disk"), t.model || ""],
                                [qsTr("Connection"), ({ nvme: "NVMe", sata: "SATA", usb: "USB", ata: "ATA", mmc: "SD/MMC",
                                                        scsi: "SCSI" })[t.connection] || (t.connection || "").toUpperCase()],
                                [qsTr("Server"), t.host || ""]
                            ]
                            return rows.filter(r => r[1] !== "" && t.kind !== "folder" || r[0] === qsTr("Location"))
                                       .reduce((cells, r) => cells.concat(r), [])
                        }
                        delegate: Label {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: index % 2 === 1
                            text: modelData
                            opacity: index % 2 === 0 ? 0.65 : 1
                            elide: Text.ElideMiddle
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: win.target.hasUsage === true
                    spacing: 24

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 3
                        columnSpacing: 12
                        rowSpacing: 6
                        Rectangle { width: 12; height: 12; color: win.target.nearlyFull ? theme.danger : theme.accent }
                        Label { text: qsTr("Used space"); opacity: 0.65 }
                        Label { Layout.fillWidth: true; text: win.target.usedText || ""; horizontalAlignment: Text.AlignRight }
                        Rectangle { width: 12; height: 12; color: Qt.rgba(win.tint.r, win.tint.g, win.tint.b, 0.2) }
                        Label { text: qsTr("Free space"); opacity: 0.65 }
                        Label { Layout.fillWidth: true; text: win.target.freeText || ""; horizontalAlignment: Text.AlignRight }
                        Item { width: 12; height: 12 }
                        Label { text: qsTr("Capacity"); font.bold: true }
                        Label { Layout.fillWidth: true; text: win.target.sizeText || ""; font.bold: true; horizontalAlignment: Text.AlignRight }
                    }

                    // Used space, as a ring.
                    Shape {
                        implicitWidth: 96
                        implicitHeight: 96
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: Qt.rgba(win.tint.r, win.tint.g, win.tint.b, 0.2)
                            strokeWidth: 16
                            fillColor: "transparent"
                            PathAngleArc { centerX: 48; centerY: 48; radiusX: 38; radiusY: 38; startAngle: 0; sweepAngle: 360 }
                        }
                        ShapePath {
                            strokeColor: win.target.nearlyFull ? theme.danger : theme.accent
                            strokeWidth: 16
                            fillColor: "transparent"
                            capStyle: ShapePath.FlatCap
                            PathAngleArc {
                                centerX: 48; centerY: 48; radiusX: 38; radiusY: 38
                                startAngle: -90
                                sweepAngle: 360 * (win.target.usedFraction || 0)
                            }
                        }
                    }
                }
            }
        }

        // Shortcuts
        Rectangle {
            anchors.fill: parent
            visible: win.helpVisible
            color: "#cc000000"
            MouseArea {
                anchors.fill: parent
                onClicked: win.helpVisible = false
            }
            Pane {
                anchors.centerIn: parent
                padding: 24
                Material.roundedScale: theme.radius
                GridLayout {
                    columns: 2
                    columnSpacing: 32
                    rowSpacing: 8
                    Repeater {
                        // Key, then what it does: two cells per row.
                        model: [
                            qsTr("Arrow keys"), qsTr("Move between folders and drives"),
                            "Enter", qsTr("Open (mounting the drive first)"),
                            "Menu, Shift + F10", qsTr("More: eject, properties"),
                            "Alt + Enter", qsTr("Properties"),
                            "F5", qsTr("Refresh"),
                            "?", qsTr("Show or hide these shortcuts"),
                            "Q", qsTr("Quit")
                        ]
                        delegate: Label {
                            required property var modelData
                            required property int index
                            text: modelData
                            font.bold: index % 2 === 0
                        }
                    }
                }
            }
        }
    }
}
