import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import "Icons.js" as Icons

// A card that opens another page (a chevron at the end) or another app
// (an arrow out of a box).
SettingsCard {
    id: link
    property bool external: false

    clickable: true

    Icon {
        path: link.external ? Icons.external : Icons.chevron
        color: Material.foreground
        opacity: 0.7
        size: 16
        mirrorable: true
    }
}
