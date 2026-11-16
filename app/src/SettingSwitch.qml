import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One setting: a title, a line on what it does, and a switch bound to a
// settings path such as "snapping.edges".
ItemDelegate {
    id: row
    required property string path
    required property string title
    property string description: ""

    readonly property bool enabledValue: {
        backend.settings
        return backend.value(row.path) === true
    }

    Layout.fillWidth: true
    padding: 12
    Material.roundedScale: theme.radius
    onClicked: backend.setValue(row.path, !row.enabledValue)

    contentItem: RowLayout {
        spacing: 16
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Label {
                Layout.fillWidth: true
                text: row.title
                font.pixelSize: 15
                wrapMode: Text.WordWrap
            }
            Label {
                Layout.fillWidth: true
                visible: row.description !== ""
                text: row.description
                opacity: 0.6
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }
        }
        Switch {
            checked: row.enabledValue
            onToggled: backend.setValue(row.path, checked)
        }
    }
}
