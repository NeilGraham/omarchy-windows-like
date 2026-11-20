import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "Icons.js" as Icons
import "DisplayLayout.js" as Layouts

// Display, as Windows 11 lays it out, with everything on the one page (no
// advanced settings behind another): the displays where they stand, to pick
// one and drag them into place; how several are used (extend, duplicate,
// one only); and the picked display's scale, resolution, orientation,
// refresh rate, variable refresh rate, HDR and color, and what it is.
//
// Changes apply at once. One that can leave a screen blank asks to be kept,
// and goes back by itself after 15 seconds (Monitors in monitors.cpp).
SettingsPage {
    id: page
    pageId: "display"
    title: qsTr("Display")

    // Every display, numbered as Windows numbers them.
    readonly property var list: monitors.monitors.map((m, i) => Object.assign({ number: i + 1 }, m))
    property string selectedName: ""
    readonly property var selected: list.find(m => m.name === selectedName)
        || list.find(m => m.focused && !m.disabled) || list.find(m => !m.disabled) || list[0] || null
    readonly property var cfg: selected ? selected.config : null
    readonly property bool selectedOn: !!selected && !selected.disabled
    // The displays with a place of their own on the desktop.
    readonly property var placed: list.filter(m => !m.disabled && m.mirrorOf === "")
    // Bumped after every change, so a control a change didn't take goes
    // back to what the display really has.
    property int revision: 0

    function numberOf(name) {
        const m = list.find(m => m.name === name)
        return m ? m.number : 0
    }

    function apply(configs, confirm) {
        if (configs.length > 0)
            monitors.apply(configs, confirm)
        revision++
    }

    function set(values, confirm) {
        if (selected)
            apply(Layouts.change(monitors.monitors, selected.name, values), confirm)
    }

    function hz(value) {
        return qsTr("%1 Hz").arg(Number(value).toLocaleString(Qt.locale(), "f", 2).replace(/[.,]?0+$/, ""))
    }

    // ---------- Controls ----------

    // A drop-down at the end of a card.
    component ChoiceCard: SettingsCard {
        id: choiceCard
        property var options: [] // [{ value, label }]
        property var current
        signal chosen(var value)

        ComboBox {
            Layout.preferredWidth: 300
            model: choiceCard.options
            textRole: "label"
            valueRole: "value"
            currentIndex: { page.revision; return choiceCard.options.findIndex(o => o.value === choiceCard.current) }
            onActivated: if (currentValue !== choiceCard.current) choiceCard.chosen(currentValue)
        }
    }

    // A switch at the end of a card; the whole card toggles it.
    component SwitchCard: SettingsCard {
        id: switchCard
        property bool on: false
        signal switched(bool on)
        clickable: true
        onClicked: switched(!on)
        Label {
            text: switchCard.on ? qsTr("On") : qsTr("Off")
            opacity: 0.8
        }
        Switch {
            checked: { page.revision; return switchCard.on }
            focusPolicy: Qt.NoFocus
            onToggled: switchCard.switched(checked)
        }
    }

    // A slider whose value is applied when it's let go.
    component SliderCard: SettingsCard {
        id: sliderCard
        property real from: 0
        property real to: 1
        property real stepSize: 0.05
        property real value: 0
        property string suffix: ""
        signal committed(real value)
        Label {
            text: Number(slider.value).toLocaleString(Qt.locale(), "f", 2) + sliderCard.suffix
            opacity: 0.8
        }
        Slider {
            id: slider
            Layout.preferredWidth: 200
            from: sliderCard.from
            to: sliderCard.to
            stepSize: sliderCard.stepSize
            value: { page.revision; return sliderCard.value }
            onPressedChanged: if (!pressed && Math.abs(value - sliderCard.value) > 0.001) sliderCard.committed(value)
        }
    }

    // ---------- Keep these display settings? ----------

    Dialog {
        id: keepDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.NoAutoClose
        title: qsTr("Keep these display settings?")
        width: 440
        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Reverting to the previous display settings in %n second(s).", "", monitors.secondsLeft)
        }
        footer: DialogButtonBox {
            Button {
                text: qsTr("Keep changes")
                highlighted: true
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
            Button {
                text: qsTr("Revert")
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            }
        }
        onAccepted: monitors.keep()
        onRejected: monitors.revert()
        // Opened and closed by the change, which also ends on its own.
        Connections {
            target: monitors
            function onConfirmChanged() {
                if (monitors.confirming && !keepDialog.opened)
                    keepDialog.open()
                else if (!monitors.confirming && keepDialog.opened)
                    keepDialog.close()
            }
        }
    }

    // ---------- Problems ----------

    // Hyprland isn't there to ask, or didn't answer.
    SettingsCard {
        visible: !monitors.available
        searchable: !monitors.available
        iconPath: Icons.info
        title: qsTr("No displays to show")
        description: monitors.error
    }
    // A change Hyprland didn't take, or a save that failed.
    SettingsCard {
        visible: monitors.applyError !== ""
        searchable: false
        iconPath: Icons.info
        title: qsTr("That didn't work")
        description: monitors.applyError
    }

    // ---------- Where they stand ----------

    Rectangle {
        id: arrangementCard
        Layout.fillWidth: true
        Layout.preferredHeight: offRow.visible ? 300 : 240
        visible: page.list.length > 0
        radius: theme.radius
        color: theme.card
        border.color: Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.06)

        // The ones on, where they are.
        Item {
            id: arrangement
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: offRow.visible ? offRow.top : parent.bottom
            anchors.margins: 28
            readonly property var rects: page.placed.map(m => Object.assign({ m: m }, Layouts.rect(m.config)))
            readonly property real minX: Math.min(...rects.map(r => r.x))
            readonly property real minY: Math.min(...rects.map(r => r.y))
            readonly property real spanX: Math.max(...rects.map(r => r.x + r.w)) - minX
            readonly property real spanY: Math.max(...rects.map(r => r.y + r.h)) - minY
            // Room to drag a display beside the others.
            readonly property real fit: rects.length === 0 ? 1
                : Math.min(width / Math.max(1, spanX * (rects.length > 1 ? 1.15 : 1)), height / Math.max(1, spanY * (rects.length > 1 ? 1.15 : 1)))
            readonly property real offsetX: (width - spanX * fit) / 2
            readonly property real offsetY: (height - spanY * fit) / 2

            Repeater {
                model: arrangement.rects

                Rectangle {
                    id: screenRect
                    required property var modelData
                    readonly property var m: modelData.m
                    readonly property bool picked: page.selected && (page.selected.name === m.name || page.selected.mirrorOf === m.name)
                    // Displays showing a copy of this one share its picture: "1 | 2".
                    readonly property var copies: page.list.filter(o => !o.disabled && o.mirrorOf === m.name)
                    readonly property real gap: 2
                    property bool dragging: false
                    x: dragging ? x : arrangement.offsetX + (modelData.x - arrangement.minX) * arrangement.fit + gap
                    y: dragging ? y : arrangement.offsetY + (modelData.y - arrangement.minY) * arrangement.fit + gap
                    z: dragging ? 2 : picked ? 1 : 0
                    width: modelData.w * arrangement.fit - 2 * gap
                    height: modelData.h * arrangement.fit - 2 * gap
                    radius: Math.min(6, theme.radius)
                    color: picked ? theme.accent : Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, dragArea.containsMouse ? 0.2 : 0.12)
                    border.width: picked ? 0 : 1
                    border.color: Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.25)
                    opacity: dragging ? 0.85 : 1

                    Label {
                        anchors.centerIn: parent
                        text: [screenRect.m.number].concat(screenRect.copies.map(o => o.number)).join(" | ")
                        font.pixelSize: Math.max(14, Math.min(40, parent.height / 3))
                        font.bold: true
                        color: screenRect.picked ? theme.accentForeground : Material.foreground
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: page.placed.length > 1 ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.PointingHandCursor
                        drag.target: page.placed.length > 1 ? screenRect : null
                        drag.threshold: 6
                        onPressed: page.selectedName = screenRect.m.name
                        onPositionChanged: if (drag.active) screenRect.dragging = true
                        onReleased: {
                            if (!screenRect.dragging)
                                return
                            // Back to desktop pixels; it lands against the nearest display.
                            const dx = (screenRect.x - screenRect.gap - arrangement.offsetX) / arrangement.fit + arrangement.minX
                            const dy = (screenRect.y - screenRect.gap - arrangement.offsetY) / arrangement.fit + arrangement.minY
                            screenRect.dragging = false
                            page.apply(Layouts.move(monitors.monitors, screenRect.m.name, dx, dy), false)
                        }
                    }
                }
            }
        }

        // The ones that are off: smaller, greyed, along the bottom.
        Row {
            id: offRow
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 16
            spacing: 10
            visible: page.list.some(m => m.disabled)

            Label {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Off")
                opacity: 0.55
                font.pixelSize: 13
            }

            Repeater {
                model: page.list.filter(m => m.disabled)

                Rectangle {
                    id: offRect
                    required property var modelData
                    readonly property bool picked: page.selected && page.selected.name === modelData.name
                    readonly property var size: Layouts.rect(modelData.config)
                    height: 40
                    width: Math.max(40, Math.min(110, height * size.w / Math.max(1, size.h)))
                    radius: Math.min(4, theme.radius)
                    color: "transparent"
                    border.width: picked ? 2 : 1
                    border.color: picked ? theme.accent : Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.3)
                    opacity: picked ? 0.9 : offMouse.containsMouse ? 0.7 : 0.45

                    Label {
                        anchors.centerIn: parent
                        text: offRect.modelData.number
                        font.bold: true
                        font.pixelSize: 15
                    }
                    MouseArea {
                        id: offMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.selectedName = offRect.modelData.name
                    }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        visible: page.list.length > 0
        Label {
            Layout.fillWidth: true
            text: page.placed.length > 1
                ? qsTr("Select a display to change its settings. Drag displays to rearrange them.")
                : qsTr("Select a display to change its settings.")
            opacity: 0.65
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
        Button {
            text: qsTr("Detect")
            flat: true
            onClicked: monitors.refresh()
        }
    }

    // ---------- The display picked ----------

    SectionHeader {
        visible: page.selected !== null
        text: page.selected ? page.selected.number + "   " + page.selected.label : ""
    }

    // Windows' "multiple displays" choice, for this display.
    ChoiceCard {
        visible: page.list.length > 1 && page.selected !== null
        searchable: page.list.length > 1
        iconPath: Icons.display
        title: qsTr("Multiple displays")
        description: qsTr("Extend the desktop to this display, show a copy of another one on it, or turn it off.")
        keywords: "duplicate mirror extend disconnect show only second monitor projector"
        options: {
            if (!page.selected)
                return []
            const out = [{ value: "extend", label: qsTr("Extend desktop to this display") }]
            for (const o of page.placed)
                if (o.name !== page.selected.name)
                    out.push({ value: "dup:" + o.name, label: qsTr("Duplicate display %1").arg(o.number) })
            out.push({ value: "only", label: qsTr("Show only on this display") })
            if (page.placed.some(o => o.name !== page.selected.name))
                out.push({ value: "off", label: qsTr("Disconnect this display") })
            return out
        }
        current: !page.selected ? ""
            : page.selected.disabled ? "off"
            : page.selected.mirrorOf !== "" ? "dup:" + page.selected.mirrorOf
            : page.list.every(o => o.name === page.selected.name || o.disabled) ? "only"
            : "extend"
        onChosen: value => {
            const name = page.selected.name
            if (value === "extend")
                page.apply(Layouts.extend(monitors.monitors, name), true)
            else if (value === "only")
                page.apply(Layouts.showOnly(monitors.monitors, name), true)
            else if (value === "off")
                page.apply(Layouts.disconnect(monitors.monitors, name), true)
            else if (value.startsWith("dup:"))
                page.apply(Layouts.duplicate(monitors.monitors, name, value.slice(4)), true)
        }
    }

    SettingsCard {
        visible: page.selected !== null && page.selected.disabled
        searchable: false
        iconPath: Icons.info
        title: qsTr("This display is off")
        description: page.list.length > 1
            ? qsTr("Choose \"Extend desktop to this display\" or a duplicate above to turn it on.")
            : qsTr("Hyprland has turned it off.")
    }

    // ---------- Scale & layout ----------

    SectionHeader {
        visible: page.selectedOn
        text: qsTr("Scale & layout")
    }

    ChoiceCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Scale")
        description: qsTr("Change the size of text, apps, and other items")
        keywords: "zoom size dpi text bigger smaller"
        readonly property var recommended: page.selected ? Layouts.recommendedScale(page.selected) : null
        options: {
            const values = [1, 1.25, 1.5, 1.6, 1.75, 2, 2.25, 2.5, 3]
            const current = page.cfg ? Number(page.cfg.scale) : 1
            if (!values.some(v => Math.abs(v - current) < 0.001))
                values.push(current)
            values.sort((a, b) => a - b)
            return values.map(v => ({
                value: v,
                label: Math.round(v * 100) + "%" + (recommended !== null && Math.abs(v - recommended) < 0.001 ? qsTr(" (Recommended)") : "")
            }))
        }
        current: page.cfg ? (options.find(o => Math.abs(o.value - Number(page.cfg.scale)) < 0.001) || {}).value : undefined
        onChosen: value => page.set({ scale: value }, false)
    }

    ChoiceCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Display resolution")
        description: qsTr("Adjust the resolution to fit your connected display")
        keywords: "resolution size pixels mode"
        options: page.selected ? Layouts.resolutions(page.selected.modes).map((r, i) => ({
            value: r.width + "x" + r.height,
            label: qsTr("%1 × %2").arg(r.width).arg(r.height) + (i === 0 ? qsTr(" (Recommended)") : "")
        })) : []
        current: page.cfg ? page.cfg.width + "x" + page.cfg.height : ""
        onChosen: value => {
            const [w, h] = value.split("x").map(Number)
            page.set({ width: w, height: h, refresh: Layouts.closestRate(page.selected.modes, w, h, Number(page.cfg.refresh)) }, true)
        }
    }

    ChoiceCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Display orientation")
        keywords: "rotate rotation portrait landscape flipped turn"
        options: [
            { value: 0, label: qsTr("Landscape") },
            { value: 1, label: qsTr("Portrait") },
            { value: 2, label: qsTr("Landscape (flipped)") },
            { value: 3, label: qsTr("Portrait (flipped)") }
        ]
        current: page.cfg ? Number(page.cfg.transform) % 4 : 0
        onChosen: value => page.set({ transform: value }, true)
    }

    // ---------- Refresh rate & color ----------

    SectionHeader {
        visible: page.selectedOn
        text: qsTr("Refresh rate & color")
    }

    ChoiceCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Choose a refresh rate")
        description: qsTr("A higher rate looks smoother, but also uses more power")
        keywords: "hz hertz fps frequency"
        options: page.cfg ? Layouts.rates(page.selected.modes, Number(page.cfg.width), Number(page.cfg.height))
            .map(r => ({ value: r, label: page.hz(r) })) : []
        current: page.cfg ? (options.find(o => Math.abs(o.value - Number(page.cfg.refresh)) < 0.02) || {}).value : undefined
        onChosen: value => page.set({ refresh: value }, true)
    }

    ChoiceCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Variable refresh rate")
        description: qsTr("Matches the refresh rate to what's on screen, for smoother games and video. Some displays flicker with it on.")
        keywords: "vrr freesync g-sync adaptive sync dynamic"
        options: [
            { value: 0, label: qsTr("Off") },
            { value: 1, label: qsTr("On") },
            { value: 2, label: qsTr("Only for full screen apps") }
        ]
        current: page.cfg ? Number(page.cfg.vrr) : 0
        onChosen: value => page.set({ vrr: value }, false)
    }

    SwitchCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("Use HDR")
        description: qsTr("Brighter, more vivid picture on a display that supports it")
        keywords: "hdr high dynamic range color brightness"
        on: page.cfg ? String(page.cfg.cm).startsWith("hdr") : false
        onSwitched: on => page.set(on ? { cm: "hdr", bitdepth: 10 } : { cm: "auto" }, true)
    }

    ChoiceCard {
        visible: page.selectedOn && page.cfg && String(page.cfg.cm).startsWith("hdr")
        searchable: false
        title: qsTr("HDR brightness range")
        description: qsTr("Where HDR takes the display's brightness from")
        options: [
            { value: "hdr", label: qsTr("Standard") },
            { value: "hdredid", label: qsTr("From the display (EDID)") }
        ]
        current: page.cfg ? String(page.cfg.cm) : ""
        onChosen: value => page.set({ cm: value }, true)
    }

    SliderCard {
        visible: page.selectedOn && page.cfg && String(page.cfg.cm).startsWith("hdr")
        searchable: false
        title: qsTr("SDR content brightness")
        description: qsTr("How bright apps and video that aren't HDR look")
        from: 0.5
        to: 3
        stepSize: 0.05
        suffix: "×"
        value: page.cfg ? Number(page.cfg.sdrBrightness) : 1
        onCommitted: value => page.set({ sdrBrightness: value }, false)
    }

    SliderCard {
        visible: page.selectedOn && page.cfg && String(page.cfg.cm).startsWith("hdr")
        searchable: false
        title: qsTr("SDR content color saturation")
        from: 0.5
        to: 1.5
        stepSize: 0.05
        suffix: "×"
        value: page.cfg ? Number(page.cfg.sdrSaturation) : 1
        onCommitted: value => page.set({ sdrSaturation: value }, false)
    }

    ChoiceCard {
        visible: page.selectedOn && page.cfg && !String(page.cfg.cm).startsWith("hdr")
        searchable: page.selectedOn
        title: qsTr("Color profile")
        description: qsTr("The colors the display is set up to show")
        keywords: "color gamut srgb p3 adobe wide calibration"
        options: [
            { value: "auto", label: qsTr("Automatic") },
            { value: "srgb", label: qsTr("sRGB") },
            { value: "edid", label: qsTr("From the display (EDID)") },
            { value: "wide", label: qsTr("Wide color (BT.2020)") },
            { value: "dcip3", label: qsTr("DCI-P3") },
            { value: "dp3", label: qsTr("Display P3") },
            { value: "adobe", label: qsTr("Adobe RGB") }
        ]
        current: page.cfg ? (options.some(o => o.value === page.cfg.cm) ? page.cfg.cm : "auto") : "auto"
        onChosen: value => page.set({ cm: value }, true)
    }

    SwitchCard {
        visible: page.selectedOn
        searchable: true
        title: qsTr("10-bit color")
        description: qsTr("Smoother gradients on a display and cable that support it")
        keywords: "bit depth 10bit color banding"
        on: page.cfg ? Number(page.cfg.bitdepth) === 10 : false
        onSwitched: on => page.set({ bitdepth: on ? 10 : 8 }, true)
    }

    // ---------- What it is ----------

    SectionHeader {
        visible: page.selected !== null
        text: qsTr("Display information")
    }

    SettingsCard {
        visible: page.selected !== null
        searchable: page.selected !== null
        iconPath: Icons.display
        title: page.selected ? page.selected.label : ""
        description: page.selected ? [page.selected.description !== page.selected.label ? page.selected.description : "",
                                      qsTr("Connected to %1").arg(page.selected.name)].filter(s => s !== "").join(" · ") : ""
        keywords: "information details model manufacturer serial connector size inches"

        below: GridLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 38
            columns: 2
            columnSpacing: 24
            rowSpacing: 6
            Repeater {
                model: {
                    const m = page.selected
                    if (!m)
                        return []
                    const inches = Layouts.diagonal(m)
                    const hdr = String(m.config.cm).startsWith("hdr")
                    const rows = [
                        [qsTr("Manufacturer"), m.make],
                        [qsTr("Model"), m.model],
                        [qsTr("Serial number"), m.serial],
                        [qsTr("Connector"), m.name],
                        [qsTr("Size"), inches > 0 ? qsTr("%1\" (%2 × %3 mm)").arg(inches).arg(m.physicalWidth).arg(m.physicalHeight) : ""],
                    ]
                    if (!m.disabled)
                        rows.push(
                            [qsTr("Desktop mode"), qsTr("%1 × %2").arg(m.width).arg(m.height) + ", " + page.hz(m.refreshRate)],
                            [qsTr("Desktop size"), qsTr("%1 × %2 at %3%").arg(m.logicalWidth).arg(m.logicalHeight).arg(m.scalePercent)],
                            [qsTr("Position"), m.mirrorOf !== "" ? qsTr("Copy of display %1").arg(page.numberOf(m.mirrorOf)) : m.x + ", " + m.y],
                            [qsTr("Color format"), m.format],
                            [qsTr("Bit depth"), qsTr("%1-bit").arg(m.bitdepth)],
                            [qsTr("Color space"), hdr ? qsTr("High dynamic range (HDR)") : qsTr("Standard dynamic range (SDR)")],
                            [qsTr("Variable refresh rate"), m.vrr ? qsTr("Active") : Number(m.config.vrr) > 0 ? qsTr("On, not active now") : qsTr("Off")])
                    else
                        rows.push([qsTr("Status"), qsTr("Off")])
                    return rows.filter(r => r[1] !== "" && r[1] !== undefined).reduce((all, r) => all.concat(r), [])
                }
                delegate: Label {
                    required property var modelData
                    required property int index
                    text: modelData
                    opacity: index % 2 === 0 ? 0.65 : 1
                    font.pixelSize: 13
                    Layout.fillWidth: index % 2 === 1
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
