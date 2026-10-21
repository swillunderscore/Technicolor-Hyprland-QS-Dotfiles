import QtQuick

// Label + live value + optional Reset on one line, the slider under it, and an
// optional hint under that. Same contract as TcSlider: the owner binds `value`
// and updates its own state in onMoved.
Column {
    id: sr
    property string label
    property string valueText: ""
    property bool resettable: true
    property string hint: ""
    property real from: 0
    property real to: 1
    property real value: 0
    signal moved(real v)
    signal committed(real v)
    signal reset()
    width: parent ? parent.width : 0
    spacing: 2

    Item {
        width: parent.width; height: 22
        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
               text: sr.label; color: ST.fg; font.pixelSize: 12; font.family: ST.ff }
        Text { anchors.right: sr.resettable ? rst.left : parent.right
               anchors.rightMargin: sr.resettable ? 10 : 0; anchors.verticalCenter: parent.verticalCenter
               text: sr.valueText; color: ST.fg; opacity: 0.6; font.pixelSize: 11; font.family: ST.ff }
        Rectangle {
            id: rst; visible: sr.resettable
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            width: 48; height: 20; radius: 6; color: rstM.containsMouse ? ST.rowHover : ST.rowBg
            Text { anchors.centerIn: parent; text: "Reset"; color: ST.fg; font.pixelSize: 10; font.family: ST.ff }
            MouseArea { id: rstM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sr.reset() }
        }
    }
    TcSlider {
        width: parent.width
        from: sr.from; to: sr.to; value: sr.value
        onMoved: (v) => sr.moved(v)
        onCommitted: (v) => sr.committed(v)
    }
    Text {
        visible: sr.hint !== ""
        width: parent.width; wrapMode: Text.WordWrap; bottomPadding: 4
        text: sr.hint; color: ST.fg; opacity: 0.5; font.pixelSize: 11; font.family: ST.ff
        lineHeight: 1.1
    }
}
