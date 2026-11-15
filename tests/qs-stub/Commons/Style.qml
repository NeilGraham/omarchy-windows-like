pragma Singleton
import QtQuick

// Stand-in for Omarchy's qs.Commons.Style, for tests only.
QtObject {
    property int cornerRadius: 0
    readonly property QtObject font: QtObject {
        readonly property string menuFamily: "sans-serif"
        readonly property int body: 12
        readonly property int heading: 16
    }
    function duration(ms) {
        return 0;
    }
}
