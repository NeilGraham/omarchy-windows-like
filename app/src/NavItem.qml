import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A category in the navigation: an icon and a name, and while it's the
// current one a lighter background with the accent's bar at its start.
ItemDelegate {
    id: item
    property string label
    property string iconPath
    property bool current: false

    readonly property color tint: Material.foreground

    Layout.fillWidth: true
    implicitHeight: 40
    Accessible.name: label
    leftPadding: 16
    rightPadding: 12

    background: Rectangle {
        radius: Math.min(6, theme.radius)
        color: Qt.rgba(item.tint.r, item.tint.g, item.tint.b,
                       item.current ? 0.08 : item.down ? 0.04 : item.hovered ? 0.05 : 0)
        border.width: item.visualFocus ? 2 : 0
        border.color: theme.accent

        Rectangle {
            visible: item.current
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 3
            height: 16
            radius: 1.5
            color: theme.accent
        }
    }

    contentItem: RowLayout {
        spacing: 14
        Icon {
            path: item.iconPath
            color: theme.accent
            size: 18
        }
        Label {
            Layout.fillWidth: true
            text: item.label
            font.pixelSize: 14
            elide: Text.ElideRight
        }
    }
}
