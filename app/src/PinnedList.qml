import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A list of pinned apps, each with a remove button.
SettingsCard {
    id: pins
    required property string path

    readonly property var items: {
        backend.settings
        return backend.value(pins.path) || []
    }

    description: qsTr("Right-click an app in Start or on the taskbar to pin it.")

    below: Flow {
        Layout.fillWidth: true
        spacing: 8
        Repeater {
            model: pins.items
            Button {
                required property var modelData
                text: backend.appName(modelData) + "   ✕"
                flat: true
                Material.roundedScale: Math.min(4, theme.radius)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Unpin %1").arg(backend.appName(modelData))
                onClicked: backend.removeFromList(pins.path, modelData)
            }
        }
        Label {
            visible: pins.items.length === 0
            text: qsTr("Nothing pinned")
            opacity: 0.6
            topPadding: 4
        }
    }
}
