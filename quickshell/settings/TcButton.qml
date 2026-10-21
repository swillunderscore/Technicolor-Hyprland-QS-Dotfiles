import QtQuick

// A text button tile. `armed` tints it amber for a two-click confirm.
Rectangle {
    id: b
    property string text
    property bool armed: false
    signal clicked()
    height: 36; radius: 9
    color: m.containsMouse ? ST.rowHover : (b.armed ? Qt.rgba(0.9, 0.6, 0.2, 0.30) : ST.rowBg)
    opacity: b.enabled ? 1 : 0.6
    Text { anchors.centerIn: parent; text: b.text; color: ST.fg; font.pixelSize: 13; font.family: ST.ff }
    MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
}
