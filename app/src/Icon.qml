import QtQuick
import QtQuick.Shapes

// A line icon (Icons.js) in any color, so it follows the theme without an
// icon font or the SVG module. Arrows point the other way right to left.
Item {
    id: icon
    property string path
    property color color: "white"
    property real size: 20
    property bool mirrorable: false

    implicitWidth: size
    implicitHeight: size

    Shape {
        width: 24
        height: 24
        scale: icon.size / 24
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        transform: Scale {
            origin.x: 12
            xScale: icon.mirrorable && Qt.application.layoutDirection === Qt.RightToLeft ? -1 : 1
        }
        ShapePath {
            strokeColor: icon.color
            strokeWidth: 1.6
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: icon.path }
        }
    }
}
