import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

SettingsPage {
    pageId: "package/windows"
    parentId: "package"
    title: qsTr("Windows & tabs")

    SectionHeader { text: qsTr("Windows") }
    SettingSwitch {
        path: "general.floatingDefault"
        title: qsTr("Floating windows by default")
        description: qsTr("New workspaces float like Windows instead of tiling. Super + L still switches one workspace.")
    }
    SettingSwitch {
        path: "resizing.sides"
        title: qsTr("Resize from any side")
        description: qsTr("Dragging a side resizes in that direction only, and the top edge above the title bar resizes too.")
    }
    SettingSwitch {
        path: "resizing.joint"
        title: qsTr("Resize snapped windows together")
        description: qsTr("Windows side by side (or one above another) share the edge between them: drag it and both resize. The cursor shows a split arrow there.")
    }

    SectionHeader { text: qsTr("Tabs") }
    SettingSwitch {
        path: "tabs.enabled"
        title: qsTr("Tabs")
        description: qsTr("Tabs in the title bar for any window, with close buttons, + and scrolling.")
    }
    SettingSwitch {
        path: "tabs.terminalShortcuts"
        title: qsTr("Mac Terminal shortcuts in foot")
        description: qsTr("Ctrl + T, Ctrl + W, Ctrl + 1 to 9 and Ctrl + Tab. Other apps keep these keys.")
    }
    SettingSwitch {
        path: "tabs.terminalNames"
        title: qsTr("Name terminal tabs after what runs in them")
        description: qsTr("The folder, or the program running, instead of the window title.")
    }

    // Where Windows has it: Accessibility > Visual effects.
    SectionHeader { text: qsTr("Visual effects") }
    SettingSwitch {
        path: "animations.enabled"
        title: qsTr("Animation effects")
        description: qsTr("Snapped windows glide into place, the snap preview and layouts fade in and out, and Start slides up from the taskbar. Off, they appear at once.")
        keywords: "animations motion movement fade slide reduce visual effects"
    }
}
