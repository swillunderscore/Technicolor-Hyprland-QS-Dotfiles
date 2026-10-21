import QtQuick

// Mutually exclusive choice chips. model: [{ id, name }]; `selected` is an id.
Flow {
    id: ch
    property var model: []
    property var selected
    signal picked(var id)
    width: parent ? parent.width : 0
    spacing: 6
    Repeater {
        model: ch.model
        delegate: Rectangle {
            required property var modelData
            readonly property bool sel: ch.selected === modelData.id
            height: 30; radius: 8; width: lbl.implicitWidth + 24
            color: sel ? ST.rowHover : (m.containsMouse ? ST.rowHover : ST.rowBg)
            border.width: sel ? 2 : 0; border.color: ST.fg
            Text { id: lbl; anchors.centerIn: parent; text: modelData.name; color: ST.fg; font.pixelSize: 12; font.family: ST.ff; font.bold: sel }
            MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.picked(modelData.id) }
        }
    }
}
