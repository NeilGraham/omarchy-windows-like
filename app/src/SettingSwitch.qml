import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A setting that's on or off, bound to a settings path such as
// "snapping.edges". The whole card toggles it, and so does Space.
SettingsCard {
    id: row
    required property string path

    readonly property bool enabledValue: {
        backend.settings
        return backend.value(row.path) === true
    }

    clickable: true
    onClicked: backend.setValue(row.path, !row.enabledValue)

    // "On" or "Off" beside the switch, as Windows writes it.
    Label {
        text: row.enabledValue ? qsTr("On") : qsTr("Off")
        opacity: 0.8
    }
    Switch {
        checked: row.enabledValue
        focusPolicy: Qt.NoFocus
        onToggled: backend.setValue(row.path, checked)
    }
}
