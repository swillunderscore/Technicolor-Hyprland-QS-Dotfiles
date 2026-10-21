import QtQuick

// A switch with its title and a one-paragraph explanation, in a row tile.
Rectangle {
    id: tr
    property string title
    property string desc: ""
    property bool on: false
    signal toggled(bool v)
    width: parent ? parent.width : 0
    height: Math.max(50, txt.implicitHeight + 18); radius: 9; color: ST.rowBg
    Column {
        id: txt
        anchors.left: parent.left; anchors.leftMargin: 12
        anchors.right: sw.left; anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter; spacing: 2
        Text { width: parent.width; wrapMode: Text.WordWrap; text: tr.title; color: ST.fg; font.pixelSize: 13; font.bold: true; font.family: ST.ff }
        Text { visible: tr.desc !== ""; width: parent.width; wrapMode: Text.WordWrap
               text: tr.desc; color: ST.fg; opacity: 0.6; font.pixelSize: 11; font.family: ST.ff }
    }
    TcToggle {
        id: sw
        anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
        on: tr.on
        onToggled: (v) => tr.toggled(v)
    }
}
