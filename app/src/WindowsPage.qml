import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

SettingsPage {
    pageId: "package/windows"
    parentId: "package"
    title: qsTr("Windows & tabs")

    SectionHeader { text: qsTr("Workspace modes") }
    SettingChoice {
        path: "workspaces.startMode"
        title: qsTr("Starting mode")
        description: qsTr("Press Super + Shift + F12 to toggle the focused workspace. The choice is remembered across logins.")
        options: [
            { value: "native", label: qsTr("Default Omarchy") },
            { value: "windows-like", label: qsTr("Windows-like") }
        ]
    }
    SettingChoice {
        path: "workspaces.scope"
        title: qsTr("Apply the starting mode to")
        description: qsTr("Workspaces outside the selection start in Default Omarchy. Changing the starting mode or selection resets saved toggles.")
        options: [
            { value: "all", label: qsTr("All workspaces") },
            { value: "selected", label: qsTr("Selected workspaces") }
        ]
    }
    SettingsCard {
        id: workspaceNumbers
        visible: {
            backend.settings
            return backend.value("workspaces.scope") === "selected"
        }
        searchable: visible
        title: qsTr("Workspace numbers")
        description: qsTr("Enter workspace numbers separated by commas, such as 1, 3, 5.")

        TextField {
            id: numbers
            Layout.preferredWidth: 180
            Accessible.name: workspaceNumbers.title
            text: {
                backend.settings
                return (backend.value("workspaces.selected") || []).join(", ")
            }
            validator: RegularExpressionValidator {
                regularExpression: /\s*(?:[1-9][0-9]*(?:\s*,\s*[1-9][0-9]*)*)?\s*/
            }
            onEditingFinished: {
                if (!acceptableInput)
                    return
                const ids = text.trim() === "" ? [] : text.split(",").map(Number)
                if (ids.some(id => id > 2147483647)) {
                    text = (backend.value("workspaces.selected") || []).join(", ")
                    return
                }
                backend.setValue("workspaces.selected", [...new Set(ids)].sort((a, b) => a - b))
            }
        }
    }

    SectionHeader { text: qsTr("Windows") }
    SettingSwitch {
        path: "general.floatingDefault"
        title: qsTr("Floating windows by default")
        description: qsTr("New windows float on Windows-like workspaces. Super + L still changes the focused workspace layout.")
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
