import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "Icons.js" as Icons

// One thing in This PC, as Windows draws it: a folder is an icon and a name;
// a drive adds a bar of the space used (red once it's 90 % full) and how
// much is free.
ItemDelegate {
    id: tile
    required property var entry
    readonly property bool isTile: true
    readonly property bool isFolder: entry.kind === "folder"
    readonly property color tint: Material.foreground
    readonly property color accent: theme.accent
    readonly property color barColor: entry.nearlyFull ? theme.danger : theme.accent

    signal activated()
    signal menuRequested(real x, real y)
    signal propertiesRequested()

    // One width for every tile, so folders and drives line up in columns.
    width: 352
    height: isFolder ? 60 : 84
    padding: 10
    focusPolicy: Qt.StrongFocus
    Accessible.name: entry.title

    onDoubleClicked: activated()
    // Enter opens, Alt + Enter shows Properties, and the Menu key or
    // Shift + F10 the menu, as in Windows' Explorer.
    Keys.onPressed: event => {
        const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        if (enter && (event.modifiers & Qt.AltModifier))
            propertiesRequested()
        else if (enter)
            activated()
        else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))
            menuRequested(width / 2, height / 2)
        else
            return
        event.accepted = true
    }

    // Right-click opens the menu where the pointer is.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => {
            tile.forceActiveFocus()
            tile.menuRequested(mouse.x, mouse.y)
        }
    }

    background: Rectangle {
        radius: Math.min(6, theme.radius)
        color: tile.activeFocus ? Qt.rgba(tile.accent.r, tile.accent.g, tile.accent.b, 0.16)
             : tile.hovered ? Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, 0.06)
             : "transparent"
        border.width: tile.activeFocus ? 1 : 0
        border.color: theme.accent
    }

    contentItem: RowLayout {
        spacing: 12
        Icon {
            Layout.alignment: Qt.AlignVCenter
            path: Icons.forItem(tile.entry)
            color: theme.accent
            size: tile.isFolder ? 32 : 44
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 4
            Label {
                Layout.fillWidth: true
                text: tile.entry.title
                font.pixelSize: 14
                elide: Text.ElideRight
            }
            // Space used
            Rectangle {
                Layout.fillWidth: true
                visible: tile.entry.hasUsage === true
                implicitHeight: 12
                color: Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(tile.tint.r, tile.tint.g, tile.tint.b, 0.18)
                Rectangle {
                    x: 1
                    y: 1
                    height: parent.height - 2
                    width: (parent.width - 2) * (tile.entry.usedFraction || 0)
                    color: tile.barColor
                }
            }
            Label {
                Layout.fillWidth: true
                visible: !tile.isFolder && text !== ""
                text: tile.entry.locked ? qsTr("Locked · %1").arg(tile.entry.sizeText)
                    : tile.entry.hasUsage ? qsTr("%1 free of %2").arg(tile.entry.freeText).arg(tile.entry.sizeText)
                    : !tile.entry.mounted ? qsTr("Not mounted · %1").arg(tile.entry.sizeText)
                    : tile.entry.kind === "phone" ? qsTr("Portable device")
                    : qsTr("Network share")
                font.pixelSize: 12
                opacity: 0.65
                elide: Text.ElideRight
            }
        }
    }
}
