import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A choice between a few values, as a drop-down at the end of the card.
SettingsCard {
    id: choice
    required property string path
    required property var options // [{ value, label }]

    readonly property var current: {
        backend.settings
        return backend.value(choice.path)
    }

    ComboBox {
        Layout.preferredWidth: 180
        model: choice.options
        textRole: "label"
        valueRole: "value"
        currentIndex: choice.options.findIndex(o => o.value === choice.current)
        onActivated: backend.setValue(choice.path, currentValue)
    }
}
