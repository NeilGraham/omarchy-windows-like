import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A page of settings: whatever the page puts in it, scrolling when it
// doesn't fit. The window shows its title (with its parent's before it, on a
// sub-page) and finds its cards for search.
ScrollView {
    id: page
    required property string pageId
    required property string title
    // A sub-page names the page it belongs to: "package" for Snapping.
    property string parentId: ""
    default property alias content: column.data

    // Asks the window to show another page.
    signal navigate(string target)

    // Scrolls a card into view and points at it, for a search result.
    function reveal(item) {
        const flick = page.contentItem
        const y = item.mapToItem(column, 0, 0).y
        flick.contentY = Math.max(0, Math.min(y - 48, flick.contentHeight - flick.height))
        item.flash()
    }

    contentWidth: availableWidth
    contentHeight: column.implicitHeight + 32
    clip: true

    ColumnLayout {
        id: column
        // Room for the scroll bar, and no wider than Windows lets cards get.
        width: Math.min(page.availableWidth - 16, 1000)
        spacing: 4
    }
}
