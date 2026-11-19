import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "Icons.js" as Icons

// Display: the monitors Hyprland sees, read-only, and the way into Displays,
// the app that changes them. Without Displays the summary stays and the
// page says how else monitors are set.
SettingsPage {
    id: page
    pageId: "display"
    title: qsTr("Display")

    // The ones that show a picture of their own, each with its number.
    readonly property var shown: monitors.monitors.map((m, i) => Object.assign({ number: i + 1 }, m))
        .filter(m => !m.disabled && m.mirrorOf === "")

    function number(value, digits) {
        return Number(value).toLocaleString(Qt.locale(), "f", digits).replace(/[.,]?0+$/, "")
    }

    // The monitors where they stand, numbered as in the list below.
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 220
        visible: page.shown.length > 0
        radius: theme.radius
        color: theme.card
        border.color: Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.06)

        Item {
            id: arrangement
            anchors.fill: parent
            anchors.margins: 28
            readonly property real minX: Math.min(...page.shown.map(m => m.x))
            readonly property real minY: Math.min(...page.shown.map(m => m.y))
            readonly property real spanX: Math.max(...page.shown.map(m => m.x + m.logicalWidth)) - minX
            readonly property real spanY: Math.max(...page.shown.map(m => m.y + m.logicalHeight)) - minY
            readonly property real fit: Math.min(width / Math.max(1, spanX), height / Math.max(1, spanY))

            Repeater {
                model: page.shown
                Rectangle {
                    required property var modelData
                    readonly property real gap: 3
                    x: (arrangement.width - arrangement.spanX * arrangement.fit) / 2
                       + (modelData.x - arrangement.minX) * arrangement.fit + gap
                    y: (arrangement.height - arrangement.spanY * arrangement.fit) / 2
                       + (modelData.y - arrangement.minY) * arrangement.fit + gap
                    width: modelData.logicalWidth * arrangement.fit - 2 * gap
                    height: modelData.logicalHeight * arrangement.fit - 2 * gap
                    radius: Math.min(6, theme.radius)
                    color: modelData.focused ? theme.accent : Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.12)
                    Label {
                        anchors.centerIn: parent
                        text: parent.modelData.number
                        font.pixelSize: Math.max(14, Math.min(40, parent.height / 3))
                        font.bold: true
                        color: parent.modelData.focused ? theme.accentForeground : Material.foreground
                    }
                }
            }
        }
    }

    // Hyprland isn't there to ask, or didn't answer.
    SettingsCard {
        visible: !monitors.available
        searchable: !monitors.available
        iconPath: Icons.info
        title: qsTr("No displays to show")
        description: monitors.error
    }

    LinkCard {
        visible: monitors.displaysInstalled
        searchable: monitors.displaysInstalled
        external: true
        iconPath: Icons.display
        title: qsTr("Open Displays")
        description: qsTr("Change the resolution, refresh rate, scale and layout, and VRR and HDR.")
        keywords: "resolution refresh rate scale layout monitor hdr vrr"
        onClicked: monitors.openDisplays()
    }
    SettingsCard {
        visible: !monitors.displaysInstalled
        searchable: !monitors.displaysInstalled
        iconPath: Icons.info
        title: qsTr("Displays isn't installed")
        description: qsTr("Install the Displays app to change the resolution, refresh rate and scale from here. Until then, Hyprland takes them from ~/.config/hypr/monitors.lua.")
        keywords: "resolution refresh rate scale layout monitor"
    }

    SectionHeader {
        visible: monitors.monitors.length > 0
        text: qsTr("%n display(s) connected", "", monitors.monitors.length)
    }
    Repeater {
        model: monitors.monitors
        SettingsCard {
            required property var modelData
            required property int index
            iconPath: Icons.display
            title: (index + 1) + "   " + modelData.label
            description: [modelData.description !== modelData.label ? modelData.description : "", modelData.name]
                .filter(s => s !== "").join(" · ")
            keywords: "monitor screen resolution refresh rate scale"

            ColumnLayout {
                spacing: 2
                Label {
                    Layout.alignment: Qt.AlignRight
                    text: modelData.disabled ? qsTr("Off")
                        : qsTr("%1 × %2").arg(modelData.width).arg(modelData.height)
                    font.pixelSize: 15
                }
                Label {
                    Layout.alignment: Qt.AlignRight
                    visible: !modelData.disabled
                    text: modelData.mirrorOf !== "" ? qsTr("Mirrors %1").arg(modelData.mirrorOf)
                        : qsTr("%1 Hz").arg(page.number(modelData.refreshRate, 2)) + "  ·  "
                          + qsTr("%1% scale").arg(modelData.scalePercent)
                    opacity: 0.65
                    font.pixelSize: 13
                }
            }
        }
    }
}
