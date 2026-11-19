import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "Icons.js" as Icons

// Laid out like Windows 11's Settings: search and the categories down the
// left, the current page on the right under its title, its settings in cards.
ApplicationWindow {
    id: win
    width: 1040
    height: 720
    minimumWidth: 760
    minimumHeight: 500
    visible: true
    title: qsTr("Settings")
    color: theme.window

    Material.theme: theme.dark ? Material.Dark : Material.Light
    Material.accent: theme.accent
    Material.background: theme.card
    Material.foreground: theme.foreground
    Material.roundedScale: theme.radius

    property bool helpVisible: false
    property string pageId: categories[0].id
    // The pages visited before this one, for Back.
    property var history: []

    // The navigation, top to bottom. A category is an entry here and a page
    // with the same pageId under `pages`; its sub-pages name it as parentId.
    readonly property var categories: [
        { id: "display", title: qsTr("Display"), icon: Icons.display },
        { id: "package", title: qsTr("Package"), icon: Icons.package_ }
    ]

    readonly property var currentPage: findPage(pageId)
    readonly property var parentPage: currentPage && currentPage.parentId !== "" ? findPage(currentPage.parentId) : null
    readonly property string categoryId: parentPage ? parentPage.pageId : pageId
    readonly property bool canGoBack: history.length > 0 || parentPage !== null

    function findPage(id) {
        for (let i = 0; i < pages.children.length; ++i)
            if (pages.children[i].pageId === id)
                return pages.children[i]
        return null
    }

    function go(id) {
        if (id === pageId || !findPage(id))
            return
        history = history.concat([pageId])
        pageId = id
    }

    function back() {
        if (history.length > 0) {
            pageId = history[history.length - 1]
            history = history.slice(0, -1)
        } else if (parentPage) {
            pageId = parentPage.pageId
        }
    }

    function stepCategory(step) {
        const ids = categories.map(c => c.id)
        go(ids[(ids.indexOf(categoryId) + step + ids.length) % ids.length])
    }

    // Every page, and every card on it, that search can find: the card's
    // title, description and keywords, but not its page's title, so
    // "snapping" finds the page rather than everything on it.
    function searchIndex() {
        const out = []
        const walk = (page, item) => {
            for (let i = 0; i < item.children.length; ++i) {
                const child = item.children[i]
                if (child.searchable === true && child.title)
                    out.push({ title: child.title, page: page, item: child,
                               text: [child.title, child.description, child.keywords].join(" ").toLowerCase() })
                else
                    walk(page, child)
            }
        }
        for (let i = 0; i < pages.children.length; ++i) {
            const page = pages.children[i]
            out.push({ title: page.title, page: page, item: null, text: page.title.toLowerCase() })
            walk(page, page)
        }
        return out
    }

    function search(query) {
        const words = query.toLowerCase().split(/\s+/).filter(w => w !== "")
        if (words.length === 0)
            return []
        // Titles that start with what was typed first, then the rest in page order.
        const found = searchIndex().filter(r => words.every(w => r.text.includes(w)))
        const first = r => r.title.toLowerCase().startsWith(words[0]) ? 0 : 1
        return found.map((r, i) => ({ r: r, i: i }))
            .sort((a, b) => first(a.r) - first(b.r) || a.i - b.i)
            .map(x => x.r).slice(0, 8)
    }

    function crumb(page) {
        const parent = page.parentId !== "" ? findPage(page.parentId) : null
        return parent ? parent.title + "  ›  " + page.title : page.title
    }

    function openResult(result) {
        searchField.text = ""
        searchField.focus = false
        go(result.page.pageId)
        if (result.item)
            Qt.callLater(() => result.page.reveal(result.item))
    }

    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; onActivated: win.helpVisible = !win.helpVisible }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; onActivated: Qt.quit() }
    Shortcut {
        sequence: "Esc"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (win.helpVisible)
                win.helpVisible = false
            else if (searchField.activeFocus || searchField.text !== "") {
                searchField.text = ""
                searchField.focus = false
            }
        }
    }
    Shortcut { sequences: ["Ctrl+F", "Ctrl+E"]; context: Qt.ApplicationShortcut; onActivated: searchField.forceActiveFocus() }
    Shortcut { sequences: [StandardKey.Back]; context: Qt.ApplicationShortcut; onActivated: win.back() }
    Shortcut { sequence: "Ctrl+Tab"; context: Qt.ApplicationShortcut; onActivated: win.stepCategory(1) }
    Shortcut { sequences: ["Ctrl+Shift+Tab", "Ctrl+Shift+Backtab"]; context: Qt.ApplicationShortcut; onActivated: win.stepCategory(-1) }
    // Ctrl + 1, 2, … for each category in the navigation.
    Instantiator {
        model: win.categories
        delegate: Shortcut {
            required property var modelData
            required property int index
            sequence: "Ctrl+" + (index + 1)
            context: Qt.ApplicationShortcut
            onActivated: win.go(modelData.id)
        }
    }

    // The Display page lists the monitors as they are now, so ask Hyprland
    // again while it's in front (Displays may just have changed them).
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: win.active && win.categoryId === "display"
        onTriggered: monitors.refresh()
    }

    // Right-to-left languages mirror the window; the Translator sets the
    // application's layout direction.
    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true

        // The mouse's back button, anywhere.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.BackButton
            onClicked: win.back()
        }

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // Navigation
            ColumnLayout {
                Layout.preferredWidth: 288
                Layout.fillHeight: true
                Layout.margins: 12
                Layout.rightMargin: 4
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 8
                    spacing: 8
                    ToolButton {
                        enabled: win.canGoBack
                        opacity: enabled ? 1 : 0.35
                        focusPolicy: Qt.NoFocus
                        implicitWidth: 40
                        implicitHeight: 36
                        Accessible.name: qsTr("Back")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Back")
                        onClicked: win.back()
                        contentItem: Item {
                            Icon {
                                anchors.centerIn: parent
                                path: Icons.back
                                color: Material.foreground
                                size: 16
                                mirrorable: true
                            }
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Settings")
                        font.pixelSize: 13
                    }
                }

                // Search, as Windows has it above the categories.
                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    Layout.bottomMargin: 10
                    implicitHeight: 36
                    leftPadding: 12
                    rightPadding: 36
                    topPadding: 0
                    bottomPadding: 0
                    verticalAlignment: TextInput.AlignVCenter
                    font.pixelSize: 14
                    Accessible.name: qsTr("Find a setting")

                    readonly property var results: win.search(text)
                    property int selected: 0
                    onTextChanged: selected = 0

                    Keys.onDownPressed: selected = Math.min(selected + 1, results.length - 1)
                    Keys.onUpPressed: selected = Math.max(selected - 1, 0)
                    Keys.onReturnPressed: if (results.length > 0) win.openResult(results[selected])
                    Keys.onEnterPressed: if (results.length > 0) win.openResult(results[selected])

                    background: Rectangle {
                        radius: Math.min(6, theme.radius)
                        color: theme.card
                        border.width: 1
                        border.color: Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.08)
                        // Windows underlines the field in the accent while it's typed in.
                        Rectangle {
                            visible: searchField.activeFocus
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 2
                            color: theme.accent
                        }
                    }

                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: searchField.leftPadding
                        anchors.rightMargin: searchField.rightPadding
                        verticalAlignment: Text.AlignVCenter
                        visible: searchField.text === ""
                        text: qsTr("Find a setting")
                        font.pixelSize: 14
                        opacity: 0.55
                        elide: Text.ElideRight
                    }
                    Icon {
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        path: Icons.search
                        color: Material.foreground
                        opacity: 0.7
                        size: 16
                    }

                    Popup {
                        y: searchField.height + 4
                        width: Math.max(searchField.width, 320)
                        padding: 4
                        visible: searchField.activeFocus && searchField.text.trim() !== ""
                        closePolicy: Popup.NoAutoClose
                        focus: false
                        background: Rectangle {
                            radius: Math.min(8, theme.radius)
                            color: theme.card
                            border.color: Qt.rgba(Material.foreground.r, Material.foreground.g, Material.foreground.b, 0.12)
                        }
                        contentItem: ColumnLayout {
                            spacing: 0
                            Repeater {
                                model: searchField.results
                                ItemDelegate {
                                    required property var modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    focusPolicy: Qt.NoFocus
                                    highlighted: index === searchField.selected
                                    onClicked: win.openResult(modelData)
                                    contentItem: ColumnLayout {
                                        spacing: 0
                                        Label {
                                            Layout.fillWidth: true
                                            text: modelData.title
                                            font.pixelSize: 14
                                            elide: Text.ElideRight
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            visible: modelData.item !== null || modelData.page.parentId !== ""
                                            text: modelData.item ? win.crumb(modelData.page)
                                                                 : win.findPage(modelData.page.parentId)?.title ?? ""
                                            font.pixelSize: 12
                                            opacity: 0.6
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                            Label {
                                visible: searchField.results.length === 0
                                Layout.margins: 12
                                text: qsTr("No results")
                                opacity: 0.6
                            }
                        }
                    }
                }

                Repeater {
                    model: win.categories
                    NavItem {
                        required property var modelData
                        label: modelData.title
                        iconPath: modelData.icon
                        current: win.categoryId === modelData.id
                        onClicked: win.go(modelData.id)
                    }
                }

                Item { Layout.fillHeight: true }

                Label {
                    Layout.leftMargin: 12
                    text: qsTr("? for shortcuts")
                    opacity: 0.5
                }
            }

            // The current page
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: 28
                Layout.leftMargin: 28
                Layout.rightMargin: 12
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.rightMargin: 16
                    Layout.bottomMargin: 20
                    spacing: 12

                    // "Package  ›  Snapping": the parent is a link back.
                    Label {
                        visible: win.parentPage !== null
                        text: win.parentPage ? win.parentPage.title : ""
                        font.pixelSize: 28
                        font.bold: true
                        opacity: parentLink.containsMouse ? 0.85 : 0.6
                        MouseArea {
                            id: parentLink
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.go(win.parentPage.pageId)
                        }
                    }
                    Icon {
                        visible: win.parentPage !== null
                        path: Icons.chevron
                        color: Material.foreground
                        opacity: 0.6
                        size: 20
                        mirrorable: true
                    }
                    Label {
                        Layout.fillWidth: true
                        text: win.currentPage ? win.currentPage.title : ""
                        font.pixelSize: 28
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    // The package's changes apply in the background.
                    BusyIndicator {
                        visible: win.categoryId === "package" && backend.applying
                        running: visible
                        implicitWidth: 24
                        implicitHeight: 24
                    }
                    Label {
                        visible: win.categoryId === "package" && backend.error === "" && backend.status !== ""
                        text: backend.status
                        opacity: 0.6
                    }
                }

                // An error from saving or applying, like Windows' info bar.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.rightMargin: 16
                    Layout.bottomMargin: 12
                    visible: win.categoryId === "package" && backend.error !== ""
                    implicitHeight: errorText.implicitHeight + 24
                    radius: theme.radius
                    readonly property color danger: theme.danger
                    color: Qt.tint(theme.card, Qt.rgba(danger.r, danger.g, danger.b, 0.18))
                    border.color: danger
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12
                        Icon {
                            path: Icons.info
                            color: theme.danger
                            size: 20
                        }
                        Label {
                            id: errorText
                            Layout.fillWidth: true
                            text: backend.error
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                StackLayout {
                    id: pages
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: {
                        for (let i = 0; i < children.length; ++i)
                            if (children[i] === win.currentPage)
                                return i
                        return 0
                    }

                    DisplayPage { onNavigate: target => win.go(target) }
                    PackagePage { onNavigate: target => win.go(target) }
                    TaskbarPage { onNavigate: target => win.go(target) }
                    SnappingPage { onNavigate: target => win.go(target) }
                    WindowsPage { onNavigate: target => win.go(target) }
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
                            "Ctrl + F", qsTr("Find a setting"),
                            "Ctrl + " + win.categories.map((c, i) => i + 1).join(", "), qsTr("Go to a category"),
                            "Ctrl + Tab", qsTr("Next category"),
                            "Ctrl + Shift + Tab", qsTr("Previous category"),
                            "Alt + ←", qsTr("Back"),
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
