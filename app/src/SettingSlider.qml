import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A number in a range, as a slider with its value beside it.
SettingsCard {
    id: row
    required property string path
    property real from: 0
    property real to: 100
    property real stepSize: 1
    property real fallback: from
    property string unit: ""

    Label {
        text: Math.round(slider.value) + (row.unit !== "" ? " " + row.unit : "")
        opacity: 0.8
    }
    Slider {
        id: slider
        Layout.preferredWidth: 200
        from: row.from
        to: row.to
        stepSize: row.stepSize
        value: { backend.settings; return backend.value(row.path) || row.fallback }
        onMoved: backend.setValue(row.path, value)
    }
}
