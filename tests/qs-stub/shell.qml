import QtQuick
import Quickshell
import Quickshell.Wayland

// Runs WindowsLike.qml on its own, outside Omarchy's shell, for tests.
// OWL_TEST_TASKBAR=<px> adds a stand-in taskbar: a bottom layer surface that
// reserves that much space, as Omarchy's bar does.
ShellRoot {
    WindowsLike {}

    Variants {
        model: Quickshell.env("OWL_TEST_TASKBAR") ? Quickshell.screens : []
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors {
                left: true
                right: true
                bottom: true
            }
            implicitHeight: Number(Quickshell.env("OWL_TEST_TASKBAR"))
            exclusiveZone: implicitHeight
            color: "#334455"
            WlrLayershell.namespace: "owl-test-taskbar"
        }
    }
}
