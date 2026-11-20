import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

SettingsPage {
    pageId: "package/taskbar"
    parentId: "package"
    title: qsTr("Taskbar & Start")

    SettingSwitch {
        path: "taskbar.enabled"
        title: qsTr("Windows-style taskbar")
        description: qsTr("Omarchy's bar becomes a taskbar with a Start button and your apps. Off brings the original bar and the dock back.")
    }

    SectionHeader { text: qsTr("Taskbar appearance") }
    SettingChoice {
        path: "taskbar.style"
        title: qsTr("Style")
        description: qsTr("Windows 11 centers the apps; classic keeps them at the left.")
        options: [{ value: "windows11", label: qsTr("Windows 11") }, { value: "classic", label: qsTr("Classic") }]
    }
    SettingChoice {
        path: "taskbar.position"
        title: qsTr("Position")
        options: [{ value: "bottom", label: qsTr("Bottom") }, { value: "top", label: qsTr("Top") }]
    }
    SettingSlider {
        path: "taskbar.height"
        title: qsTr("Height")
        from: 32
        to: 64
        stepSize: 2
        fallback: 44
        unit: "px"
    }
    SettingSwitch {
        path: "taskbar.showDesktops"
        title: qsTr("Show desktops")
        description: qsTr("Next to Start: the number of the desktop you're on. Click it to switch desktops, add one, or rename them.")
    }
    SettingSwitch {
        path: "taskbar.showWorkspaces"
        title: qsTr("Show workspaces")
        description: qsTr("Omarchy's row of workspace numbers, at the left of the taskbar. Desktops, next to Start, does the same job.")
    }
    SettingSwitch {
        path: "taskbar.showLabels"
        title: qsTr("Show window titles on taskbar buttons")
    }

    SectionHeader { text: qsTr("Start") }
    SettingSwitch {
        path: "start.superOpens"
        title: qsTr("Super opens Start")
        description: qsTr("Tap Super on its own. Super with another key still does what it always did.")
    }
    SettingSwitch {
        path: "start.showRecent"
        title: qsTr("Show recently used apps")
    }
    SettingSwitch {
        path: "start.showRecentlyInstalled"
        title: qsTr("Show recently installed apps")
    }

    SectionHeader { text: qsTr("Pinned apps") }
    PinnedList {
        path: "taskbar.pinned"
        title: qsTr("Taskbar")
    }
    PinnedList {
        path: "start.pinned"
        title: qsTr("Start")
    }
}
