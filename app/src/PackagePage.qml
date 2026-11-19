import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "Icons.js" as Icons

// Package: what omarchy-windows-like changes, a card for each part leading
// to its own page, like Windows' Personalization.
SettingsPage {
    id: page
    pageId: "package"
    title: qsTr("Package")

    // The package itself, what it is and whether the last change took.
    SettingsCard {
        iconPath: Icons.package_
        title: "omarchy-windows-like"
        description: backend.error !== "" ? backend.error
                   : backend.status !== "" ? backend.status
                   : qsTr("Every change is saved and applied as you make it.")
        keywords: "reset defaults status"
        Button {
            text: qsTr("Reset to defaults")
            flat: true
            enabled: backend.installed
            Material.roundedScale: theme.radius
            onClicked: backend.resetToDefaults()
        }
    }

    // Search finds these pages themselves, so not their cards here too.
    SectionHeader { text: qsTr("Settings") }
    LinkCard {
        searchable: false
        iconPath: Icons.taskbar
        title: qsTr("Taskbar & Start")
        description: qsTr("Style, position and height, workspaces, Start, pinned apps")
        onClicked: page.navigate("package/taskbar")
    }
    LinkCard {
        searchable: false
        iconPath: Icons.snapping
        title: qsTr("Snapping")
        description: qsTr("Halves and quarters, snap layouts, snap assist, stretching")
        onClicked: page.navigate("package/snapping")
    }
    LinkCard {
        searchable: false
        iconPath: Icons.tabs
        title: qsTr("Windows & tabs")
        description: qsTr("Floating by default, resizing, tabs and their shortcuts, animations")
        onClicked: page.navigate("package/windows")
    }
}
