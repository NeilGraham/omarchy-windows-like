import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 960
    height: 680
    minimumWidth: 720
    minimumHeight: 480
    visible: true
    title: qsTr("Windows-like Settings")
    color: "#0e0e10"

    Material.theme: Material.Dark
    Material.accent: theme.accent
    Material.roundedScale: theme.radius

    property bool helpVisible: false
    property int pageIndex: 0

    readonly property var pages: [
        { title: qsTr("Taskbar & Start"), key: "1" },
        { title: qsTr("Snapping"), key: "2" },
        { title: qsTr("Windows & tabs"), key: "3" }
    ]

    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; onActivated: win.helpVisible = !win.helpVisible }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; onActivated: Qt.quit() }
    Shortcut { sequence: "Esc"; context: Qt.ApplicationShortcut; onActivated: win.helpVisible = false }
    Shortcut { sequence: "Ctrl+1"; context: Qt.ApplicationShortcut; onActivated: win.pageIndex = 0 }
    Shortcut { sequence: "Ctrl+2"; context: Qt.ApplicationShortcut; onActivated: win.pageIndex = 1 }
    Shortcut { sequence: "Ctrl+3"; context: Qt.ApplicationShortcut; onActivated: win.pageIndex = 2 }
    Shortcut { sequence: "Ctrl+Tab"; context: Qt.ApplicationShortcut; onActivated: win.pageIndex = (win.pageIndex + 1) % win.pages.length }

    // A choice between a few values, as a row of buttons.
    component Choice: RowLayout {
        id: choice
        required property string path
        required property string title
        required property var options // [{ value, label }]
        Layout.fillWidth: true
        Layout.margins: 12
        spacing: 12
        readonly property var current: {
            backend.settings
            return backend.value(choice.path)
        }
        Label {
            Layout.fillWidth: true
            text: choice.title
            font.pixelSize: 15
        }
        Repeater {
            model: choice.options
            Button {
                required property var modelData
                text: modelData.label
                checkable: true
                checked: choice.current === modelData.value
                highlighted: checked
                flat: !checked
                Material.roundedScale: theme.radius
                onClicked: backend.setValue(choice.path, modelData.value)
            }
        }
    }

    component SectionLabel: Label {
        Layout.fillWidth: true
        Layout.topMargin: 16
        Layout.leftMargin: 12
        font.pixelSize: 13
        font.bold: true
        color: theme.accent
    }

    // A list of pinned apps, each with a remove button.
    component PinnedList: ColumnLayout {
        id: pins
        required property string path
        required property string title
        Layout.fillWidth: true
        Layout.margins: 12
        readonly property var items: {
            backend.settings
            return backend.value(pins.path) || []
        }
        Label {
            text: pins.title
            font.pixelSize: 15
        }
        Flow {
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
            }
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("Right-click an app in Start or on the taskbar to pin it.")
            opacity: 0.6
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }

    // Right-to-left languages mirror the window; the Translator sets the
    // application's layout direction.
    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // Pages
            Pane {
                Layout.preferredWidth: 220
                Layout.fillHeight: true
                padding: 12
                background: Rectangle { color: "#151517" }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 4

                    Label {
                        Layout.fillWidth: true
                        Layout.margins: 8
                        Layout.bottomMargin: 16
                        text: qsTr("Windows-like")
                        font.pixelSize: 18
                        font.bold: true
                    }

                    Repeater {
                        model: win.pages
                        ItemDelegate {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            // A lone & would mark a mnemonic.
                            text: modelData.title.replace(/&/g, "&&")
                            highlighted: win.pageIndex === index
                            Material.roundedScale: theme.radius
                            onClicked: win.pageIndex = index
                        }
                    }

                    Item { Layout.fillHeight: true }

                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Reset to defaults")
                        flat: true
                        Material.roundedScale: theme.radius
                        onClicked: backend.resetToDefaults()
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 24
                    currentIndex: win.pageIndex

                    SettingsPage {
                        heading: qsTr("Taskbar & Start")

                        SettingSwitch {
                            path: "taskbar.enabled"
                            title: qsTr("Windows-style taskbar")
                            description: qsTr("Omarchy's bar becomes a taskbar with a Start button and your apps. Off brings the original bar and the dock back.")
                        }
                        Choice {
                            path: "taskbar.style"
                            title: qsTr("Style")
                            options: [{ value: "windows11", label: qsTr("Windows 11") }, { value: "classic", label: qsTr("Classic") }]
                        }
                        Choice {
                            path: "taskbar.position"
                            title: qsTr("Position")
                            options: [{ value: "bottom", label: qsTr("Bottom") }, { value: "top", label: qsTr("Top") }]
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.margins: 12
                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Height")
                                font.pixelSize: 15
                            }
                            Slider {
                                id: heightSlider
                                from: 32
                                to: 64
                                stepSize: 2
                                value: { backend.settings; return backend.value("taskbar.height") || 44 }
                                onMoved: backend.setValue("taskbar.height", value)
                            }
                            Label {
                                text: Math.round(heightSlider.value) + " px"
                                Layout.preferredWidth: 48
                            }
                        }
                        SettingSwitch {
                            path: "taskbar.showWorkspaces"
                            title: qsTr("Show workspaces")
                            description: qsTr("Omarchy's workspace numbers, at the left of the taskbar.")
                        }
                        SettingSwitch {
                            path: "taskbar.showLabels"
                            title: qsTr("Show window titles on taskbar buttons")
                        }

                        SectionLabel { text: qsTr("Start") }
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

                        SectionLabel { text: qsTr("Pinned apps") }
                        PinnedList {
                            path: "taskbar.pinned"
                            title: qsTr("Taskbar")
                        }
                        PinnedList {
                            path: "start.pinned"
                            title: qsTr("Start")
                        }
                    }

                    SettingsPage {
                        heading: qsTr("Snapping")

                        SettingSwitch {
                            path: "snapping.edges"
                            title: qsTr("Snap to the left or right half")
                            description: qsTr("Drag a window to the left or right edge of the screen.")
                        }
                        SettingSwitch {
                            path: "snapping.corners"
                            title: qsTr("Snap to a quarter")
                            description: qsTr("Drag a window into a corner.")
                        }
                        SettingSwitch {
                            path: "snapping.fillSpace"
                            title: qsTr("Fill the space beside other windows")
                            description: qsTr("Snapped next to a window that stands the full height (snapped, or stretched top to bottom), a window fills the room beside it instead of exactly half.")
                        }
                        SettingSwitch {
                            path: "snapping.topMaximizes"
                            title: qsTr("Maximize at the top")
                            description: qsTr("Drag a window to the top edge of the screen.")
                        }
                        SettingSwitch {
                            path: "snapping.picker"
                            title: qsTr("Snap layouts")
                            description: qsTr("Drag a window to the top to pick a layout: halves, thirds, quarters and more.")
                        }
                        SettingSwitch {
                            path: "general.superZ"
                            title: qsTr("Super + Z opens snap layouts")
                        }
                        SettingSwitch {
                            path: "snapping.assist"
                            title: qsTr("Snap assist")
                            description: qsTr("After a window snaps, pick windows for the rest of the layout.")
                        }
                        SettingSwitch {
                            path: "snapping.stretch"
                            title: qsTr("Stretch to full height")
                            description: qsTr("Drag a window's top or bottom border to the edge of the screen.")
                        }
                        SettingSwitch {
                            path: "snapping.restoreSize"
                            title: qsTr("Restore the size when dragged away")
                            description: qsTr("A snapped window dragged off its spot gets its old size back.")
                        }
                    }

                    SettingsPage {
                        heading: qsTr("Windows & tabs")

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

                        SectionLabel { text: qsTr("Tabs") }
                        SettingSwitch {
                            path: "tabs.enabled"
                            title: qsTr("Tabs")
                            description: qsTr("A tab bar under the title bar once a window has a second tab, with close buttons, + and scrolling.")
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
                    }
                }

                // Status
                Pane {
                    Layout.fillWidth: true
                    padding: 10
                    background: Rectangle { color: "#151517" }
                    RowLayout {
                        anchors.fill: parent
                        BusyIndicator {
                            running: backend.applying
                            visible: running
                            implicitWidth: 24
                            implicitHeight: 24
                        }
                        Label {
                            Layout.fillWidth: true
                            text: backend.error !== "" ? backend.error : backend.status
                            color: backend.error !== "" ? "#ff6b6b" : Material.foreground
                            opacity: backend.error !== "" ? 1 : 0.7
                            elide: Text.ElideRight
                        }
                        Label {
                            text: qsTr("? for shortcuts")
                            opacity: 0.5
                        }
                    }
                }
            }
        }

        // Shortcuts
        Rectangle {
            anchors.fill: parent
            visible: win.helpVisible
            color: "#cc000000"
            MouseArea {
                anchors.fill: parent
                onClicked: win.helpVisible = false
            }
            Pane {
                anchors.centerIn: parent
                padding: 24
                Material.roundedScale: theme.radius
                GridLayout {
                    columns: 2
                    columnSpacing: 32
                    rowSpacing: 8
                    Repeater {
                        // Key, then what it does: two cells per row.
                        model: [
                            "Ctrl + 1, 2, 3", qsTr("Go to a page"),
                            "Ctrl + Tab", qsTr("Next page"),
                            "Space", qsTr("Toggle the focused setting"),
                            "?", qsTr("Show or hide these shortcuts"),
                            "Q", qsTr("Quit")
                        ]
                        delegate: Label {
                            required property var modelData
                            required property int index
                            text: modelData
                            font.bold: index % 2 === 0
                        }
                    }
                }
            }
        }
    }
}
