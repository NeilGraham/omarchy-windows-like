import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

SettingsPage {
    pageId: "package/snapping"
    parentId: "package"
    title: qsTr("Snapping")

    SectionHeader { text: qsTr("Snap by dragging") }
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
        path: "snapping.topMaximizes"
        title: qsTr("Maximize at the top")
        description: qsTr("Drag a window to the top edge of the screen.")
    }
    SettingSwitch {
        path: "snapping.fillSpace"
        title: qsTr("Fill the space beside other windows")
        description: qsTr("Snapped next to a window that stands the full height (snapped, or stretched top to bottom), a window fills the room beside it instead of exactly half.")
    }
    SettingSwitch {
        path: "snapping.stretch"
        title: qsTr("Stretch to full height")
        description: qsTr("Drag a window's top or bottom border to the edge of the screen.")
    }
    SettingSwitch {
        path: "snapping.gaps"
        title: qsTr("Leave gaps between snapped windows")
        description: qsTr("Off, snapped windows meet each other and the edges of the screen, as on Windows. On, they keep the gaps set in Hyprland.")
    }
    SettingSwitch {
        path: "snapping.restoreSize"
        title: qsTr("Restore the size when dragged away")
        description: qsTr("A snapped window dragged off its spot gets its old size back.")
    }

    SectionHeader { text: qsTr("Snap layouts") }
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
}
