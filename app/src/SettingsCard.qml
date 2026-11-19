import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One row of a page, as a card the way Windows 11 lays settings out: an
// optional icon, a title and a line on what it does, and the control at the
// end. Clickable cards (a switch, a link to another page) light up on hover.
// Search finds every card by its title and description.
ItemDelegate {
    id: card
    property string title
    property string description: ""
    property string iconPath: ""
    property string keywords: ""
    property bool clickable: false
    // The control at the end of the row.
    default property alias trailing: trailingRow.data
    // Anything under the title, the card's full width (pinned apps).
    property alias below: belowColumn.data

    // Search skips a card that's hidden for good (not just on another page).
    property bool searchable: true
    readonly property color tint: Material.foreground

    // Points a search result at this card.
    function flash() { flashAnimation.restart() }

    Layout.fillWidth: true
    hoverEnabled: clickable
    focusPolicy: clickable ? Qt.StrongFocus : Qt.NoFocus
    topPadding: 12
    bottomPadding: 12
    leftPadding: 16
    rightPadding: 16
    implicitHeight: Math.max(description !== "" ? 68 : 52, implicitContentHeight + topPadding + bottomPadding)

    background: Rectangle {
        radius: theme.radius
        color: card.down && card.clickable ? Qt.tint(theme.card, Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.02))
             : card.hovered ? Qt.tint(theme.card, Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.05))
             : theme.card
        border.width: card.visualFocus ? 2 : 1
        border.color: card.visualFocus ? theme.accent : Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.06)

        Rectangle {
            id: flashRect
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: 2
            border.color: theme.accent
            opacity: 0
            SequentialAnimation {
                id: flashAnimation
                NumberAnimation { target: flashRect; property: "opacity"; to: 1; duration: 150 }
                PauseAnimation { duration: 900 }
                NumberAnimation { target: flashRect; property: "opacity"; to: 0; duration: 400 }
            }
        }
    }

    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            Icon {
                visible: card.iconPath !== ""
                path: card.iconPath
                color: theme.accent
                size: 22
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Label {
                    Layout.fillWidth: true
                    text: card.title
                    font.pixelSize: 15
                    wrapMode: Text.WordWrap
                }
                Label {
                    Layout.fillWidth: true
                    visible: card.description !== ""
                    text: card.description
                    opacity: 0.65
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                }
            }
            RowLayout {
                id: trailingRow
                spacing: 12
            }
        }
        ColumnLayout {
            id: belowColumn
            Layout.fillWidth: true
            visible: children.length > 0
        }
    }
}
