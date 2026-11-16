import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A page of settings: a heading, then whatever the page puts in it, scrolling
// when it doesn't fit.
ScrollView {
    id: page
    property string heading: ""
    default property alias content: column.data

    contentWidth: availableWidth
    clip: true

    ColumnLayout {
        id: column
        width: page.availableWidth
        spacing: 4

        Label {
            Layout.fillWidth: true
            Layout.bottomMargin: 12
            text: page.heading
            font.pixelSize: 24
            font.bold: true
        }
    }
}
