import QtQuick

// A section heading inside a page: hairline (except for the first section),
// title, and an optional explanation. Anything placed inside lands to the
// right of the title (e.g. an "Add app" button).
Column {
    id: sec
    property string title
    property string desc: ""
    property bool first: false
    default property alias trailing: trail.data
    width: parent ? parent.width : 0
    spacing: 4
    topPadding: first ? 0 : 8

    Rectangle { visible: !sec.first; width: parent.width; height: 1; color: ST.fg; opacity: 0.12 }
    Item { visible: !sec.first; width: 1; height: 4 }
    Item {
        width: parent.width; height: Math.max(22, trail.childrenRect.height)
        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
               text: sec.title; color: ST.fg; font.pixelSize: 14; font.bold: true; font.family: ST.ff }
        Item { id: trail; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
               width: childrenRect.width; height: childrenRect.height }
    }
    Text {
        visible: sec.desc !== ""
        width: parent.width; wrapMode: Text.WordWrap
        text: sec.desc; color: ST.fg; opacity: 0.55; font.pixelSize: 11; font.family: ST.ff
    }
}
