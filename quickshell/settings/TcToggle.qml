import QtQuick

// A pill switch. The owner binds `on` and updates it in onToggled (don't
// self-assign).
Rectangle {
    id: tg
    property bool on: false
    signal toggled(bool v)
    width: 46; height: 26; radius: 13
    color: tg.on ? ST.fg : Qt.rgba(ST.fg.r, ST.fg.g, ST.fg.b, 0.18)
    Behavior on color { ColorAnimation { duration: 130 } }
    Rectangle {
        width: 20; height: 20; radius: 10
        anchors.verticalCenter: parent.verticalCenter
        x: tg.on ? parent.width - width - 3 : 3
        color: tg.on ? ST.blockColor : ST.fg
        Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    }
    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: tg.toggled(!tg.on) }
}
