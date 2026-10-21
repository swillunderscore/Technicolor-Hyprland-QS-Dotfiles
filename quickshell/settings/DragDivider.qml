import QtQuick

// A grabbable horizontal splitter. Drag it to resize the section above: it
// emits the vertical drag delta; the owner adds it to that section's height
// property (clamped). Uses global Y so the delta is right even as it moves.
Item {
    id: dd
    signal dragged(real dy)
    width: parent ? parent.width : 100
    height: 14
    Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.16) }
    Rectangle { anchors.centerIn: parent; width: 34; height: 4; radius: 2
        color: Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, (ddM.containsMouse || ddM.pressed) ? 0.55 : 0.30) }
    MouseArea {
        // Same grab-stealing problem as TcSlider, and worse here: this drag IS
        // vertical, which is exactly what a Flickable grabs for itself.
        id: ddM; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true
        preventStealing: true; cursorShape: Qt.SizeVerCursor
        property real lastY: 0
        onPressed: (m) => ddM.lastY = dd.mapToGlobal(m.x, m.y).y
        onPositionChanged: (m) => {
            if (!pressed) return
            var gy = dd.mapToGlobal(m.x, m.y).y
            dd.dragged(gy - ddM.lastY); ddM.lastY = gy
        }
    }
}
