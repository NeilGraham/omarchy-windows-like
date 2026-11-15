pragma Singleton
import QtQuick

// Stand-in for Omarchy's qs.Commons.Color, for tests only.
QtObject {
    property color background: "#1a1b26"
    property color accent: "#7aa2f7"
    readonly property QtObject popups: QtObject {
        property color background: "#1a1b26"
        property color text: "#c0caf5"
        property color border: "#7aa2f7"
    }
}
